#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>

from pathlib import Path
import os
import subprocess
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / 'packaging/caihong-platform/switch-display-manager.sh'

PACMAN = '''\
#!/bin/sh
set -eu
printf 'pacman %s\n' "$*" >> "$COMMAND_LOG"
case $1 in
	-Qq)
		case $2 in
			plasma-login-manager) [ -e "$FAKE_PLM_INSTALLED" ] ;;
			sddm|sddm-kcm) [ -e "$FAKE_SDDM_INSTALLED" ] ;;
			*) exit 1 ;;
		esac
		;;
	-S)
		: > "$FAKE_PLM_INSTALLED"
		mkdir -p "$FAKE_ROOT/usr/lib/systemd/system"
		printf '[Unit]\n[Install]\nAlias=display-manager.service\n' \
			> "$FAKE_ROOT/usr/lib/systemd/system/plasmalogin.service"
		;;
	-R)
		rm -f "$FAKE_SDDM_INSTALLED"
		;;
	*)
		exit 2
		;;
esac
'''

CHROOT = '''\
#!/bin/sh
set -eu
printf 'chroot %s\n' "$*" >> "$COMMAND_LOG"
export FAKE_ROOT=$1
shift
[ "$1" = /usr/bin/env ] && shift
while [ "$#" -gt 0 ]; do
	case $1 in
		*=*) shift ;;
		*) break ;;
	esac
done
[ "$1" = pacman ] || exit 2
shift
exec fake-pacman "$@"
'''

SYSTEMCTL = '''\
#!/bin/sh
set -eu
root=
action=
unit=
for argument in "$@"; do
	case $argument in
		--root=*) root=${argument#--root=} ;;
		enable|disable|is-enabled) action=$argument ;;
		*) unit=$argument ;;
	esac
done
[ -n "$root" ] || exit 2
	case $action in
	is-enabled)
		[ -L "$root/etc/systemd/system/graphical.target.wants/$unit" ] ||
			[ -e "$root/etc/systemd/system/graphical.target.wants/$unit" ] ||
			[ -L "$root/etc/systemd/system/multi-user.target.wants/$unit" ] ||
			[ -e "$root/etc/systemd/system/multi-user.target.wants/$unit" ]
		;;
	enable)
		[ "$unit" = plasmalogin.service ] || exit 2
		mkdir -p "$root/etc/systemd/system"
		ln -sfn /usr/lib/systemd/system/plasmalogin.service \
			"$root/etc/systemd/system/display-manager.service"
		printf 'systemctl --root=%s enable %s\n' "$root" "$unit" >> "$COMMAND_LOG"
		;;
	*) exit 2 ;;
esac
'''


class DisplayManagerMigrationTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-display-manager-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.root = self.work / 'root'
        self.bin = self.work / 'bin'
        self.log = self.work / 'commands.log'
        self.root.mkdir()
        self.bin.mkdir()

        for name, contents in (
                ('fake-pacman', PACMAN),
                ('fake-chroot', CHROOT),
                ('fake-systemctl', SYSTEMCTL)):
            path = self.bin / name
            path.write_text(contents)
            path.chmod(0o755)

        self.environment = dict(
            os.environ,
            PATH=f'{self.bin}:{os.environ["PATH"]}',
            CAIHONG_PLATFORM_ROOT=str(self.root),
            CAIHONG_CHROOT_TOOL='fake-chroot',
            CAIHONG_SYSTEMCTL='fake-systemctl',
            COMMAND_LOG=str(self.log),
            FAKE_ROOT=str(self.root),
            FAKE_PLM_INSTALLED=str(self.work / 'plm-installed'),
            FAKE_SDDM_INSTALLED=str(self.work / 'sddm-installed'),
            CAIHONG_PLATFORM_UPDATE_INSTALL='1',
        )

    def run_script(self):
        return subprocess.run(
            ['sh', str(SCRIPT)],
            env=self.environment,
            text=True,
            capture_output=True,
        )

    def test_existing_sddm_installation_is_migrated_to_plm(self):
        pacman = self.root / 'usr/bin/pacman'
        pacman.parent.mkdir(parents=True)
        pacman.write_text('#!/bin/sh\nexec fake-pacman "$@"\n')
        pacman.chmod(0o755)
        (self.work / 'sddm-installed').touch()
        alias = self.root / 'etc/systemd/system/display-manager.service'
        alias.parent.mkdir(parents=True)
        alias.symlink_to('/usr/lib/systemd/system/sddm.service')

        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            alias.readlink(), Path('/usr/lib/systemd/system/plasmalogin.service')
        )
        self.assertFalse((self.work / 'sddm-installed').exists())
        log = self.log.read_text()
        self.assertIn(
            'pacman -S --needed --noconfirm --disable-sandbox plasma-login-manager', log
        )
        self.assertIn('pacman -R --noconfirm sddm-kcm', log)
        self.assertIn('pacman -R --noconfirm sddm', log)
        self.assertIn('systemctl --root=', log)

    def test_non_arch_target_is_left_alone(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.log.exists())

    def test_administrator_selected_display_manager_is_preserved(self):
        pacman = self.root / 'usr/bin/pacman'
        pacman.parent.mkdir(parents=True)
        pacman.write_text('#!/bin/sh\nexec fake-pacman "$@"\n')
        pacman.chmod(0o755)
        (self.work / 'sddm-installed').touch()
        alias = self.root / 'etc/systemd/system/display-manager.service'
        alias.parent.mkdir(parents=True)
        alias.symlink_to('/usr/lib/systemd/system/ly.service')

        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(alias.readlink(), Path('/usr/lib/systemd/system/ly.service'))
        self.assertTrue((self.work / 'sddm-installed').exists())
        self.assertFalse(self.log.exists())

    def test_directly_enabled_non_sddm_manager_is_preserved(self):
        pacman = self.root / 'usr/bin/pacman'
        pacman.parent.mkdir(parents=True)
        pacman.write_text('#!/bin/sh\nexec fake-pacman "$@"\n')
        pacman.chmod(0o755)
        (self.work / 'sddm-installed').touch()
        alias = self.root / 'etc/systemd/system/display-manager.service'
        alias.parent.mkdir(parents=True)
        alias.symlink_to('/usr/lib/systemd/system/sddm.service')
        wants = self.root / 'etc/systemd/system/graphical.target.wants'
        wants.mkdir(parents=True)
        (wants / 'ly.service').symlink_to('/usr/lib/systemd/system/ly.service')

        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(alias.readlink(), Path('/usr/lib/systemd/system/sddm.service'))
        self.assertTrue((self.work / 'sddm-installed').exists())
        self.assertFalse(self.log.exists())

    def test_migration_is_skipped_outside_update_package_installation(self):
        pacman = self.root / 'usr/bin/pacman'
        pacman.parent.mkdir(parents=True)
        pacman.write_text('#!/bin/sh\nexec fake-pacman "$@"\n')
        pacman.chmod(0o755)
        (self.work / 'sddm-installed').touch()
        self.environment['CAIHONG_PLATFORM_UPDATE_INSTALL'] = '0'

        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.work / 'sddm-installed').exists())
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
