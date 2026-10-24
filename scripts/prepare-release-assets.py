#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
"""Prepare installable GitHub release assets and release notes."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
from pathlib import Path


PART_BYTES = 1900 * 1024 * 1024
DIRECT_BYTES = 2000 * 1024 * 1024
COPY_BYTES = 8 * 1024 * 1024
SPARSE_HEADER = struct.Struct("<I4H4I")
SPARSE_CHUNK_HEADER = struct.Struct("<2H2I")
SPARSE_MAGIC = 0xED26FF3A
SPARSE_CHUNK_RAW = 0xCAC1
SPARSE_CHUNK_FILL = 0xCAC2
SPARSE_CHUNK_DONT_CARE = 0xCAC3
SPARSE_CHUNK_CRC32 = 0xCAC4
ZSTD_LEVEL = 15
ZSTD_THREADS = 0


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_dependencies(path: Path) -> dict[str, str]:
    result = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        result[key] = value
    return result


def inspect_android_sparse(path: Path) -> dict[str, int | str]:
    """Validate an Android sparse image and return release metadata."""
    with path.open("rb") as source:
        header = source.read(SPARSE_HEADER.size)
        if len(header) != SPARSE_HEADER.size:
            raise RuntimeError(f"truncated Android sparse header: {path}")
        (
            magic,
            major,
            minor,
            file_header_bytes,
            chunk_header_bytes,
            block_bytes,
            total_blocks,
            total_chunks,
            _checksum,
        ) = SPARSE_HEADER.unpack(header)
        if magic != SPARSE_MAGIC or major != 1:
            raise RuntimeError(f"unsupported Android sparse image: {path}")
        if file_header_bytes < SPARSE_HEADER.size:
            raise RuntimeError(f"invalid Android sparse file header size: {path}")
        if chunk_header_bytes < SPARSE_CHUNK_HEADER.size:
            raise RuntimeError(f"invalid Android sparse chunk header size: {path}")
        if block_bytes == 0 or block_bytes % 4:
            raise RuntimeError(f"invalid Android sparse block size: {path}")
        source.seek(file_header_bytes)

        output_blocks = 0
        for _ in range(total_chunks):
            chunk_header = source.read(chunk_header_bytes)
            if len(chunk_header) != chunk_header_bytes:
                raise RuntimeError(f"truncated Android sparse chunk header: {path}")
            chunk_type, _reserved, chunk_blocks, total_bytes = (
                SPARSE_CHUNK_HEADER.unpack_from(chunk_header)
            )
            if total_bytes < chunk_header_bytes:
                raise RuntimeError(f"invalid Android sparse chunk size: {path}")
            payload_bytes = total_bytes - chunk_header_bytes
            expected_payload = {
                SPARSE_CHUNK_RAW: chunk_blocks * block_bytes,
                SPARSE_CHUNK_FILL: 4,
                SPARSE_CHUNK_DONT_CARE: 0,
                SPARSE_CHUNK_CRC32: 4,
            }.get(chunk_type)
            if expected_payload is None or payload_bytes != expected_payload:
                raise RuntimeError(f"invalid Android sparse chunk payload: {path}")
            source.seek(payload_bytes, 1)
            output_blocks += chunk_blocks

        if output_blocks != total_blocks or source.tell() != path.stat().st_size:
            raise RuntimeError(f"inconsistent Android sparse image length: {path}")

    return {
        "format": "android-sparse-ext4",
        "sparse_version": f"{major}.{minor}",
        "block_bytes": block_bytes,
        "logical_bytes": total_blocks * block_bytes,
        "filesystem_label": "linux",
    }


def copy_part(source, target: Path, limit: int) -> int:
    copied = 0
    with target.open("wb") as destination:
        while copied < limit:
            block = source.read(min(COPY_BYTES, limit - copied))
            if not block:
                break
            destination.write(block)
            copied += len(block)
    return copied


def compress_zstd(source: Path, output: Path) -> None:
    if shutil.which("zstd") is None:
        raise RuntimeError("zstd is required to prepare release assets")
    temporary = output.with_name(f"{output.name}.new")
    temporary.unlink(missing_ok=True)
    try:
        subprocess.run(
            [
                "zstd",
                "-q",
                f"-T{ZSTD_THREADS}",
                f"-{ZSTD_LEVEL}",
                "--force",
                str(source),
                "-o",
                str(temporary),
            ],
            check=True,
        )
        subprocess.run(["zstd", "-q", "--test", str(temporary)], check=True)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def write_release_notes(
    path: Path,
    kernel_release: str,
    assets: list[Path],
    asset_hashes: dict[str, str],
    rootfs: Path,
    rootfs_hash: str,
    compressed_rootfs: Path,
    compressed_rootfs_hash: str,
    rootfs_assets: list[Path],
    dependencies: dict[str, str],
    rootfs_metadata: dict[str, int | str],
) -> None:
    checksums = "".join(
        f"{asset_hashes[asset.name]}  {asset.name}\n" for asset in assets
    )
    platform_package = next(
        (asset for asset in assets if asset.name.startswith("caihong-platform-")),
        None,
    )
    npu_package = next(
        (asset for asset in assets if asset.name.startswith("caihong-npu-")),
        None,
    )
    armada_kernel_package = next(
        (asset for asset in assets if asset.name.startswith("caihong-kernel-armada-")),
        None,
    )
    kernel_package = next(
        (asset for asset in assets if asset.name.startswith("linux-caihong-")),
        None,
    )
    source_lines = []
    for component in ("LINUX", "LIBCAMERA", "PLASMA_CAMERA", "QBOOTCTL", "MKBOOTIMG"):
        repository = dependencies.get(f"{component}_REPOSITORY")
        reference = dependencies.get(f"{component}_REF")
        commit = dependencies.get(f"{component}_COMMIT")
        if repository and reference and commit:
            source_lines.append(
                f"- `{component.lower().replace('_', '-')}`: `{commit}` "
                f"(`{reference}`, {repository})"
            )

    if (
        len(rootfs_assets) == 1
        and rootfs_assets[0].name == compressed_rootfs.name
    ):
        reconstruction = f"Use `{compressed_rootfs.name}` directly."
    else:
        parts = " ".join(asset.name for asset in rootfs_assets)
        reconstruction = (
            "GitHub limits each Release asset to less than 2 GiB, so the rootfs "
            "image is compressed first and then split. Reconstruct the zstd stream "
            "in part-number order:\n\n"
            "```sh\n"
            f"cat {parts} > {compressed_rootfs.name}\n"
            "```"
        )

    if rootfs_metadata["format"] == "android-sparse-ext4":
        rootfs_instructions = (
            f"{reconstruction}\n\n"
            "Verify and decompress the complete stream to recover the flashable "
            "Android sparse ext4 image:\n\n"
            "```sh\n"
            f"sha256sum {compressed_rootfs.name}\n"
            f"zstd -d {compressed_rootfs.name} -o {rootfs.name}\n"
            f"sha256sum {rootfs.name}\n"
            "ROOT_PARTITION=linux  # use userdata for a single-system install\n"
            f"fastboot flash \"$ROOT_PARTITION\" {rootfs.name}\n"
            "```\n\n"
            "The two SHA-256 values are listed below. The decompressed image is "
            "ready for fastboot; its logical filesystem size is "
            f"{rootfs_metadata['logical_bytes']} bytes."
        )
    else:
        rootfs_instructions = reconstruction

    path.write_text(
        f"""Caihong Linux release for the OnePlus Pad Pro.

The two Android boot image v2 files contain only Linux `{kernel_release}` and the
Caihong DTB; they do not contain a ramdisk. Choose the `linux` image for dual boot
or the `userdata` image for a single-system installation.

## Required DTBO step

Erase only the DTBO partition for the slot selected for Linux before flashing
its boot image. Keep the Android slot's DTBO intact.

```sh
LINUX_SLOT=b
fastboot erase "dtbo_${{LINUX_SLOT}}"
fastboot flash "boot_${{LINUX_SLOT}}" caihong-boot-linux-{kernel_release}.img
```

## Rootfs

{rootfs_instructions}

Complete compressed rootfs SHA-256:

```text
{compressed_rootfs_hash}  {compressed_rootfs.name}
```

Decompressed flashable rootfs SHA-256:

```text
{rootfs_hash}  {rootfs.name}
```

## Existing rootfs updates

After verifying the SHA-256 values below, install the device-only payloads
without reflashing:

```sh
sudo /usr/libexec/caihong-platform/install-caihong-platform \\
  {platform_package.name if platform_package else 'caihong-platform-archlinuxarm-<version>.tar.zst'}
sudo pacman -U ./{kernel_package.name if kernel_package else 'linux-caihong-<version>-1-aarch64.pkg.tar.zst'}
sudo /usr/libexec/caihong-platform/install-caihong-platform \\
  {npu_package.name if npu_package else 'caihong-npu-<version>-lib.tar.zst'}
```

Armada does not use pacman. Install the same components with:

```sh
sudo /usr/libexec/caihong-platform/install-caihong-platform \\
  {platform_package.name if platform_package else 'caihong-platform-armada-<version>.tar.zst'}
sudo /usr/libexec/caihong-platform/install-caihong-kernel \\
  {armada_kernel_package.name if armada_kernel_package else 'caihong-kernel-armada-<version>.tar.zst'}
sudo /usr/libexec/caihong-platform/install-caihong-platform \\
  {npu_package.name if npu_package else 'caihong-npu-<version>-lib64.tar.zst'}
```

## Asset SHA-256

```text
{checksums}```

## Resolved source revisions

{chr(10).join(source_lines)}
"""
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--dependencies", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--require-pacman-kernel", action="store_true")
    args = parser.parse_args()

    release_dir = args.release_dir.resolve()
    rootfs = args.rootfs.resolve()
    if not rootfs.name.endswith(".ext4.sparse.img"):
        raise RuntimeError("release rootfs must be an .ext4.sparse.img file")
    rootfs_metadata = inspect_android_sparse(rootfs)
    assets = args.assets.resolve()
    kernel_release = (release_dir / "KERNEL_RELEASE").read_text().strip()
    boot_manifests = {
        root: json.loads(
            (release_dir / f"caihong-boot-{root}-{kernel_release}.img.json").read_text()
        )
        for root in ("linux", "userdata")
    }
    for root, manifest in boot_manifests.items():
        if manifest.get("root_partlabel") != root:
            raise RuntimeError(f"boot manifest root mismatch for {root}")
    kernel_package_name = (release_dir / "LINUX_CAIHONG_PACKAGE").read_text().strip()
    kernel_package = release_dir / kernel_package_name
    if not kernel_package.is_file():
        raise RuntimeError(f"kernel package does not exist: {kernel_package}")
    if args.require_pacman_kernel and not kernel_package_name.endswith(
        "-aarch64.pkg.tar.zst"
    ):
        raise RuntimeError("Arch release must include a pacman kernel package")

    compressed_rootfs = release_dir / f"{rootfs.name}.zst"
    print(f"compressing {rootfs.name} before release splitting")
    compress_zstd(rootfs, compressed_rootfs)

    if assets.exists():
        shutil.rmtree(assets)
    assets.mkdir(parents=True)
    copied = []
    names = [
        f"caihong-boot-linux-{kernel_release}.img",
        f"caihong-boot-userdata-{kernel_release}.img",
        kernel_package_name,
    ]
    platform_package = release_dir / (
        release_dir / "CAIHONG_PLATFORM_PACKAGE"
    ).read_text().strip()
    npu_package = release_dir / (
        release_dir / "CAIHONG_NPU_PACKAGE"
    ).read_text().strip()
    names.extend((platform_package.name, npu_package.name))
    armada_kernel_package_name = (
        release_dir / "CAIHONG_KERNEL_ARMADA_PACKAGE"
    ).read_text().strip()
    armada_kernel_package = release_dir / armada_kernel_package_name
    if not armada_kernel_package.is_file():
        raise RuntimeError(
            f"Armada kernel package does not exist: {armada_kernel_package}"
        )
    names.append(armada_kernel_package_name)
    for name in names:
        target = assets / name
        shutil.copy2(release_dir / name, target)
        copied.append(target)

    rootfs_hash = sha256(rootfs)
    compressed_rootfs_hash = sha256(compressed_rootfs)
    rootfs_assets = []
    if compressed_rootfs.stat().st_size < DIRECT_BYTES:
        target = assets / compressed_rootfs.name
        shutil.copy2(compressed_rootfs, target)
        rootfs_assets.append(target)
    else:
        with compressed_rootfs.open("rb") as source:
            index = 0
            while True:
                target = assets / f"{compressed_rootfs.name}.part-{index:02d}"
                copied_bytes = copy_part(source, target, PART_BYTES)
                if copied_bytes == 0:
                    target.unlink()
                    break
                rootfs_assets.append(target)
                index += 1
    copied.extend(rootfs_assets)
    asset_hashes = {path.name: sha256(path) for path in copied}

    dependencies = load_dependencies(args.dependencies)
    manifest = {
        "device": "OnePlus Pad Pro (caihong)",
        "kernel_release": kernel_release,
        "boot": boot_manifests,
        "pacman_package": {
            "name": kernel_package_name,
            "bytes": kernel_package.stat().st_size,
            "sha256": asset_hashes[kernel_package_name],
        },
        "rootfs": {
            **rootfs_metadata,
            "image_name": rootfs.name,
            "image_bytes": rootfs.stat().st_size,
            "image_sha256": rootfs_hash,
            "compression": {
                "format": "zstd",
                "level": ZSTD_LEVEL,
                "reconstructed_name": compressed_rootfs.name,
                "bytes": compressed_rootfs.stat().st_size,
                "sha256": compressed_rootfs_hash,
                "assets": [path.name for path in rootfs_assets],
            },
        },
        "dependencies": dependencies,
    }
    manifest["platform_package"] = {
        "name": platform_package.name,
        "bytes": platform_package.stat().st_size,
        "sha256": asset_hashes[platform_package.name],
    }
    manifest["npu_package"] = {
        "name": npu_package.name,
        "bytes": npu_package.stat().st_size,
        "sha256": asset_hashes[npu_package.name],
    }
    manifest["armada_kernel_package"] = {
        "name": armada_kernel_package_name,
        "bytes": armada_kernel_package.stat().st_size,
        "sha256": asset_hashes[armada_kernel_package_name],
    }
    manifest_path = release_dir / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    sums = release_dir / "SHA256SUMS"
    sums.write_text(
        "".join(f"{asset_hashes[path.name]}  {path.name}\n" for path in copied)
    )
    write_release_notes(
        args.notes.resolve(),
        kernel_release,
        copied,
        asset_hashes,
        rootfs,
        rootfs_hash,
        compressed_rootfs,
        compressed_rootfs_hash,
        rootfs_assets,
        dependencies,
        rootfs_metadata,
    )
    for path in copied:
        if path.stat().st_size >= 2 * 1024 * 1024 * 1024:
            raise RuntimeError(f"release asset is not below 2 GiB: {path}")
    print(f"prepared {len(copied)} installable release assets in {assets}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
