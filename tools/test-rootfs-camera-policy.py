from pathlib import Path
import re
import shlex
import unittest


PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = (PROJECT / 'scripts/install-caihong-libcamera-rootfs.sh').read_text()
VERIFIER = (PROJECT / 'scripts/verify-archlinuxarm-rootfs.sh').read_text()


def assignment(source, name):
    match = re.search(r"^" + re.escape(name) + r"='([^']*)'", source, re.MULTILINE)
    if not match:
        raise ValueError('missing shell assignment: ' + name)
    return set(shlex.split(match.group(1)))


def array(source, name):
    match = re.search(r'^' + re.escape(name) + r'=\((.*?)\)', source,
                      re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError('missing shell array: ' + name)
    return set(shlex.split(match.group(1)))


class RootfsCameraPolicyTests(unittest.TestCase):
    def test_removed_distribution_packages_are_not_required(self):
        removed = array(INSTALLER, 'obsolete_packages')
        required = assignment(VERIFIER, 'required_packages')
        self.assertTrue(removed)
        self.assertFalse(removed & required,
                         'verifier requires packages removed by the camera installer')

    def test_custom_camera_outputs_remain_required(self):
        outputs = {path.replace('$libdir', 'lib')
                   for path in array(INSTALLER, 'required_outputs')}
        required = assignment(VERIFIER, 'required_paths')
        self.assertTrue(outputs)
        self.assertTrue(outputs <= required, outputs - required)
        self.assertIn('usr/share/caihong/libcamera-build-info', required)

    def test_software_isp_outputs_remain_rejected(self):
        removed = array(INSTALLER, 'obsolete_outputs')
        rejected = assignment(VERIFIER, 'obsolete_camera_paths')
        self.assertTrue(removed)
        self.assertTrue(removed <= rejected, removed - rejected)

    def test_native_platform_package_owns_the_camera_stack(self):
        required = assignment(VERIFIER, 'required_packages')
        self.assertIn('caihong-platform', required)
        self.assertNotIn('gst-plugin-libcamera', required)
        self.assertNotIn('plasma-camera', required)


if __name__ == '__main__':
    unittest.main()
