#!/usr/bin/env python3
import argparse
from pathlib import Path
import subprocess


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
    else:
        metadata = subprocess.check_output(['rpm', '-qp', '--queryformat', '%{NAME} %{ARCH}', str(package)], text=True)
        if metadata != 'caihong-platform aarch64':
            raise ValueError('invalid RPM platform metadata')
    required = {
        'usr/libexec/caihong-platform/configure-platform',
        'usr/share/caihong-platform/defaults/etc/systemd/system/caihong-keyboard.service',
        'usr/share/caihong-platform/distribution',
        'usr/share/caihong-npu/VERSION',
        'usr/share/caihong-ssc/root/sensors/sns_reg.conf',
        'usr/bin/cam', 'usr/bin/qcam', 'usr/bin/plasma-camera',
        f'usr/{libdir}/libcamera.so.0.7',
        f'usr/{libdir}/gstreamer-1.0/libgstlibcamera.so',
        f'usr/{libdir}/dri/qcom_drv_video.so',
        f'usr/{libdir}/dri/msm_drv_video.so',
        'usr/lib/power-profiles-daemon',
        'usr/local/sbin/qbootctl', 'usr/local/libexec/caihong-nvram-mac',
        'usr/local/sbin/caihong-npu-info',
        'usr/local/libexec/caihong-npu-htp-self-test',
        'usr/local/libexec/caihong-npu-htp-conv-test',
        f'usr/{libdir}/libcdsprpc.so.1',
        f'usr/{libdir}/caihong-npu/libcalculator.so',
        f'usr/{libdir}/caihong-npu/qnn/libQnnHtp.so',
        f'usr/{libdir}/caihong-npu/qnn/libQnnHtpPrepare.so',
        f'usr/{libdir}/caihong-npu/qnn/libQnnHtpV75Stub.so',
        'usr/share/caihong-npu/dsp/v75/libQnnHtpV75Skel.so',
        'usr/share/caihong-npu/dsp/v75/fastrpc_shell_unsigned_3',
        'usr/share/licenses/caihong-npu/LICENSE.fastrpc',
        'usr/share/licenses/caihong-npu/LICENSE.geniex-qairt-plugin',
    }
    if distribution == 'archlinuxarm':
        required.update(('usr/bin/caihong-toolbox',
                         'usr/lib/caihong-toolbox/caihong-toolbox-service',
                         'usr/lib/systemd/system/caihong-toolbox.service'))
    missing = required - listing
    if missing:
        raise ValueError(f'{package.name} is missing: {sorted(missing)}')
    if 'usr/libexec/caihong-platform/install-caihong-platform' in listing:
        raise ValueError('obsolete tar installer is still packaged')
    print(f'verified native {distribution} platform package including NPU: {name}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('release', type=Path)
    arguments = parser.parse_args()
    verify(arguments.release, 'archlinuxarm', 'lib', '-aarch64.pkg.tar.zst')
    verify(arguments.release, 'armada', 'lib64', '-1.aarch64.rpm')


if __name__ == '__main__':
    main()
