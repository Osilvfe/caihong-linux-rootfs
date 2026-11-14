import hashlib
import importlib.util
from pathlib import Path
import re
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / 'scripts'))
SPEC = importlib.util.spec_from_file_location('platform_verifier', PROJECT / 'scripts/verify-platform-packages.py')
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class PlatformManifestTests(unittest.TestCase):
    def test_camera_policy_preserves_native_and_usb_cameras(self):
        policy = (PROJECT / 'rootfs/archlinuxarm/usr/share/wireplumber/wireplumber.conf.d/90-caihong-camera.conf').read_text()
        patterns = re.findall(r'device\.name = "~([^"]+)"', policy)
        self.assertEqual(len(patterns), 3)
        for name in ('v4l2_device.platform-acb6000.isp',
                     'v4l2_device.platform-ac01000.remoteproc',
                     'v4l2_device.platform-aa00000.video-codec.2'):
            self.assertTrue(any(re.match(pattern, name) for pattern in patterns), name)
        for name in ('v4l2_device.usb-webcam', 'v4l2_device.platform-caihong-camera-native',
                     'libcamera_device./base/soc@0/cci@ac15000/i2c-bus@1/camera@36'):
            self.assertFalse(any(re.match(pattern, name) for pattern in patterns), name)

    def test_all_sensor_modes_have_verified_bps_tables(self):
        firmware = PROJECT / 'firmware'
        checksums = {line.split()[1].removeprefix('./'): line.split()[0]
                     for line in (firmware / 'SHA256SUMS').read_text().splitlines()}
        for size in ('640x480', '1632x1224', '2104x1560', '3264x2448', '4208x3120'):
            relative = f'qcom/sm8650/bps-striping-bggr10-nv12-{size}.bin'
            self.assertEqual(hashlib.sha256((firmware / relative).read_bytes()).hexdigest(),
                             checksums[relative])
            for distribution in ('archlinuxarm', 'armada'):
                self.assertIn('usr/lib/firmware/' + relative,
                              VERIFIER.source_paths(PROJECT, distribution))

    def test_source_manifest_covers_overlays_firmware_and_ssc(self):
        output = PROJECT.parent / 'build/caihong-platform-manifest-tests'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output) as temporary:
            project = Path(temporary)
            for relative in (
                'rootfs/archlinuxarm/etc/caihong-test.conf',
                'rootfs/archlinuxarm/etc/sudoers.d/10-alarm',
                'rootfs/archlinuxarm/usr/local/sbin/caihong-test',
                'rootfs/archlinuxarm/usr/share/alsa/ucm2/conf.d/sm8650/SM8650-MTP.conf',
                'rootfs/armada/etc/caihong-armada.conf',
                'firmware/qcom/test.bin', 'firmware/SOURCE.md',
                'firmware/SHA256SUMS', 'firmware/regulatory.db',
                'firmware-assets/caihong-ssc/root/sensors/test',
            ):
                path = project / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('test')
            link = project / 'rootfs/archlinuxarm/etc/systemd/system/test.service'
            link.parent.mkdir(parents=True)
            link.symlink_to('/usr/lib/systemd/system/test.service')
            for distribution in ('archlinuxarm', 'armada'):
                with self.subTest(distribution=distribution):
                    paths = VERIFIER.source_paths(project, distribution)
                    prefix = 'usr/share/caihong-platform/defaults/'
                    self.assertIn(prefix + 'etc/caihong-test.conf', paths)
                    self.assertIn(prefix + 'etc/systemd/system/test.service', paths)
                    self.assertIn(prefix + 'usr/share/alsa/ucm2/conf.d/sm8650/SM8650-MTP.conf', paths)
                    self.assertIn('usr/local/sbin/caihong-test', paths)
                    self.assertIn('usr/lib/firmware/qcom/test.bin', paths)
                    self.assertIn('usr/share/caihong-ssc/root/sensors/test', paths)
                    self.assertNotIn('usr/lib/firmware/regulatory.db', paths)
                    self.assertNotIn('usr/lib/firmware/SOURCE.md', paths)
                    self.assertNotIn('usr/lib/firmware/SHA256SUMS', paths)
                    self.assertEqual(prefix + 'etc/caihong-armada.conf' in paths,
                                     distribution == 'armada')
                    self.assertEqual(prefix + 'etc/sudoers.d/10-alarm' in paths,
                                     distribution == 'archlinuxarm')

    def test_missing_runtime_dependency_is_rejected_for_both_distributions(self):
        for distribution, dependencies in VERIFIER.RUNTIME_PACKAGES.items():
            with self.subTest(distribution=distribution):
                prefix = 'depend = ' if distribution == 'archlinuxarm' else ''
                metadata = '\n'.join(prefix + dependency for dependency in dependencies)
                VERIFIER.verify_dependencies(metadata, distribution)
                for dependency in dependencies:
                    with self.assertRaisesRegex(ValueError, dependency):
                        VERIFIER.verify_dependencies('\n'.join(
                            prefix + name for name in dependencies if name != dependency), distribution)


if __name__ == '__main__':
    unittest.main()
