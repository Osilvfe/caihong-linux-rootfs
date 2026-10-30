import importlib.machinery
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from xml.etree import ElementTree


PROJECT = Path(__file__).resolve().parents[1]
WORKSPACE = PROJECT.parent
SOURCE = PROJECT / 'rootfs/archlinuxarm/usr/local/sbin/caihong-keyboard'
loader = importlib.machinery.SourceFileLoader('default_keyboard', str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
keyboard_module = importlib.util.module_from_spec(spec)
loader.exec_module(keyboard_module)


class DefaultKeyboardTests(unittest.TestCase):
    def setUp(self):
        output = WORKSPACE / 'build/caihong-keyboard-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.paths = keyboard_module.Paths(self.root)
        controls = self.root / 'oneplus'
        controls.mkdir()
        (controls / 'f4_compensation').write_text('0\n')
        (controls / 'media_keys').write_text('1\n')
        event = self.root / 'event10'
        event.write_bytes(b'')
        self.node = {'controls': controls, 'event': event, 'address': 'AA:BB:CC:DD:EE:FF'}
        self.bluez = Mock()
        self.bluez.keyboard_characteristic.return_value = '/keyboard/command'
        nodes = patch.object(keyboard_module, 'keyboard_nodes', return_value=[self.node])
        pogo = patch.object(keyboard_module, 'pogo_node', return_value=None)
        self.nodes = nodes.start()
        self.pogo = pogo.start()
        self.addCleanup(nodes.stop)
        self.addCleanup(pogo.stop)

    def service(self):
        service = keyboard_module.Service(self.paths, self.bluez)
        service.companion = Mock()
        service.companion.running.return_value = False
        return service

    def test_default_has_no_compensation_preference(self):
        service = self.service()
        self.assertFalse(service.media_keys)
        self.assertTrue(service.status()['automatic'])
        self.assertNotIn('SetCompensation', keyboard_module.INTERFACE_XML)

    def test_connected_keyboard_starts_automatically(self):
        service = self.service()
        service.monitor()
        service.companion.start.assert_called_once_with()
        self.assertEqual((self.node['controls'] / 'media_keys').read_text().strip(), '0')
        self.bluez.connect.assert_not_called()

    def test_existing_worker_not_started_twice(self):
        service = self.service()
        service.companion.running.return_value = True
        service.monitor()
        service.companion.start.assert_not_called()

    def test_pogo_keeps_native_path(self):
        pogo = self.root / 'pogo'
        pogo.mkdir()
        (pogo / 'attached').write_text('1\n')
        self.pogo.return_value = pogo
        service = self.service()
        service.monitor()
        service.companion.stop.assert_called_once_with()
        service.companion.start.assert_not_called()
        self.bluez.write.assert_not_called()

    def test_disconnected_keyboard_is_not_reconnected(self):
        self.nodes.return_value = []
        service = self.service()
        service.monitor()
        service.companion.start.assert_not_called()
        self.bluez.connect.assert_not_called()

    def test_failed_start_has_bounded_retry(self):
        service = self.service()
        service.companion.start.side_effect = keyboard_module.Unavailable('waiting')
        with patch.object(keyboard_module.time, 'monotonic', return_value=100):
            service.monitor()
            service.monitor()
        self.assertEqual(service.companion.start.call_count, 1)
        self.assertEqual(service.retry_after, 105)

    def test_sleep_stops_and_resume_rearms_automatic_monitor(self):
        service = self.service()
        service.sleep_changed(None, None, None, None, None, SimpleNamespace(unpack=lambda: (True,)), None)
        service.monitor()
        service.companion.start.assert_not_called()
        service.sleep_changed(None, None, None, None, None, SimpleNamespace(unpack=lambda: (False,)), None)
        service.monitor()
        service.companion.start.assert_called_once_with()

    def test_media_preference_survives_new_service(self):
        service = self.service()
        service.set_media_keys(True)
        self.assertEqual(json.loads(service.preferences.read_text()), {'media_keys': True})
        self.assertEqual(service.preferences.stat().st_mode & 0o777, 0o600)
        self.assertTrue(keyboard_module.Service(self.paths, self.bluez).media_keys)
        service.set_media_keys(False)
        self.assertFalse(keyboard_module.Service(self.paths, self.bluez).media_keys)

    def test_invalid_preferences_are_not_applied(self):
        preferences = self.paths.path('/var/lib/caihong-keyboard/preferences.json')
        preferences.parent.mkdir(parents=True)
        preferences.write_text('{"compensation": false, "media_keys": true}')
        with self.assertRaises(ValueError):
            keyboard_module.Service(self.paths, self.bluez)

    def test_preferences_can_be_saved_without_keyboard(self):
        self.nodes.return_value = []
        service = self.service()
        service.set_media_keys(True)
        self.assertTrue(service.media_keys)
        self.bluez.write.assert_not_called()

    def test_only_booleans_are_accepted(self):
        service = self.service()
        for value in (0, 1, None, 'true'):
            with self.assertRaises(ValueError):
                service.set_media_keys(value)
            with self.assertRaises(ValueError):
                service.set_touchpad(value)

    def test_touchpad_request_uses_current_companion(self):
        service = self.service()
        service.set_touchpad(False)
        service.companion.set_target.assert_called_once_with(False)

    def test_touchpad_request_prefers_pogo_when_attached(self):
        pogo = self.root / 'pogo'
        pogo.mkdir()
        (pogo / 'attached').write_text('1\n')
        (pogo / 'touchpad_enabled').write_text('1\n')
        self.pogo.return_value = pogo
        service = self.service()
        service.set_touchpad(False)
        self.assertEqual((pogo / 'touchpad_enabled').read_text().strip(), '0')
        service.companion.set_target.assert_not_called()

    def companion(self):
        return keyboard_module.KeyboardCompanion(self.paths, self.bluez)

    def finish(self, companion):
        companion.thread.join(timeout=2)
        self.assertFalse(companion.running())

    def test_foreign_gate_is_never_stolen(self):
        (self.node['controls'] / 'f4_compensation').write_text('1\n')
        with self.assertRaises(keyboard_module.Unavailable):
            self.companion().start()
        self.bluez.write.assert_not_called()

    def test_initial_write_failure_does_not_enable_mapping(self):
        self.bluez.write.side_effect = keyboard_module.Unavailable('failed')
        with self.assertRaises(keyboard_module.Unavailable):
            self.companion().start()
        self.assertEqual((self.node['controls'] / 'f4_compensation').read_text().strip(), '0')

    def test_real_input_semantics_and_cleanup(self):
        packet = struct.Struct('llHHi')
        payload = []
        for code, value in ((62, 1), (62, 0), (530, 1), (530, 0),
                            (62, 1), (62, 2), (62, 0), (530, 1), (530, 0)):
            payload.extend(packet.pack(0, 0, kind, event_code, event_value)
                           for kind, event_code, event_value in ((4, 4, 0x7006b), (1, code, value), (0, 0, 0)))
        self.node['event'].write_bytes(b''.join(payload))
        companion = self.companion()
        companion.start()
        self.finish(companion)
        self.assertEqual([call.args[1].hex() for call in self.bluez.write.call_args_list],
                         ['1301010015', '1301010015', '1301010116', '1301010116', '1301010015', '1301010015'])
        self.assertEqual((self.node['controls'] / 'f4_compensation').read_text().strip(), '0')

    def test_dropped_events_disarm_worker(self):
        self.node['event'].write_bytes(struct.pack('llHHi', 0, 0, 0, 3, 0))
        companion = self.companion()
        companion.start()
        self.finish(companion)
        self.assertIn('events lost', companion.error)
        self.assertEqual((self.node['controls'] / 'f4_compensation').read_text().strip(), '0')

    def test_truncated_input_disarms_worker(self):
        self.node['event'].write_bytes(b'incomplete')
        companion = self.companion()
        companion.start()
        self.finish(companion)
        self.assertIn('truncated', companion.error)

    def test_input_write_failure_is_visible_and_disarms(self):
        packet = struct.Struct('llHHi')
        self.node['event'].write_bytes(packet.pack(0, 0, 4, 4, 0x7006b) + packet.pack(0, 0, 1, 62, 1))
        self.bluez.write.side_effect = [None, keyboard_module.Unavailable('write failed'), None]
        companion = self.companion()
        companion.start()
        self.finish(companion)
        self.assertIn('write failed', companion.error)
        self.assertEqual((self.node['controls'] / 'f4_compensation').read_text().strip(), '0')

    def test_users_cannot_mutate_default_daemon(self):
        policy = SOURCE.parents[3] / 'etc/dbus-1/system.d/org.caihong.Keyboard1.conf'
        root = ElementTree.parse(policy).getroot()
        defaults = root.find("policy[@context='default']")
        self.assertEqual({node.attrib['send_member'] for node in defaults.findall('deny')},
                         {'SetTouchpad', 'SetMediaKeys'})
        self.assertIsNotNone(root.find("policy[@user='root']/allow[@own='org.caihong.Keyboard1']"))


if __name__ == '__main__':
    unittest.main(verbosity=2)
