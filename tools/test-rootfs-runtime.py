from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
CONFIGURE = PROJECT / 'packaging/caihong-platform/configure-platform'


class PlatformConfigurationTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-runtime-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.defaults = self.root / 'usr/share/caihong-platform/defaults'
        self.pending = self.root / 'var/lib/caihong-config-pending/caihong-platform'
        self.environment = dict(os.environ, CAIHONG_PLATFORM_ROOT=str(self.root),
                                CAIHONG_PLATFORM_SKIP_DISPLAY_MANAGER='1')
        self.write(self.defaults, 'etc/caihong-test.conf', 'candidate configuration\n')
        self.write(self.defaults, 'etc/systemd/system/caihong-test.service', 'candidate unit\n')
        link = self.defaults / 'etc/systemd/system/multi-user.target.wants/caihong-test.service'
        link.parent.mkdir(parents=True)
        link.symlink_to('../caihong-test.service')
        helper = self.root / 'usr/libexec/caihong-platform/switch-display-manager'
        helper.parent.mkdir(parents=True)
        shutil.copy2(PROJECT / 'packaging/caihong-platform/switch-display-manager.sh', helper)
        helper.chmod(0o755)

    def write(self, root, relative, contents):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def configure(self):
        result = subprocess.run(['sh', str(CONFIGURE)], env=self.environment,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fresh_install_initializes_default_configuration(self):
        self.configure()
        self.assertEqual((self.root / 'etc/caihong-test.conf').read_text(), 'candidate configuration\n')
        self.assertTrue((self.root / 'etc/systemd/system/multi-user.target.wants/caihong-test.service').is_symlink())

    def test_updates_preserve_configuration_and_disabled_services(self):
        self.configure()
        self.write(self.root, 'etc/caihong-test.conf', 'user configuration\n')
        (self.root / 'etc/systemd/system/multi-user.target.wants/caihong-test.service').unlink()
        self.configure()
        self.assertEqual((self.root / 'etc/caihong-test.conf').read_text(), 'user configuration\n')
        self.assertFalse((self.root / 'etc/systemd/system/multi-user.target.wants/caihong-test.service').is_symlink())
        self.assertEqual((self.root / 'etc/caihong-test.conf.caihong-new').read_text(), 'candidate configuration\n')
        self.assertTrue((self.pending / 'etc/systemd/system/multi-user.target.wants/caihong-test.service').is_symlink())
        self.assertFalse(list((self.root / 'etc/systemd').rglob('*.caihong-new')))

    def test_legacy_installation_preserves_existing_policy(self):
        self.write(self.root, 'var/lib/caihong-packages/caihong-platform/version', 'legacy\n')
        self.write(self.root, 'etc/caihong-test.conf', 'original\n')
        self.configure()
        self.assertEqual((self.root / 'etc/caihong-test.conf').read_text(), 'original\n')
        self.assertFalse((self.root / 'etc/systemd/system/multi-user.target.wants/caihong-test.service').is_symlink())

    def test_image_build_applies_defaults_without_dm_migration(self):
        self.environment['CAIHONG_PLATFORM_IMAGE_BUILD'] = '1'
        self.write(self.root, 'etc/caihong-test.conf', 'original\n')
        self.configure()
        self.assertEqual((self.root / 'etc/caihong-test.conf').read_text(), 'candidate configuration\n')

    def test_ssc_calibration_is_preserved_and_missing_defaults_are_seeded(self):
        seed = self.root / 'usr/share/caihong-ssc/root'
        state = self.root / 'var/lib/caihong-ssc/root'
        self.write(seed, 'registry/calibration', 'default\n')
        self.write(state, 'registry/calibration', 'calibrated\n')
        self.write(seed, 'sensors/sns_reg.conf', 'sensor configuration\n')
        self.configure()
        self.assertEqual((state / 'registry/calibration').read_text(), 'calibrated\n')
        self.assertEqual((state / 'sensors/sns_reg.conf').read_text(), 'sensor configuration\n')

    def test_obsolete_installer_and_alsa_daemon_are_removed(self):
        self.write(self.root, 'usr/libexec/caihong-platform/install-caihong-platform', 'legacy\n')
        self.write(self.root, 'etc/alsa/state-daemon.conf', 'legacy\n')
        self.configure()
        self.assertFalse((self.root / 'usr/libexec/caihong-platform/install-caihong-platform').exists())
        self.assertFalse((self.root / 'etc/alsa/state-daemon.conf').exists())


class RealtimeDependencyTests(unittest.TestCase):
    def test_rtkit_is_installed_and_verified(self):
        for relative in ('scripts/package-archlinuxarm-rootfs.sh',
                         'scripts/verify-archlinuxarm-rootfs.sh'):
            self.assertIn('rtkit', (PROJECT / relative).read_text())


if __name__ == '__main__':
    unittest.main()
