import importlib.util
from pathlib import Path
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release_assets', PROJECT / 'scripts/prepare-release-assets.py')
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleasePackageTests(unittest.TestCase):
    def test_notes_install_native_platform_and_kernel_without_npu_archives(self):
        output = PROJECT.parent / 'build/caihong-release-package-tests'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output) as temporary:
            root = Path(temporary)
            for distribution, suffix, manager in (
                ('archlinuxarm', '-aarch64.pkg.tar.zst', 'pacman'),
                ('armada', '-1.aarch64.rpm', 'dnf'),
            ):
                with self.subTest(distribution=distribution):
                    assets = [root / f'caihong-platform-test-1{suffix}',
                              root / f'linux-caihong-test-1{suffix}']
                    image = root / 'rootfs.img'
                    compressed = root / 'rootfs.img.zst'
                    for path in (*assets, image, compressed):
                        path.write_bytes(b'test')
                    notes = root / f'{distribution}.md'
                    RELEASE.write_release_notes(
                        notes, distribution, 'test', assets,
                        {path.name: '0' * 64 for path in assets}, image, '0' * 64,
                        compressed, '0' * 64, [compressed], {},
                        {'format': 'android-sparse-ext4', 'logical_bytes': 4096,
                         'filesystem_label': 'linux'})
                    contents = notes.read_text()
                    self.assertIn('sudo ' + manager, contents)
                    self.assertIn('./' + assets[0].name, contents)
                    self.assertIn('./' + assets[1].name, contents)
                    self.assertNotIn('install-caihong-platform', contents)
                    self.assertNotIn('caihong-npu-', contents)
                    self.assertIn('fully upgrade', contents)


if __name__ == '__main__':
    unittest.main()
