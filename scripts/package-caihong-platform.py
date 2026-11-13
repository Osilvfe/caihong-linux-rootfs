#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


PROJECT = Path(__file__).resolve().parents[1]
COMPONENTS = {
    'libcamera': '0.7.2',
    'libcamera-ipa': '0.7.2',
    'libcamera-tools': '0.7.2',
    'gst-plugin-libcamera': '0.7.2',
    'plasma-camera': '26.08.1',
    'power-profiles-daemon': '0.30',
}


def pacman_package(stage, output, version):
    dependencies = ['bash', 'coreutils', 'findutils', 'systemd', 'util-linux', 'kmod',
                    'glibc', 'openssl', 'bluez', 'bluez-utils', 'networkmanager',
                    'python', 'python-gobject', 'pyside6', 'kirigami', 'kconfig',
                    'kcoreaddons', 'ki18n', 'qt6-base', 'qt6-declarative',
                    'qt6-multimedia', 'qt6-sensors', 'qt6-svg', 'exiv2',
                    'libva', 'libdrm', 'libyaml', 'libevent', 'libjpeg-turbo',
                    'libtiff', 'gnutls', 'gstreamer', 'gst-plugins-base',
                    'libqmi', 'libqrtr-glib', 'protobuf-c', 'e2fsprogs', 'libgudev',
                    'libunwind', 'hostapd', 'dnsmasq', 'nftables', 'iw', 'iproute2',
                    'polkit', 'upower', 'plasma-login-manager']
    reader = stage / 'usr/local/libexec/caihong-nvram-mac'
    dynamic = subprocess.run(['readelf', '-d', str(reader)], check=True,
                             capture_output=True, text=True).stdout
    crypto = re.search(r'\[libcrypto\.so\.(\d+)\]', dynamic)
    if crypto:
        dependencies.append(f'libcrypto.so={crypto.group(1)}-64')
    size = sum(path.lstat().st_size for path in (stage / 'usr').rglob('*')
               if path.is_file() or path.is_symlink())
    records = ['pkgname = caihong-platform', 'pkgbase = caihong-platform',
               f'pkgver = {version}-1', 'pkgdesc = Caihong device support including NPU runtime',
               'url = https://github.com/Osilvfe/caihong-linux-rootfs',
               f'builddate = {os.environ.get("SOURCE_DATE_EPOCH", str(int(time.time())))}',
               f'size = {size}', 'arch = aarch64', 'license = LicenseRef-Caihong-Bundle']
    records.extend(f'depend = {name}' for name in dependencies)
    for name, provided_version in COMPONENTS.items():
        provided = f'{name}={provided_version}' if provided_version else name
        records.extend((f'provides = {provided}', f'conflict = {name}', f'replaces = {name}'))
    records.extend(('provides = libcamera.so=0.7-64',
                    'provides = libcamera-base.so=0.7-64',
                    'conflict = sddm', 'conflict = sddm-kcm'))
    (stage / '.PKGINFO').write_text('\n'.join(records) + '\n')
    shutil.copy2(PROJECT / 'packaging/caihong-platform/caihong-platform.install', stage / '.INSTALL')
    subprocess.run(['bsdtar', '--uid', '0', '--gid', '0', '--format=mtree',
                    '--options=!all,use-set,type,uid,gid,mode,time,size,sha256,link',
                    '-czf', str(stage / '.MTREE'), '-C', str(stage),
                    '.PKGINFO', '.INSTALL', 'usr'], check=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix='platform-tar.') as temporary:
        archive = Path(temporary) / 'package.tar'
        subprocess.run(['bsdtar', '--uid', '0', '--gid', '0', '--uname', 'root',
                        '--gname', 'root', '-cf', str(archive), '-C', str(stage),
                        '.PKGINFO', '.INSTALL', '.MTREE', 'usr'], check=True)
        subprocess.run(['zstd', '-q', '-T' + os.environ.get('ZSTD_THREADS', '1'), '-15', '-f', str(archive),
                        '-o', str(output)], check=True)


def rpm_package(stage, output, version):
    with tempfile.TemporaryDirectory(dir=output.parent, prefix='platform-rpm.') as temporary:
        top = Path(temporary)
        for name in ('BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS'):
            (top / name).mkdir()
        conflicts = ['libcamera', 'libcamera-ipa', 'libcamera-tools',
                     'gstreamer1-plugin-libcamera', 'plasma-camera', 'power-profiles-daemon']
        metadata = '\n'.join(f'Provides: {name} = {COMPONENTS.get(name, "0.7.2")}'
                             for name in conflicts)
        metadata += '\n' + '\n'.join(f'Obsoletes: {name}' for name in conflicts)
        metadata += '\n' + '\n'.join(f'Conflicts: {name}' for name in conflicts)
        private_sonames = set()
        for library in (stage / 'usr/lib/caihong-adbd').glob('*.so*'):
            if library.is_symlink() or not library.is_file():
                continue
            dynamic = subprocess.check_output(['readelf', '-d', str(library)], text=True)
            private_sonames.update(re.findall(r'\(SONAME\).*\[([^\]]+)\]', dynamic))
        if private_sonames:
            pattern = '|'.join(re.escape(name).replace(r'\.', '[.]')
                               for name in sorted(private_sonames))
            metadata += f'\n%global __requires_exclude ^({pattern})([(].*[)])?$'
        files = []
        for path in sorted(stage.rglob('*')):
            if path.is_symlink() or path.is_file():
                relative = str(path.relative_to(stage))
                if any(character.isspace() for character in relative) or '%' in relative:
                    raise ValueError(f'unsupported RPM path: {relative}')
                files.append('/' + relative)
            elif path.is_dir():
                relative = str(path.relative_to(stage))
                if relative not in ('usr', 'usr/bin', 'usr/lib', 'usr/lib64', 'usr/share',
                                     'usr/local', 'usr/local/bin', 'usr/local/sbin',
                                     'usr/local/lib', 'usr/local/libexec', 'usr/libexec'):
                    files.append('%dir /' + relative)
        spec = top / 'SPECS/caihong-platform.spec'
        spec.write_text(f'''Name: caihong-platform
Version: {version}
Release: 1
Summary: Caihong device support including NPU runtime
License: LicenseRef-Caihong-Bundle
URL: https://github.com/Osilvfe/caihong-linux-rootfs
BuildArch: aarch64
Requires: bash, coreutils, findutils, systemd, util-linux
Requires: python3, python3-gobject, bluez, NetworkManager
Requires: kmod, e2fsprogs, hostapd, dnsmasq, nftables, iw, iproute
Provides: libcdsprpc.so()(64bit)
{metadata}
%global _build_id_links none
%global __os_install_post %{{nil}}
%global __requires_exclude_from ^/usr/(share/caihong-npu/dsp|share/caihong-ssc/root|lib/dsp|lib/firmware)/.*$
%global __provides_exclude_from ^/usr/(share/caihong-npu/dsp|share/caihong-ssc/root|lib/dsp|lib/firmware|lib/caihong-adbd)/.*$

%description
Caihong firmware, camera, audio, sensors, board services and Qualcomm NPU runtime.

%install
mkdir -p %{{buildroot}}
cp -a "{stage}"/. %{{buildroot}}/

%posttrans
/usr/libexec/caihong-platform/configure-platform

%files
%defattr(-,root,root,-)
{chr(10).join(files)}
''')
        subprocess.run(['rpmbuild', '-bb', '--target', 'aarch64', '--define',
                        f'_topdir {top}', '--define', f'_tmppath {top}',
                        '--define', f'_dbpath {top}/rpmdb', str(spec)], check=True)
        packages = list((top / 'RPMS').rglob('caihong-platform-*.rpm'))
        if len(packages) != 1:
            raise RuntimeError('expected exactly one caihong-platform RPM')
        shutil.copy2(packages[0], output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', type=Path)
    parser.add_argument('release', type=Path)
    parser.add_argument('--distribution', choices=('archlinuxarm', 'armada'), required=True)
    parser.add_argument('--version', required=True)
    arguments = parser.parse_args()
    stage = arguments.stage.resolve()
    release = arguments.release.resolve()
    release.mkdir(parents=True, exist_ok=True)
    version = re.sub(r'[^A-Za-z0-9.+]', '.', arguments.version)
    if not version or not version[0].isalnum():
        raise ValueError('invalid platform version')
    if not (stage / 'usr/share/caihong-npu/VERSION').is_file():
        raise ValueError('the platform package must contain the NPU runtime')
    assets = stage / 'usr/share/caihong-platform'
    assets.mkdir(parents=True, exist_ok=True)
    defaults = assets / 'defaults'
    defaults.mkdir(exist_ok=True)
    if (stage / 'etc').exists():
        shutil.move(str(stage / 'etc'), defaults / 'etc')
    ucm = Path('usr/share/alsa/ucm2/conf.d/sm8650/SM8650-MTP.conf')
    if (stage / ucm).exists():
        (defaults / ucm).parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(stage / ucm), defaults / ucm)
    for name in ('configure-platform', 'switch-display-manager.sh'):
        destination = stage / 'usr/libexec/caihong-platform' / name.removesuffix('.sh')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(PROJECT / 'packaging/caihong-platform' / name, destination)
        destination.chmod(0o755)
    (assets / 'version').write_text(arguments.version + '\n')
    if arguments.distribution == 'archlinuxarm':
        output = release / f'caihong-platform-{version}-1-aarch64.pkg.tar.zst'
        pointer = 'CAIHONG_PLATFORM_PACKAGE_ARCHLINUXARM'
        build = pacman_package
    else:
        output = release / f'caihong-platform-{version}-1.aarch64.rpm'
        pointer = 'CAIHONG_PLATFORM_PACKAGE_ARMADA'
        build = rpm_package
    temporary = output.with_name(output.name + '.new')
    try:
        build(stage, temporary, version)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    (release / pointer).write_text(output.name + '\n')
    print(f'created native platform package: {output}')


if __name__ == '__main__':
    main()
