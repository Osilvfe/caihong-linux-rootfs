import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True

PROJECT = Path(__file__).resolve().parents[1]
WORKSPACE = PROJECT.parent
SOURCE = PROJECT / 'rootfs/archlinuxarm/usr/local/sbin/caihong-flashlight-panel'

loader = importlib.machinery.SourceFileLoader('caihong_flashlight_panel', str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
panel = importlib.util.module_from_spec(spec)
loader.exec_module(panel)


class FlashlightPanelTests(unittest.TestCase):
    def setUp(self):
        output = WORKSPACE / 'build/caihong-flashlight-panel-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / 'config/plasma-org.kde.plasma.desktop-appletsrc'
        self.marker = self.root / 'config/caihong-flashlight-panel'
        self.config.parent.mkdir(parents=True)

        for name, value in (
            ('CONFIG', self.config),
            ('MARKER', self.marker),
            ('ATTEMPTS', 1),
            ('INTERVAL', 0),
        ):
            patcher = patch.object(panel, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

        self.log = self.root / 'gdbus.log'
        self.fake = self.root / 'bin/gdbus'
        self.fake.parent.mkdir()
        self.fake.write_text(
            '#!/bin/sh\n'
            'printf "%s\\n" "$*" >> "$FAKE_LOG"\n'
            'printf "%s\\n" "${FAKE_REPLY:-added}"\n'
        )
        self.fake.chmod(0o755)
        environment = {
            'FAKE_LOG': str(self.log),
            'FAKE_REPLY': 'added',
        }
        patcher = patch.dict(os.environ, environment)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_config(self, *plugins):
        body = ''.join(
            f'\n[Containments][2][Applets][{index}]\n'
            f'immutability=1\nplugin={plugin}\n'
            for index, plugin in enumerate(plugins, start=1)
        )
        self.config.write_text('[Containments][2]\nplugin=org.kde.panel\n' + body)

    def runner(self):
        return patch.object(panel, 'find_runner', return_value=str(self.fake))

    def test_existing_applet_is_not_added_again(self):
        self.write_config('org.kde.plasma.digitalclock', panel.APPLET_ID)
        finder = Mock()
        with patch.object(panel, 'find_runner', finder):
            self.assertEqual(panel.main([]), 0)
        finder.assert_not_called()
        self.assertTrue(self.marker.exists())

    def test_marker_keeps_a_removed_applet_removed(self):
        self.write_config('org.kde.plasma.digitalclock')
        self.marker.touch()
        finder = Mock()
        with patch.object(panel, 'find_runner', finder):
            self.assertEqual(panel.main([]), 0)
        finder.assert_not_called()

    def test_force_adds_after_a_previous_removal(self):
        self.write_config('org.kde.plasma.digitalclock')
        self.marker.touch()
        with self.runner():
            self.assertEqual(panel.main(['--force']), 0)
        self.assertTrue(self.marker.exists())
        self.assertIn(panel.APPLET_ID, self.log.read_text())

    def test_missing_applet_is_added_and_marked(self):
        self.write_config('org.kde.plasma.digitalclock')
        with self.runner():
            self.assertEqual(panel.main([]), 0)
        self.assertTrue(self.marker.exists())
        self.assertIn(panel.DBUS_METHOD, self.log.read_text())
        self.assertIn(panel.APPLET_ID, self.log.read_text())

    def test_no_panel_is_retried_then_reported(self):
        self.write_config('org.kde.plasma.digitalclock')
        os.environ['FAKE_REPLY'] = 'no-panel'
        with self.runner():
            self.assertEqual(panel.main([]), 1)
        self.assertFalse(self.marker.exists())

    def test_dry_run_does_not_call_plasmashell(self):
        self.write_config('org.kde.plasma.digitalclock')
        finder = Mock()
        with patch.object(panel, 'find_runner', finder):
            self.assertEqual(panel.main(['--dry-run']), 0)
        finder.assert_not_called()
        self.assertFalse(self.marker.exists())

    def test_status_reports_presence(self):
        self.write_config('org.kde.plasma.digitalclock', panel.APPLET_ID)
        self.assertEqual(panel.main(['--status']), 0)
        self.write_config('org.kde.plasma.digitalclock')
        self.assertEqual(panel.main(['--status']), 1)

    def test_missing_runner_fails_cleanly(self):
        self.write_config('org.kde.plasma.digitalclock')
        with patch.object(panel, 'find_runner', return_value=None):
            self.assertEqual(panel.main([]), 1)
        self.assertFalse(self.marker.exists())

    def test_applet_matching_is_exact(self):
        self.config.write_text('plugin=org.ahaan.flashlight-extra\n')
        self.assertFalse(panel.applet_present())

    def test_add_script_targets_the_bottom_panel(self):
        self.assertIn('panels()', panel.ADD_SCRIPT)
        self.assertIn('"bottom"', panel.ADD_SCRIPT)
        self.assertIn('addWidget', panel.ADD_SCRIPT)
        self.assertIn(panel.APPLET_ID, panel.ADD_SCRIPT)

    def test_gdbus_command_uses_call_syntax(self):
        command = panel.runner_command('/usr/bin/gdbus', 'print(1);')
        self.assertEqual(command[:2], ['/usr/bin/gdbus', 'call'])
        self.assertIn('--session', command)
        self.assertEqual(command[-1], 'print(1);')

    def test_qdbus_command_uses_positional_syntax(self):
        command = panel.runner_command('/usr/bin/qdbus6', 'print(1);')
        self.assertEqual(
            command,
            ['/usr/bin/qdbus6', panel.DBUS_DEST, panel.DBUS_PATH,
             panel.DBUS_METHOD, 'print(1);'],
        )

    def test_system_plasmoid_matches_the_helper(self):
        root = (PROJECT / 'rootfs/archlinuxarm/usr/share/plasma/plasmoids'
                / panel.APPLET_ID)
        metadata = json.loads((root / 'metadata.json').read_text())
        self.assertEqual(metadata['KPlugin']['Id'], panel.APPLET_ID)
        self.assertEqual(metadata['KPackageStructure'], 'Plasma/Applet')
        qml = (root / 'contents/ui/main.qml').read_text()
        self.assertIn('org.kde.plasma.plasma5support', qml)
        self.assertIn('/usr/local/sbin/caihong-flashlight', qml)

    def test_autostart_desktop_starts_the_helper(self):
        desktop = (PROJECT / 'rootfs/archlinuxarm/etc/xdg/autostart'
                   / 'caihong-flashlight-panel.desktop').read_text()
        self.assertIn('/usr/local/sbin/caihong-flashlight-panel', desktop)
        self.assertIn('OnlyShowIn=KDE;', desktop)
        self.assertIn('X-KDE-autostart-after=panel', desktop)


if __name__ == '__main__':
    unittest.main()
