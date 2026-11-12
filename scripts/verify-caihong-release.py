#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
"""Verify a Caihong direct-root boot image and its matching module tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


BOOT_MAGIC = b"ANDROID!"
PARTITION_BYTES = 192 * 1024 * 1024
REQUIRED_CONFIGS = (
    "CONFIG_DEVTMPFS=y",
    "CONFIG_DEVTMPFS_MOUNT=y",
    "CONFIG_EFI_PARTITION=y",
    "CONFIG_SCSI=y",
    "CONFIG_BLK_DEV_SD=y",
    "CONFIG_SCSI_UFSHCD=y",
    "CONFIG_SCSI_UFS_QCOM=y",
    "CONFIG_PHY_QCOM_QMP_UFS=y",
    "CONFIG_EXT4_FS=y",
    'CONFIG_INITRAMFS_SOURCE=""',
    "CONFIG_FW_LOADER_COMPRESS=y",
    "CONFIG_FW_LOADER_COMPRESS_XZ=y",
    "CONFIG_INPUT_JOYDEV=y",
    "CONFIG_INPUT_UINPUT=y",
)
REQUIRED_MODULES = (
    "oneplus_pogo",
    "nt36532e_ts",
    "sc8547_cp",
    "caihong_pen_power",
    "sc820cs",
    "sc1320cs",
    "gt9772",
    "ath12k_wifi7",
    "bnep",
    "rfcomm",
    "hidp",
    "qcom_q6v5_pas",
    "qcom-iris",
    "xpad",
    "qcom_camera_icp",
    "qcom-camera-icp-bps",
)
# USB audio is what makes USB-C headsets enumerate as an ALSA card.  It used to
# be dropped from the package by a hand-maintained module list, so keep it in
# the release gate where either a module or a built-in driver is acceptable.
REQUIRED_MODULES_OR_BUILTIN = (
    "msm",
    "snd-usb-audio",
    "snd-usbmidi-lib",
    "snd-rawmidi",
    "snd-hwdep",
)
EARLY_FIRMWARE = (
    "qcom/gen70900_sqe.fw",
    "qcom/gmu_gen70900.bin",
)


class VerificationError(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def align(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def parse_boot(image: bytes) -> dict[str, object]:
    if len(image) < 1660 or image[:8] != BOOT_MAGIC:
        raise VerificationError("not an Android boot image v2")
    kernel_size = struct.unpack_from("<I", image, 8)[0]
    ramdisk_size = struct.unpack_from("<I", image, 16)[0]
    second_size = struct.unpack_from("<I", image, 24)[0]
    page_size = struct.unpack_from("<I", image, 36)[0]
    header_version = struct.unpack_from("<I", image, 40)[0]
    recovery_dtbo_size = struct.unpack_from("<I", image, 1632)[0]
    header_size = struct.unpack_from("<I", image, 1644)[0]
    dtb_size = struct.unpack_from("<I", image, 1648)[0]
    if header_version != 2 or header_size < 1660:
        raise VerificationError("boot image does not use header v2")
    if page_size < 2048 or page_size & (page_size - 1):
        raise VerificationError("invalid boot page size")
    if ramdisk_size or second_size or recovery_dtbo_size:
        raise VerificationError("boot image contains a ramdisk or auxiliary payload")
    kernel_start = page_size
    kernel_end = kernel_start + kernel_size
    dtb_start = align(kernel_end, page_size)
    dtb_end = dtb_start + dtb_size
    if kernel_size == 0 or dtb_size == 0 or dtb_end > len(image):
        raise VerificationError("truncated kernel or DTB payload")
    cmdline = (image[64:576] + image[608:1632]).split(b"\0", 1)[0]
    try:
        cmdline_text = cmdline.decode("ascii")
    except UnicodeDecodeError as error:
        raise VerificationError("kernel command line is not ASCII") from error
    return {
        "kernel": image[kernel_start:kernel_end],
        "dtb": image[dtb_start:dtb_end],
        "cmdline": cmdline_text,
        "page_size": page_size,
        "header_version": header_version,
        "ramdisk_size": ramdisk_size,
    }


def one_module_release(module_tree: Path) -> tuple[str, Path]:
    root = module_tree / "lib/modules"
    releases = sorted(path for path in root.iterdir() if path.is_dir())
    if len(releases) != 1:
        raise VerificationError("module tree must contain exactly one release")
    return releases[0].name, releases[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--dtb", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--module-tree", type=Path, required=True)
    parser.add_argument("--firmware-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--root-partlabel", choices=("linux", "userdata"), required=True)
    args = parser.parse_args()

    image = args.image.read_bytes()
    if len(image) > PARTITION_BYTES:
        raise VerificationError("boot image exceeds the 192 MiB partition")
    parsed = parse_boot(image)
    kernel = args.kernel.read_bytes()
    dtb = args.dtb.read_bytes()
    if parsed["kernel"] != kernel:
        raise VerificationError("boot kernel payload differs from Image")
    if parsed["dtb"] != dtb:
        raise VerificationError("boot DTB payload differs from the board DTB")

    tokens = set(str(parsed["cmdline"]).split())
    root_tokens = {token for token in tokens if token.startswith("root=")}
    expected_root = f"root=PARTLABEL={args.root_partlabel}"
    if root_tokens != {expected_root}:
        raise VerificationError(
            f"expected exactly {expected_root}, found {sorted(root_tokens)}"
        )
    for token in (
        expected_root,
        "rootfstype=ext4",
        "rootwait",
        "rw",
    ):
        if token not in tokens:
            raise VerificationError(f"missing direct-root command-line token: {token}")
    if any(token.startswith("rdinit=") or token.startswith("root=LABEL=") for token in tokens):
        raise VerificationError("command line references the removed initramfs path")

    config_data = args.config.read_bytes()
    config_lines = set(config_data.decode("ascii").splitlines())
    missing = [item for item in REQUIRED_CONFIGS if item not in config_lines]
    if missing:
        raise VerificationError("kernel lacks direct-root config: " + ", ".join(missing))

    kernel_release, release_dir = one_module_release(args.module_tree)
    if kernel_release.encode("ascii") not in kernel:
        raise VerificationError("kernel release is absent from Image")
    module_hashes: dict[str, dict[str, object]] = {}
    for module in REQUIRED_MODULES:
        matches = list(release_dir.rglob(f"{module}.ko"))
        if len(matches) != 1:
            raise VerificationError(f"expected one module named {module}.ko")
        payload = matches[0].read_bytes()
        if kernel_release.encode("ascii") not in payload:
            raise VerificationError(f"module vermagic mismatch: {module}")
        module_hashes[module] = {
            "path": str(matches[0].relative_to(args.module_tree)),
            "bytes": len(payload),
            "sha256": digest(payload),
        }
    builtin_modules = (release_dir / "modules.builtin").read_text().splitlines()
    for module in REQUIRED_MODULES_OR_BUILTIN:
        matches = list(release_dir.rglob(f"{module}.ko"))
        if len(matches) == 1:
            payload = matches[0].read_bytes()
            if kernel_release.encode("ascii") not in payload:
                raise VerificationError(f"module vermagic mismatch: {module}")
            module_hashes[module] = {
                "path": str(matches[0].relative_to(args.module_tree)),
                "bytes": len(payload),
                "sha256": digest(payload),
            }
        elif any(path.endswith(f"/{module}.ko") for path in builtin_modules):
            module_hashes[module] = {"built_in": True}
        else:
            raise VerificationError(f"expected module or built-in driver named {module}")

    firmware_hashes = {}
    for relative in EARLY_FIRMWARE:
        payload = (args.firmware_dir / relative).read_bytes()
        if payload not in kernel:
            raise VerificationError(f"early GPU firmware is not built into Image: {relative}")
        firmware_hashes[relative] = digest(payload)

    manifest = {
        "boot_image": args.image.name,
        "boot_bytes": len(image),
        "boot_sha256": digest(image),
        "kernel_release": kernel_release,
        "kernel_bytes": len(kernel),
        "kernel_sha256": digest(kernel),
        "dtb_bytes": len(dtb),
        "dtb_sha256": digest(dtb),
        "boot_header_version": parsed["header_version"],
        "boot_page_size": parsed["page_size"],
        "external_ramdisk_bytes": parsed["ramdisk_size"],
        "root_partlabel": args.root_partlabel,
        "cmdline": parsed["cmdline"],
        "config_sha256": digest(config_data),
        "early_builtin_firmware": firmware_hashes,
        "required_modules": module_hashes,
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.manifest.with_suffix(args.manifest.suffix + ".new")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(args.manifest)
    print(
        f"verified {args.image.name}: {kernel_release}, ramdisk=0, "
        f"{len(REQUIRED_MODULES)} release modules"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, VerificationError) as error:
        raise SystemExit(f"release verification failed: {error}") from error
