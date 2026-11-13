import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class NativePlatformPackageTests(unittest.TestCase):
    def test_both_native_packages_include_npu_and_complete_ssc_defaults(self):
        output = PROJECT.parent / 'build/caihong-ssc-package-tests'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output) as temporary:
            work = Path(temporary)
            project = work / 'project'
            scripts = project / 'scripts'
            scripts.mkdir(parents=True)
            for name in ('build-caihong-platform-package.sh', 'package-caihong-platform.py'):
                shutil.copy2(PROJECT / 'scripts' / name, scripts)
            for directory in ('scripts/ssc', 'packaging/caihong-platform',
                              'rootfs/archlinuxarm', 'rootfs/armada'):
                shutil.copytree(PROJECT / directory, project / directory, symlinks=True)
            for name in (
                'caihong-build-root.sh', 'install-caihong-toolbox-rootfs.sh',
                'install-caihong-vaapi-stage.sh', 'install-caihong-libcamera-stage.sh',
                'install-caihong-plasma-camera-stage.sh', 'install-caihong-qbootctl-stage.sh',
                'install-caihong-ppd-stage.sh',
            ):
                helper = scripts / name
                helper.write_text('#!/bin/sh\nexit 0\n')
                helper.chmod(0o755)
            utilities = scripts / 'install-caihong-utilities-stage.sh'
            utilities.write_text('#!/bin/sh\nmkdir -p "$1/usr/local/libexec"\n'
                                 'cp /usr/bin/true "$1/usr/local/libexec/caihong-nvram-mac"\n')
            utilities.chmod(0o755)
            adbd = scripts / 'install-caihong-adbd.sh'
            adbd.write_text('''#!/bin/sh
set -eu
mkdir -p "$1/usr/lib/caihong-adbd" "$1/usr/bin"
cc -shared -fPIC -Wl,-soname,libbase.so.0 -x c - \\
    -o "$1/usr/lib/caihong-adbd/libbase.so.0" <<'SOURCE'
int caihong_private_test(void) { return 0; }
SOURCE
cc -x c - -x none "$1/usr/lib/caihong-adbd/libbase.so.0" \\
    -o "$1/usr/bin/adbd" <<'SOURCE'
int caihong_private_test(void);
int main(void) { return caihong_private_test(); }
SOURCE
''')
            adbd.chmod(0o755)
            npu = scripts / 'install-caihong-npu.sh'
            npu.write_text('#!/bin/sh\nmkdir -p "$2/usr/share/caihong-npu" "$2/usr/$3/caihong-npu/qnn"\n'
                           'printf "QAIRT/QNN test\\n" > "$2/usr/share/caihong-npu/VERSION"\n'
                           'printf "NPU runtime\\n" > "$2/usr/$3/caihong-npu/qnn/libQnnHtp.so"\n')
            npu.chmod(0o755)
            topology = scripts / 'build-caihong-audioreach-topology.sh'
            topology.write_text('#!/bin/sh\nprintf topology > "$1"\n')
            topology.chmod(0o755)
            firmware = project / 'firmware/qcom/sm8650/SM8650-MTP-tplg.bin'
            firmware.parent.mkdir(parents=True)
            firmware.write_bytes(b'topology')
            for name in ('regulatory.db', 'regulatory.db.p7s'):
                (project / 'firmware' / name).write_text('distribution owned\n')
            (project / 'firmware/SHA256SUMS').write_text(
                hashlib.sha256(firmware.read_bytes()).hexdigest() +
                '  qcom/sm8650/SM8650-MTP-tplg.bin\n')
            bundle = project / 'firmware-assets/caihong-ssc'
            defaults = ('sensors/sns_reg.conf', 'sensors/persist/registry/test',
                        'dsp/adsp/test.so', 'socinfo/soc_id')
            for relative in ('VERSION', 'bin/hexagonrpcd', 'bin/iio-sensor-proxy',
                             'lib/libhexagonrpc.so.0.5', 'lib/libssc.so.2',
                             *(f'root/{path}' for path in defaults)):
                path = bundle / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(relative + '\n')
            (project / 'modules-current/lib/modules/test').mkdir(parents=True)
            environment = dict(os.environ, CAIHONG_PLATFORM_VERSION='test',
                               KERNEL_RELEASE='test', CAIHONG_BUILD_ROOT=str(project / 'build-root'))
            release = project / 'release'
            for distribution, libdir in (('archlinuxarm', 'lib'), ('armada', 'lib64')):
                with self.subTest(distribution=distribution):
                    if distribution == 'armada' and not shutil.which('rpmbuild'):
                        self.fail('rpmbuild is required to validate the native Armada package')
                    environment.update(DISTRIBUTION=distribution, LIBDIR=libdir)
                    result = subprocess.run(
                        ['sh', str(scripts / 'build-caihong-platform-package.sh'), str(release)],
                        env=environment, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    pointer = release / ('CAIHONG_PLATFORM_PACKAGE_' + distribution.upper())
                    archive = release / pointer.read_text().strip()
                    root = work / distribution
                    root.mkdir()
                    if distribution == 'archlinuxarm':
                        self.assertTrue(archive.name.endswith('-aarch64.pkg.tar.zst'))
                        subprocess.run(['bsdtar', '-xf', str(archive), '-C', str(root)], check=True)
                        metadata = (root / '.PKGINFO').read_text()
                        self.assertIn('pkgname = caihong-platform\n', metadata)
                        self.assertIn('conflict = sddm\n', metadata)
                        self.assertIn('depend = plasma-login-manager\n', metadata)
                        self.assertIn('depend = wireless-regdb\n', metadata)
                        self.assertIn('depend = rtkit\n', metadata)
                        self.assertTrue((root / '.INSTALL').is_file())
                        self.assertIn('/usr/libexec/caihong-platform/configure-platform',
                                      (root / '.INSTALL').read_text())
                    else:
                        self.assertTrue(archive.name.endswith('-1.aarch64.rpm'))
                        metadata = subprocess.check_output(
                            ['rpm', '-qp', '--queryformat', '%{NAME} %{ARCH}', str(archive)], text=True)
                        self.assertEqual(metadata, 'caihong-platform aarch64')
                        for query in ('--requires', '--provides'):
                            dependencies = subprocess.check_output(
                                ['rpm', '-qp', query, str(archive)], text=True)
                            self.assertNotIn('libbase.so.0', dependencies)
                        self.assertIn('libc.so.6', subprocess.check_output(
                            ['rpm', '-qp', '--requires', str(archive)], text=True))
                        self.assertIn('wireless-regdb', subprocess.check_output(
                            ['rpm', '-qp', '--requires', str(archive)], text=True))
                        self.assertIn('rtkit', subprocess.check_output(
                            ['rpm', '-qp', '--requires', str(archive)], text=True))
                        self.assertIn('tuned-ppd', subprocess.check_output(
                            ['rpm', '-qp', '--conflicts', str(archive)], text=True))
                        self.assertIn('tuned-ppd', subprocess.check_output(
                            ['rpm', '-qp', '--obsoletes', str(archive)], text=True))
                        self.assertIn('ppd-service', subprocess.check_output(
                            ['rpm', '-qp', '--provides', str(archive)], text=True))
                        self.assertIn('/usr/libexec/caihong-platform/configure-platform',
                                      subprocess.check_output(['rpm', '-qp', '--scripts', str(archive)], text=True))
                        with subprocess.Popen(['rpm2cpio', str(archive)], stdout=subprocess.PIPE) as source:
                            subprocess.run(['bsdtar', '-xf', '-', '-C', str(root)],
                                           stdin=source.stdout, check=True)
                            source.stdout.close()
                            self.assertEqual(source.wait(), 0)
                    self.assertFalse((root / 'etc').exists())
                    for name in ('regulatory.db', 'regulatory.db.p7s'):
                        self.assertFalse((root / 'usr/lib/firmware' / name).exists())
                    self.assertFalse((root / 'usr/libexec/caihong-platform/install-caihong-platform').exists())
                    self.assertEqual((root / f'usr/{libdir}/caihong-npu/qnn/libQnnHtp.so').read_text(), 'NPU runtime\n')
                    self.assertEqual((root / 'usr/share/caihong-npu/libdir').read_text(), libdir + '\n')
                    self.assertIn('0755\tusr/share/caihong-ssc/root\n',
                                  (root / 'usr/share/caihong-platform/directory-modes').read_text())
                    environment.update(CAIHONG_PLATFORM_ROOT=str(root), CAIHONG_PLATFORM_IMAGE_BUILD='1')
                    subprocess.run(['sh', str(root / 'usr/libexec/caihong-platform/configure-platform')],
                                   env=environment, check=True)
                    environment.pop('CAIHONG_PLATFORM_ROOT')
                    environment.pop('CAIHONG_PLATFORM_IMAGE_BUILD')
                    for relative in defaults:
                        for prefix in ('usr/share/caihong-ssc/root', 'var/lib/caihong-ssc/root'):
                            self.assertEqual((root / prefix / relative).read_bytes(),
                                             (bundle / 'root' / relative).read_bytes())
                    legacy = root / 'var/lib/caihong-packages/caihong-platform/version'
                    legacy.parent.mkdir(parents=True)
                    legacy.write_text('legacy\n')
                    directory = root / 'usr/share/caihong-ssc/root'
                    directory.chmod(0o700)
                    candidate = root / 'etc/systemd/system/caihong-legacy.service.caihong-new'
                    candidate.write_text('legacy candidate\n')
                    fakebin = work / ('tools-' + distribution)
                    fakebin.mkdir()
                    (fakebin / 'chown').write_text('#!/bin/sh\nexit 0\n')
                    (fakebin / 'chown').chmod(0o755)
                    environment.update(CAIHONG_PLATFORM_ROOT=str(root), CAIHONG_PLATFORM_IMAGE_BUILD='0',
                                       PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
                    subprocess.run(['sh', str(root / 'usr/libexec/caihong-platform/configure-platform')],
                                   env=environment, check=True)
                    self.assertEqual(directory.stat().st_mode & 0o777, 0o755)
                    self.assertFalse(candidate.exists())
                    self.assertTrue((root / 'var/lib/caihong-platform/legacy-native-migration-v1').is_file())
                    directory.chmod(0o700)
                    subprocess.run(['sh', str(root / 'usr/libexec/caihong-platform/configure-platform')],
                                   env=environment, check=True)
                    self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                    for name in ('CAIHONG_PLATFORM_ROOT', 'CAIHONG_PLATFORM_IMAGE_BUILD'):
                        environment.pop(name)
                    environment['PATH'] = os.environ['PATH']


if __name__ == '__main__':
    unittest.main()
