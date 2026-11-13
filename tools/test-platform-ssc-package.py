import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class PlatformSscPackageTests(unittest.TestCase):
    def test_both_platform_packages_install_complete_ssc_defaults(self):
        output = PROJECT.parent / 'build/caihong-ssc-package-tests'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output) as temporary:
            work = Path(temporary)
            project = work / 'project'
            scripts = project / 'scripts'
            scripts.mkdir(parents=True)
            shutil.copy2(PROJECT / 'scripts/build-caihong-platform-package.sh', scripts)
            for directory in ('scripts/ssc', 'packaging/caihong-platform',
                              'rootfs/archlinuxarm', 'rootfs/armada'):
                shutil.copytree(PROJECT / directory, project / directory, symlinks=True)
            for name in (
                'caihong-build-root.sh', 'install-caihong-toolbox-rootfs.sh',
                'install-caihong-vaapi-stage.sh', 'install-caihong-libcamera-stage.sh',
                'install-caihong-plasma-camera-stage.sh', 'install-caihong-qbootctl-stage.sh',
                'install-caihong-utilities-stage.sh', 'install-caihong-ppd-stage.sh',
                'install-caihong-adbd.sh',
            ):
                helper = scripts / name
                helper.write_text('#!/bin/sh\nexit 0\n')
                helper.chmod(0o755)
            topology = scripts / 'build-caihong-audioreach-topology.sh'
            topology.write_text('#!/bin/sh\nprintf topology > "$1"\n')
            topology.chmod(0o755)
            firmware = project / 'firmware/qcom/sm8650/SM8650-MTP-tplg.bin'
            firmware.parent.mkdir(parents=True)
            firmware.write_bytes(b'topology')
            (project / 'firmware/SHA256SUMS').write_text(
                hashlib.sha256(firmware.read_bytes()).hexdigest() +
                '  qcom/sm8650/SM8650-MTP-tplg.bin\n')
            bundle = project / 'firmware-assets/caihong-ssc'
            defaults = (
                'sensors/sns_reg.conf', 'sensors/persist/registry/test',
                'dsp/adsp/test.so', 'socinfo/soc_id',
            )
            for relative in (
                'VERSION', 'bin/hexagonrpcd', 'bin/iio-sensor-proxy',
                'lib/libhexagonrpc.so.0.5', 'lib/libssc.so.2',
                *(f'root/{path}' for path in defaults),
            ):
                path = bundle / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(relative + '\n')
            (project / 'modules-current/lib/modules/test').mkdir(parents=True)
            scratch = work / 'scratch'
            scratch.mkdir()
            environment = dict(os.environ, CAIHONG_PLATFORM_VERSION='test',
                               KERNEL_RELEASE='test', TMPDIR=str(scratch),
                               CAIHONG_BUILD_ROOT=str(project / 'build-root'))
            release = project / 'release'
            for distribution, libdir in (('archlinuxarm', 'lib'), ('armada', 'lib64')):
                with self.subTest(distribution=distribution):
                    environment.update(DISTRIBUTION=distribution, LIBDIR=libdir)
                    result = subprocess.run(
                        ['sh', str(scripts / 'build-caihong-platform-package.sh'),
                         str(release)], env=environment, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    archive = release / f'caihong-platform-{distribution}-test.tar.zst'
                    root = work / distribution
                    root.mkdir()
                    environment.update(CAIHONG_PLATFORM_ROOT=str(root),
                                       CAIHONG_PLATFORM_IMAGE_BUILD='1',
                                       CAIHONG_PLATFORM_SKIP_DISPLAY_MANAGER='1')
                    result = subprocess.run(
                        ['sh', str(project / 'packaging/caihong-platform/install-caihong-platform'),
                         str(archive)], env=environment, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    for relative in defaults:
                        expected = (bundle / 'root' / relative).read_bytes()
                        for prefix in ('usr/share/caihong-ssc/root',
                                       'var/lib/caihong-ssc/root'):
                            self.assertEqual((root / prefix / relative).read_bytes(), expected)


if __name__ == '__main__':
    unittest.main()
