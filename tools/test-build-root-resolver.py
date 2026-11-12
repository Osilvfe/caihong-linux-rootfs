from pathlib import Path
import os
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / 'scripts/caihong-build-root.sh'


class BuildRootResolverTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-build-root-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.root = self.work / 'root'
        self.bin = self.work / 'bin'
        (self.root / 'etc').mkdir(parents=True)
        self.bin.mkdir()
        for name in ('bsdtar', 'mount', 'rsync', 'umount', 'mountpoint'):
            command = self.bin / name
            command.write_text('#!/bin/sh\nexit ' +
                               ('1' if name == 'mountpoint' else '0') + '\n')
            command.chmod(0o755)
        self.environment = dict(
            os.environ,
            PATH=f'{self.bin}:{os.environ["PATH"]}',
        )

    def prepare_cached_root(self, distribution):
        (self.root / '.caihong-build-root-ready').write_text(distribution + '\n')
        result = subprocess.run(
            ['bash', str(SCRIPT), 'prepare', str(self.root), distribution],
            env=self.environment,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_resolver_symlink_works_after_private_run_is_mounted(self):
        resolver = self.root / 'etc/resolv.conf'
        resolver.symlink_to('/run/caihong-missing-resolver/stub-resolv.conf')
        self.prepare_cached_root('archlinuxarm')
        self.assertFalse(resolver.is_symlink())
        self.assertEqual(resolver.read_bytes(), Path('/etc/resolv.conf').read_bytes())

    def test_armada_without_resolver_uses_host_dns(self):
        self.prepare_cached_root('armada')
        resolver = self.root / 'etc/resolv.conf'
        self.assertTrue(resolver.is_file())
        self.assertEqual(resolver.read_bytes(), Path('/etc/resolv.conf').read_bytes())


if __name__ == '__main__':
    unittest.main()
