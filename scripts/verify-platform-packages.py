#!/usr/bin/env python3
import argparse
from pathlib import Path
import subprocess

from platform_runtime import RUNTIME_PACKAGES


PROJECT = Path(__file__).resolve().parents[1]


def source_paths(project, distribution):
    required = set()
    overlays = [project / 'rootfs/archlinuxarm']
    if distribution == 'armada':
        overlays.append(project / 'rootfs/armada')
    ucm = 'usr/share/alsa/ucm2/conf.d/sm8650/SM8650-MTP.conf'
    for overlay in overlays:
        for path in overlay.rglob('*'):
            if not path.is_file() and not path.is_symlink():
                continue
            relative = path.relative_to(overlay).as_posix()
            if distribution == 'armada' and relative == 'etc/sudoers.d/10-alarm':
                continue
            if relative.startswith('etc/') or relative == ucm:
                relative = 'usr/share/caihong-platform/defaults/' + relative
            required.add(relative)
    firmware = project / 'firmware'
    for path in firmware.rglob('*'):
        if path.is_file() and path.name not in (
                'SOURCE.md', 'SHA256SUMS', 'regulatory.db', 'regulatory.db.p7s'):
            required.add('usr/lib/firmware/' + path.relative_to(firmware).as_posix())
    seed = project / 'firmware-assets/caihong-ssc/root'
    for path in seed.rglob('*'):
        if path.is_file() or path.is_symlink():
            required.add('usr/share/caihong-ssc/root/' + path.relative_to(seed).as_posix())
    return required


def verify_dependencies(metadata, distribution):
    if distribution == 'archlinuxarm':
        dependencies = {line.removeprefix('depend = ').split()[0]
                        for line in metadata.splitlines() if line.startswith('depend = ')}
    else:
        dependencies = {line.split()[0] for line in metadata.splitlines() if line.strip()}
    missing = set(RUNTIME_PACKAGES[distribution]) - dependencies
    if missing:
        raise ValueError(f'{distribution} platform package is missing runtime dependencies: {sorted(missing)}')


def read_archive(package, action, *members):
    if package.suffix != '.rpm':
        return subprocess.check_output(['bsdtar', action, str(package), *members], text=True)
    with subprocess.Popen(['rpm2cpio', str(package)], stdout=subprocess.PIPE) as source:
        result = subprocess.run(['bsdtar', action, '-', *('./' + name.removeprefix('./') for name in members)], stdin=source.stdout,
                                text=True, capture_output=True, check=True)
        source.stdout.close()
        if source.wait():
            raise RuntimeError(f'cannot read RPM payload: {package}')
    return result.stdout


def verify(release, distribution, libdir, suffix):
    pointer = release / ('CAIHONG_PLATFORM_PACKAGE_' + distribution.upper())
    name = pointer.read_text().strip()
    if Path(name).name != name or not name.startswith('caihong-platform-') or not name.endswith(suffix):
        raise ValueError(f'invalid native platform pointer: {pointer}')
    package = release / name
    if read_archive(package, '-xOf', 'usr/share/caihong-platform/distribution').strip() != distribution:
        raise ValueError(f'incorrect distribution in {package.name}')
    if read_archive(package, '-xOf', 'usr/share/caihong-npu/libdir').strip() != libdir:
        raise ValueError(f'incorrect NPU layout in {package.name}')
    listing = {path.removeprefix('./').rstrip('/')
               for path in read_archive(package, '-tf').splitlines()}
    if distribution == 'archlinuxarm':
        metadata = subprocess.check_output(['bsdtar', '-xOf', str(package), '.PKGINFO'], text=True)
        if 'pkgname = caihong-platform\n' not in metadata or 'arch = aarch64\n' not in metadata:
            raise ValueError('invalid pacman platform metadata')
        if not {'.INSTALL', '.MTREE'} <= listing:
            raise ValueError('missing native pacman install hooks')
        verify_dependencies(metadata, distribution)
    else:
        metadata = subprocess.check_output(['rpm', '-qp', '--queryformat', '%{NAME} %{ARCH}', str(package)], text=True)
        if metadata != 'caihong-platform aarch64':
            raise ValueError('invalid RPM platform metadata')
        requirements = subprocess.check_output(['rpm', '-qp', '--requires', str(package)], text=True)
        verify_dependencies(requirements, distribution)
    required = {
        'usr/libexec/caihong-platform/configure-platform',
        'usr/share/caihong-platform/defaults/etc/systemd/system/caihong-keyboard.service',
        'usr/share/caihong-platform/distribution',
        'usr/share/caihong-platform/directory-modes',
        'usr/share/caihong-npu/VERSION',
        'usr/share/caihong/toolbox-build-info',
        'usr/share/caihong/ssc-build-info',
        'usr/share/licenses/caihong-ssc/LICENSE.libssc',
        'usr/share/caihong/libcamera-build-info',
        'usr/share/caihong/plasma-camera-build-info',
        'usr/share/caihong-ssc/root/sensors/sns_reg.conf',
        'usr/bin/cam', 'usr/bin/qcam', 'usr/bin/plasma-camera',
        'usr/bin/caihong-toolbox',
        'usr/lib/caihong-toolbox/caihong-toolbox-service',
        'usr/lib/caihong-toolbox/caihong_toolbox/gui.py',
        'usr/lib/systemd/system/caihong-toolbox.service',
        'usr/share/dbus-1/system-services/org.caihong.Toolbox1.service',
        'usr/share/dbus-1/system.d/org.caihong.Toolbox1.conf',
        'usr/share/polkit-1/actions/org.caihong.toolbox.policy',
        'usr/share/applications/caihong-toolbox.desktop',
        'usr/share/icons/hicolor/scalable/apps/caihong-toolbox.svg',
        'usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-640x480.bin',
        'usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-1632x1224.bin',
        'usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-2104x1560.bin',
        'usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-3264x2448.bin',
        'usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-4208x3120.bin',
        f'usr/{libdir}/libcamera.so.0.7',
        f'usr/{libdir}/gstreamer-1.0/libgstlibcamera.so',
        f'usr/{libdir}/dri/qcom_drv_video.so',
        f'usr/{libdir}/dri/msm_drv_video.so',
        'usr/lib/power-profiles-daemon',
        'usr/local/sbin/qbootctl', 'usr/local/libexec/caihong-nvram-mac',
        'usr/local/sbin/caihong-npu-info',
        'usr/bin/adbd', 'usr/lib/caihong-adbd/runtime',
        'usr/local/libexec/caihong-ssc/hexagonrpcd',
        'usr/local/libexec/caihong-ssc/iio-sensor-proxy',
        'usr/local/lib/caihong-ssc/libhexagonrpc.so.0.5',
        'usr/local/lib/caihong-ssc/libssc.so.2',
        'usr/lib/systemd/system/caihong-ssc.service',
        'usr/lib/systemd/system/iio-sensor-proxy.service.d/caihong-ssc.conf',
        'usr/lib/udev/rules.d/90-caihong-ssc.rules',
        'usr/local/libexec/caihong-npu-htp-self-test',
        'usr/local/libexec/caihong-npu-htp-conv-test',
        f'usr/{libdir}/libcdsprpc.so.1',
        f'usr/{libdir}/libcdsprpc.so',
        f'usr/{libdir}/libcdsprpc.so.1.0.0',
        f'usr/{libdir}/caihong-npu/libcalculator.so',
        f'usr/{libdir}/caihong-npu/qnn/libQnnHtp.so',
        f'usr/{libdir}/caihong-npu/qnn/libQnnHtpPrepare.so',
        f'usr/{libdir}/caihong-npu/qnn/libQnnHtpV75Stub.so',
        'usr/share/caihong-npu/dsp/v75/libQnnHtpV75Skel.so',
        'usr/share/caihong-npu/dsp/v75/fastrpc_shell_unsigned_3',
        'usr/share/licenses/caihong-npu/LICENSE.fastrpc',
        'usr/share/licenses/caihong-npu/LICENSE.geniex-qairt-plugin',
        'usr/share/licenses/caihong-npu/THIRD_PARTY_NOTICES.QAIRT.md',
        'usr/share/doc/caihong-npu/SOURCE.md',
        'usr/lib/udev/rules.d/99-caihong-fastrpc.rules',
    }
    for name in ('fastrpc_shell_unsigned_3', 'libcalculator_skel.so',
                 'libQnnHtpV75Skel.so', 'libc++.so.1', 'libc++abi.so.1'):
        required.update((f'usr/share/caihong-npu/dsp/v75/{name}', f'usr/lib/dsp/{name}'))
    for name in ('libQnnHtp.so', 'libQnnHtpPrepare.so', 'libQnnHtpV75Stub.so'):
        required.add(f'usr/{libdir}/{name}')
    required.update(source_paths(PROJECT, distribution))
    missing = required - listing
    if missing:
        raise ValueError(f'{package.name} is missing: {sorted(missing)}')
    if 'usr/libexec/caihong-platform/install-caihong-platform' in listing:
        raise ValueError('obsolete tar installer is still packaged')
    print(f'verified native {distribution} platform package: {package.name} ({len(required)} required paths)')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('release', type=Path)
    arguments = parser.parse_args()
    verify(arguments.release, 'archlinuxarm', 'lib', '-aarch64.pkg.tar.zst')
    verify(arguments.release, 'armada', 'lib64', '-1.aarch64.rpm')


if __name__ == '__main__':
    main()
