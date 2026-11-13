from pathlib import Path
import re
import shlex
import unittest


PROJECT = Path(__file__).resolve().parents[1]
PLATFORM = (PROJECT / 'scripts/build-caihong-platform-package.sh').read_text()
ROOTFS = (PROJECT / 'scripts/package-archlinuxarm-rootfs.sh').read_text()
BASE = (PROJECT / 'scripts/build-archlinuxarm-rootfs.sh').read_text()
ARMADA = (PROJECT / 'scripts/package-armada-rootfs.sh').read_text()


def array(source, name):
    match = re.search(r'^' + re.escape(name) + r'=\((.*?)\)', source,
                      re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError('missing shell array: ' + name)
    return list(shlex.split(match.group(1)))


class PlatformPayloadTests(unittest.TestCase):
    def test_platform_package_builds_every_device_component(self):
        for script in (
            'install-caihong-toolbox-rootfs.sh',
            'install-caihong-vaapi-stage.sh',
            'install-caihong-libcamera-stage.sh',
            'install-caihong-plasma-camera-stage.sh',
            'install-caihong-qbootctl-stage.sh',
            'install-caihong-utilities-stage.sh',
            'install-caihong-ppd-stage.sh',
            'install-caihong-npu.sh',
        ):
            self.assertIn(script, PLATFORM)
        self.assertIn('caihong-build-root.sh" prepare', PLATFORM)
        self.assertIn('caihong-build-root.sh" cleanup', PLATFORM)

    def test_rootfs_requires_a_platform_package(self):
        self.assertIn('a Caihong platform package is required', ROOTFS)
        self.assertNotIn('CAIHONG_PLATFORM_IMAGE_BUILD=0', ROOTFS)
        self.assertIn('CAIHONG_PLATFORM_IMAGE_BUILD=1', ROOTFS)
        self.assertIn('plasma-login-manager', ROOTFS)
        self.assertIn('plasmalogin.service', ROOTFS)
        self.assertNotIn('\n\tsddm\n', ROOTFS)
        self.assertNotIn('sshd.service sddm.service', ROOTFS)

    def test_rootfs_does_not_directly_produce_device_payload(self):
        forbidden = (
            'rsync -aHAX --numeric-ids --chown=0:0 \\\n\t"$project_dir/rootfs/archlinuxarm/"',
            'install-caihong-libcamera-rootfs.sh',
            'install-caihong-plasma-camera-rootfs.sh',
            'install-caihong-toolbox-rootfs.sh',
            'install-caihong-vaapi-rootfs.sh',
            'install-caihong-adbd.sh',
            'build-caihong-audioreach-topology.sh',
        )
        for entry in forbidden:
            self.assertNotIn(entry, ROOTFS)

    def test_base_arch_rootfs_is_distribution_only(self):
        forbidden = (
            'rootfs/archlinuxarm/."',
            'install-caihong-adbd.sh',
            'build-caihong-audioreach-topology.sh',
            'ssc/install-rootfs.sh',
            '99-caihong-dma-heap.rules',
        )
        for entry in forbidden:
            self.assertNotIn(entry, BASE)

    def test_platform_payload_is_applied_in_image_build_mode(self):
        self.assertIn('CAIHONG_PLATFORM_IMAGE_BUILD=1', ROOTFS)
        self.assertIn('pacman -U --noconfirm', ROOTFS)

    def test_platform_package_contains_camera_and_qbootctl(self):
        verifier = (PROJECT / 'scripts/verify-platform-packages.py').read_text()
        for path in (
            'usr/bin/plasma-camera',
            'usr/bin/cam',
            'usr/bin/qcam',
            'libcamera.so.0.7',
            'gstreamer-1.0/libgstlibcamera.so',
            'usr/local/sbin/qbootctl',
            'usr/lib/power-profiles-daemon',
        ):
            self.assertIn(path, verifier)

    def test_armada_payload_uses_lib64(self):
        release = (PROJECT / '.github/workflows/release.yml').read_text()
        kernel = (PROJECT / '.github/workflows/kernel-package.yml').read_text()
        self.assertIn('DISTRIBUTION=armada LIBDIR=lib64', release)
        self.assertIn('DISTRIBUTION=armada LIBDIR=lib64', kernel)

    def test_armada_payload_has_no_arch_only_toolbox_or_sudoers(self):
        self.assertIn('rm -f -- "$stage/etc/sudoers.d/10-alarm"',
                      PLATFORM)
        branch = PLATFORM.split('if [ "$distribution" = archlinuxarm ] ||', 1)[1]
        self.assertIn('if [ "$distribution" = archlinuxarm ]; then', branch)
        self.assertIn('install-caihong-toolbox-rootfs.sh', branch)

    def test_platform_jobs_have_the_build_root_dependencies(self):
        kernel = (PROJECT / '.github/workflows/kernel-package.yml').read_text()
        self.assertIn('skopeo', kernel)
        self.assertIn('umoci', kernel)
        root = (PROJECT / 'scripts/caihong-build-root.sh').read_text()
        self.assertIn('libva-devel', root)
        self.assertIn('libtiff-devel', root)

    def test_armada_image_installs_the_same_platform_payload(self):
        self.assertIn('CAIHONG_PLATFORM_IMAGE_BUILD=1', ARMADA)
        self.assertIn('dnf5 -y install --allowerasing', ARMADA)
        self.assertNotIn('dnf5 -y --allowerasing install', ARMADA)
        for entry in (
            'rootfs/archlinuxarm/."',
            'rootfs/armada/."',
            'install-caihong-libcamera-rootfs.sh',
            'install-caihong-plasma-camera-rootfs.sh',
            'install-caihong-adbd.sh',
            'build-caihong-audioreach-topology.sh',
            'ssc/install-rootfs.sh',
        ):
            self.assertNotIn(entry, ARMADA)

    def test_armada_requires_a_platform_package(self):
        self.assertIn('missing Armada platform package pointer', ARMADA)

    def test_armada_verifier_uses_the_target_rpm_database(self):
        verifier = (PROJECT / 'scripts/verify-armada-rootfs.sh').read_text()
        self.assertIn('chroot "$target" rpm -q caihong-platform', verifier)
        self.assertNotIn('rpm --root "$target"', verifier)

    def test_arch_verifies_distribution_regulatory_data_separately(self):
        verifier = (PROJECT / 'scripts/verify-archlinuxarm-rootfs.sh').read_text()
        self.assertIn('pacman -Qkk wireless-regdb', verifier)
        self.assertIn('$2 != "./regulatory.db" && $2 != "./regulatory.db.p7s"', verifier)

    def test_no_standalone_npu_delivery_remains(self):
        for relative in ('scripts/package-archlinuxarm-rootfs.sh',
                         'scripts/package-armada-rootfs.sh',
                         '.github/workflows/release.yml',
                         '.github/workflows/kernel-package.yml'):
            contents = (PROJECT / relative).read_text()
            self.assertNotIn('CAIHONG_NPU_PACKAGE', contents)
            self.assertNotIn('build-caihong-npu-package.sh', contents)


if __name__ == '__main__':
    unittest.main()
