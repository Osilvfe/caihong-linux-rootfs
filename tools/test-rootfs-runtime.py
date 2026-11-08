import hashlib
from pathlib import Path
import os
import re
import shlex
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / 'packaging/caihong-platform/install-caihong-platform'


class PlatformInstallerTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-runtime-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.root = self.work / 'root'
        self.payload = self.work / 'payload'
        self.root.mkdir()
        self.payload.mkdir()
        self.scratch = self.work / 'scratch'
        self.scratch.mkdir()
        self.environment = dict(os.environ, CAIHONG_PLATFORM_ROOT=str(self.root),
                                TMPDIR=str(self.scratch))
        self.pending = self.root / 'var/lib/caihong-config-pending/caihong-test'
        self.unit = 'etc/systemd/system/caihong-test.service'
        self.link = 'etc/systemd/system/multi-user.target.wants/caihong-test.service'
        self.configuration = 'etc/caihong-test.conf'
        self.program = 'usr/local/libexec/caihong-test'
        self.write(self.root, self.unit, 'original unit\n')
        self.write(self.root, self.configuration, 'original configuration\n')
        self.write(self.root, self.program, 'original program\n')
        self.write(self.payload, self.unit, 'candidate unit\n')
        self.write(self.payload, self.configuration, 'candidate configuration\n')
        self.write(self.payload, self.program, 'candidate program\n')
        dependency = self.payload / self.link
        dependency.parent.mkdir(parents=True)
        dependency.symlink_to('../caihong-test.service')
        for name, contents in (('architecture', 'aarch64'), ('package', 'caihong-test'),
                               ('version', 'test-1')):
            self.write(self.payload, 'usr/share/caihong-package/' + name, contents + '\n')

    def write(self, root, relative, contents):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def package(self):
        paths = sorted(path for directory in ('usr', 'etc')
                       for path in (self.payload / directory).rglob('*')
                       if path.is_symlink() or path.is_file())
        lines = []
        for path in paths:
            contents = (str(path.readlink()) + '\n').encode() if path.is_symlink() else path.read_bytes()
            lines.append(hashlib.sha256(contents).hexdigest() + '  ./' + str(path.relative_to(self.payload)))
        (self.payload / 'manifest').write_text('\n'.join(lines) + '\n')
        archive = self.work / 'package.tar'
        subprocess.run(['bsdtar', '-cf', str(archive), '-C', str(self.payload),
                        'manifest', 'usr', 'etc'], check=True, capture_output=True)
        return archive

    def run_installer(self, *arguments):
        return subprocess.run(['sh', str(INSTALLER), *map(str, arguments)],
                              env=self.environment, text=True, capture_output=True)

    def install(self):
        result = self.run_installer(self.package())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_systemd_candidates_do_not_enter_active_scan_paths(self):
        self.install()
        self.assertEqual((self.root / self.unit).read_text(), 'original unit\n')
        self.assertFalse((self.root / self.link).is_symlink())
        self.assertFalse(list((self.root / 'etc/systemd').rglob('*.caihong-new')))
        self.assertEqual((self.pending / self.unit).read_text(), 'candidate unit\n')
        self.assertEqual(str((self.pending / self.link).readlink()), '../caihong-test.service')
        self.assertEqual((self.pending / self.link).read_text(), 'candidate unit\n')

    def test_other_configuration_keeps_explicit_review_policy(self):
        self.install()
        self.assertEqual((self.root / self.configuration).read_text(), 'original configuration\n')
        candidate = self.root / (self.configuration + '.caihong-new')
        self.assertEqual(candidate.read_text(), 'candidate configuration\n')

    def test_existing_service_enablement_is_preserved(self):
        existing = self.root / self.link
        existing.parent.mkdir(parents=True)
        existing.symlink_to('../original.service')
        self.install()
        self.assertEqual(str(existing.readlink()), '../original.service')
        self.assertTrue((self.pending / self.link).is_symlink())
        self.assertEqual(str((self.pending / self.link).readlink()), '../caihong-test.service')

    def test_rollback_restores_program_and_previous_pending_configuration(self):
        self.write(self.pending, self.unit, 'previous candidate\n')
        self.install()
        result = self.run_installer('--rollback', 'caihong-test')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / self.program).read_text(), 'original program\n')
        self.assertEqual((self.root / self.unit).read_text(), 'original unit\n')
        self.assertEqual((self.pending / self.unit).read_text(), 'previous candidate\n')
        self.assertFalse((self.pending / self.link).is_symlink())
        self.assertFalse((self.root / (self.configuration + '.caihong-new')).exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_install_and_invalid_rollback_clean_temporary_files(self):
        self.install()
        self.assertEqual(list(self.scratch.iterdir()), [])
        result = self.run_installer('--rollback', '../invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_legacy_candidates_are_not_silently_removed(self):
        legacy = self.root / (self.link + '.caihong-new')
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to('../caihong-test.service')
        self.install()
        self.assertEqual(str(legacy.readlink()), '../caihong-test.service')

    def test_checksum_failure_does_not_modify_existing_files(self):
        archive = self.package()
        self.write(self.payload, self.program, 'tampered program\n')
        subprocess.run(['bsdtar', '-cf', str(archive), '-C', str(self.payload),
                        'manifest', 'usr', 'etc'], check=True, capture_output=True)
        result = self.run_installer(archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch:', result.stderr)
        self.assertEqual((self.root / self.program).read_text(), 'original program\n')
        self.assertFalse(self.pending.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])


class RealtimeDependencyTests(unittest.TestCase):
    def test_rtkit_is_installed_and_verified(self):
        package_source = (PROJECT / 'scripts/package-archlinuxarm-rootfs.sh').read_text()
        verifier = (PROJECT / 'scripts/verify-archlinuxarm-rootfs.sh').read_text()
        packages = re.search(r'^packages=\((.*?)\)', package_source, re.MULTILINE | re.DOTALL)
        required = re.search(r"^required_packages='([^']*)'", verifier, re.MULTILINE)
        self.assertIsNotNone(packages)
        self.assertIsNotNone(required)
        self.assertIn('rtkit', shlex.split(packages.group(1)))
        self.assertIn('rtkit', shlex.split(required.group(1)))
        paths = re.search(r"^required_paths='([^']*)'", verifier, re.MULTILINE)
        self.assertIsNotNone(paths)
        self.assertIn('usr/lib/systemd/system/rtkit-daemon.service', shlex.split(paths.group(1)))
        self.assertIn('usr/share/dbus-1/system-services/org.freedesktop.RealtimeKit1.service',
                      shlex.split(paths.group(1)))


if __name__ == '__main__':
    unittest.main()
