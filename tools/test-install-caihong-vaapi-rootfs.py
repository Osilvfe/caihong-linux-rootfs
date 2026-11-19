#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class VaapiRootfsInstallerTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-vaapi-rootfs-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.project = self.work / 'project'
        self.rootfs = self.work / 'rootfs'
        self.bin = self.work / 'bin'
        self.installer = self.project / 'scripts/install-caihong-vaapi-rootfs.sh'
        self.source = self.project / 'external/qcom-va-driver'

        self.installer.parent.mkdir(parents=True)
        shutil.copy2(PROJECT / 'scripts/install-caihong-vaapi-rootfs.sh', self.installer)
        for relative in ('meson.build', 'meson_options.txt', 'src/backend.cpp', 'src/av1.cpp'):
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('test fixture\n')
        (self.rootfs / 'tmp').mkdir(parents=True)
        self.bin.mkdir()

        self.write_executable('fake-chroot', textwrap.dedent('''\
            #!/bin/sh
            rootfs=$1
            shift
            while [ "$#" -gt 0 ] && [ "$1" != meson ]; do
                shift
            done
            [ "$#" -gt 0 ] || { echo "fake-chroot: meson command missing" >&2; exit 1; }
            shift
            export FAKE_CHROOT_ROOT=$rootfs
            export PATH=$FAKE_BIN:$PATH
            exec meson "$@"
        '''))
        self.write_executable('meson', textwrap.dedent('''\
            #!/usr/bin/env python3
            import os
            from pathlib import Path
            import sys

            root = Path(os.environ['FAKE_CHROOT_ROOT'])
            args = sys.argv[1:]

            def inside(path):
                return root / path.lstrip('/')

            if args and args[0] == 'setup':
                build = inside(args[1])
                source = inside(args[2])
                if not source.is_dir():
                    print(
                        f"ERROR: Neither directory '{build}' nor directory "
                        f"'{source}' exist.",
                        file=sys.stderr,
                    )
                    raise SystemExit(1)
                build.mkdir(parents=True, exist_ok=True)
                (build / 'args.txt').write_text(' '.join(args[3:]) + '\\n')
                raise SystemExit(0)
            if args and args[0] == 'compile':
                raise SystemExit(0)
            if args and args[0] == 'install':
                dri = root / 'usr/lib/dri'
                dri.mkdir(parents=True, exist_ok=True)
                (dri / 'qcom_drv_video.so').write_bytes(b'driver')
                (dri / 'msm_drv_video.so').symlink_to('qcom_drv_video.so')
                raise SystemExit(0)
            print(f'fake-meson: unsupported arguments: {args}', file=sys.stderr)
            raise SystemExit(1)
        '''))

        self.environment = dict(
            os.environ,
            PATH=f'{self.bin}:{os.environ["PATH"]}',
            CHROOT_TOOL='fake-chroot',
            FAKE_BIN=str(self.bin),
        )

    def write_executable(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def test_meson_runs_with_paths_visible_inside_the_chroot(self):
        result = subprocess.run(
            ['bash', str(self.installer), str(self.rootfs)],
            env=self.environment,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Qualcomm Iris VA-API installed', result.stdout)
        self.assertTrue((self.rootfs / 'usr/lib/dri/qcom_drv_video.so').is_file())
        self.assertTrue((self.rootfs / 'usr/share/caihong/vaapi-build-info').is_file())


if __name__ == '__main__':
    unittest.main()
