#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / 'scripts/install-caihong-modules.sh'
RELEASE = '7.3.0-caihong-test'


class ModuleInstallerTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-module-install-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.source = self.work / 'modules-installed'
        self.target = self.work / 'rootfs'
        self.source_release = self.source / 'lib/modules' / RELEASE
        self.target_modules = self.target / 'lib/modules'
        self.target_release = self.target_modules / RELEASE
        self.log = self.work / 'depmod.log'

        self.write('kernel/sound/usb/snd-usb-audio.ko', 'usb audio module\n')
        self.write('kernel/drivers/media/i2c/caihong-sensor.ko', 'camera module\n')
        self.write('modules.builtin', 'kernel/sound/core/snd-pcm.ko\n')
        self.write('modules.order', 'kernel/sound/usb/snd-usb-audio.ko\n')
        (self.source_release / 'build').symlink_to('/host/kernel/build')
        (self.source_release / 'source').symlink_to('/host/kernel/source')

        stale = self.target_modules / '7.2.0-old/kernel/stale.ko'
        stale.parent.mkdir(parents=True)
        stale.write_text('stale release\n')
        self.write_target('kernel/stale-in-current-release.ko', 'stale module\n')

        binary = self.work / 'bin'
        binary.mkdir()
        depmod = binary / 'depmod'
        depmod.write_text(
            '#!/bin/sh\n'
            'printf "%s\\n" "$*" > "$DEPMOD_LOG"\n'
        )
        depmod.chmod(0o755)
        self.environment = dict(
            os.environ,
            PATH=f'{binary}:{os.environ["PATH"]}',
            DEPMOD_LOG=str(self.log),
        )

    def write(self, relative, contents):
        path = self.source_release / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def write_target(self, relative, contents):
        path = self.target_release / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def test_complete_module_tree_is_installed_without_an_allowlist(self):
        result = subprocess.run(
            ['sh', str(INSTALLER), str(self.source), str(self.target)],
            env=self.environment,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'installed 2 modules for {RELEASE}', result.stdout)

        for relative in (
            'kernel/sound/usb/snd-usb-audio.ko',
            'kernel/drivers/media/i2c/caihong-sensor.ko',
            'modules.builtin',
            'modules.order',
        ):
            self.assertTrue((self.target_release / relative).is_file(), relative)
        self.assertFalse((self.target_release / 'kernel/stale-in-current-release.ko').exists())
        self.assertFalse((self.target_modules / '7.2.0-old').exists())
        self.assertFalse((self.target_release / 'build').exists())
        self.assertFalse((self.target_release / 'source').exists())
        self.assertEqual(
            self.log.read_text().strip(),
            f'-b {self.target} {RELEASE}',
        )


if __name__ == '__main__':
    unittest.main()
