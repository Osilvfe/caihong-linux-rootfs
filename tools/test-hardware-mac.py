import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / 'rootfs/archlinuxarm/usr/local/sbin/caihong-hardware-mac'


class HardwareMacTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-hardware-mac-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.configuration = self.root / 'configuration'
        self.state = self.root / 'state'
        self.nvram = self.root / 'nvram'
        self.nvram.mkdir()
        (self.nvram / 'nonmodemst1').write_bytes(b'first copy')
        (self.nvram / 'nonmodemst2').write_bytes(b'second copy')
        self.reader = self.root / 'reader'
        self.reader.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$READER_CALLS"\n'
                               'cat "$READER_OUTPUT"\nexit "$READER_STATUS"\n')
        self.reader.chmod(0o700)
        self.reader_output = self.root / 'reader-output'
        self.reader_output.write_text('WLAN_MAC=04:11:22:33:44:50\n'
                                      'BLUETOOTH_MAC=04:11:22:33:44:51\n')
        self.environment = dict(os.environ, READER_CALLS=str(self.root / 'reader-calls'),
                                READER_OUTPUT=str(self.reader_output), READER_STATUS='0')

    def command(self, after=''):
        return ['bash', '-c', 'source "$1"\nsleep() { :; }\n'
                'resolve_mac_values "$2" "$3" "$4" "$5"\n' + after +
                '\nprintf "WLAN_MAC=%s\\nBLUETOOTH_MAC=%s\\n" "$wlan_mac" "$bluetooth_mac"',
                'test-hardware-mac', str(SOURCE), str(self.configuration), str(self.state),
                str(self.reader), str(self.nvram)]

    def resolve(self, after=''):
        return subprocess.run(self.command(after), env=self.environment,
                              text=True, capture_output=True, timeout=10)

    def addresses(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split('=', 1) for line in result.stdout.splitlines()
                    if line.startswith(('WLAN_MAC=', 'BLUETOOTH_MAC=')))

    def fail_reader(self):
        self.environment['READER_STATUS'] = '1'

    def test_authenticated_factory_addresses_are_preferred(self):
        values = self.addresses(self.resolve())
        self.assertEqual(values['WLAN_MAC'], '04:11:22:33:44:50')
        self.assertEqual(values['BLUETOOTH_MAC'], '04:11:22:33:44:51')
        self.assertFalse(self.state.exists())

    def test_failed_reader_output_is_not_used(self):
        self.fail_reader()
        values = self.addresses(self.resolve())
        self.assertNotIn('04:11:22:33:44:50', values.values())
        self.assertNotIn('04:11:22:33:44:51', values.values())

    def test_fallback_is_distinct_local_unicast_and_persistent(self):
        self.fail_reader()
        values = self.addresses(self.resolve())
        self.assertEqual(len(set(values.values())), 2)
        for address in values.values():
            self.assertRegex(address, r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$')
            self.assertEqual(int(address[:2], 16) & 3, 2)
        saved = self.state / 'addresses'
        previous = saved.stat().st_mtime_ns
        self.assertEqual(self.addresses(self.resolve()), values)
        self.assertEqual(saved.stat().st_mtime_ns, previous)
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertFalse(list(self.state.glob('.addresses.*')))

    def test_concurrent_generation_uses_one_pair(self):
        self.fail_reader()
        processes = [subprocess.Popen(self.command(), env=self.environment, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for attempt in range(6)]
        results = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            results.append(stdout)
        self.assertEqual(len(set(results)), 1)
        self.assertFalse(list(self.state.glob('.addresses.*')))

    def test_missing_single_copy_still_calls_reader(self):
        (self.nvram / 'nonmodemst1').unlink()
        self.addresses(self.resolve())
        self.assertEqual((self.root / 'reader-calls').read_text().splitlines(),
                         [str(self.nvram / 'nonmodemst1'), str(self.nvram / 'nonmodemst2')])

    def test_missing_both_copies_uses_fallback(self):
        for partition in self.nvram.iterdir():
            partition.unlink()
        self.addresses(self.resolve())
        self.assertTrue((self.state / 'addresses').exists())
        self.assertFalse((self.root / 'reader-calls').exists())

    def test_manual_addresses_do_not_require_reader_or_state(self):
        self.configuration.write_text('# Manually verified addresses\n'
                                      'WLAN_MAC=02:AA:BB:CC:DD:10\n'
                                      'BLUETOOTH_MAC=02:AA:BB:CC:DD:11\n')
        values = self.addresses(self.resolve())
        self.assertEqual(values['WLAN_MAC'], '02:aa:bb:cc:dd:10')
        self.assertEqual(values['BLUETOOTH_MAC'], '02:aa:bb:cc:dd:11')
        self.assertFalse((self.root / 'reader-calls').exists())
        self.assertFalse(self.state.exists())

    def test_manual_bluetooth_preserves_factory_wifi(self):
        self.configuration.write_text('BLUETOOTH_MAC=02:aa:bb:cc:dd:11')
        values = self.addresses(self.resolve())
        self.assertEqual(values['BLUETOOTH_MAC'], '02:aa:bb:cc:dd:11')
        self.assertEqual(values['WLAN_MAC'], '04:11:22:33:44:50')
        self.assertFalse(self.state.exists())

    def test_manual_bluetooth_preserves_fallback_wifi(self):
        self.fail_reader()
        self.configuration.write_text('BLUETOOTH_MAC=02:aa:bb:cc:dd:11\n')
        values = self.addresses(self.resolve())
        self.assertEqual(values['BLUETOOTH_MAC'], '02:aa:bb:cc:dd:11')
        self.assertEqual(values['WLAN_MAC'], self.addresses(self.resolve())['WLAN_MAC'])

    def test_invalid_factory_output_uses_fallback(self):
        self.reader_output.write_text('WLAN_MAC=00:00:00:00:00:00\n'
                                      'BLUETOOTH_MAC=ff:ff:ff:ff:ff:ff\n')
        self.addresses(self.resolve())
        self.assertTrue((self.state / 'addresses').exists())

    def test_incomplete_factory_output_uses_fallback(self):
        self.reader_output.write_text('WLAN_MAC=04:11:22:33:44:50\n')
        values = self.addresses(self.resolve())
        self.assertNotEqual(values['WLAN_MAC'], '04:11:22:33:44:50')

    def test_invalid_manual_values_fail_without_fallback(self):
        for address in ('00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff',
                        '01:11:22:33:44:55', '55:44:33:22:11:00', 'invalid'):
            with self.subTest(address=address):
                self.configuration.write_text('BLUETOOTH_MAC=' + address + '\n')
                self.assertNotEqual(self.resolve().returncode, 0)
                self.assertFalse(self.state.exists())

    def test_configuration_is_not_executed(self):
        sentinel = self.root / 'executed'
        self.configuration.write_text('BLUETOOTH_MAC=$(touch ' + str(sentinel) + ')\n')
        self.assertNotEqual(self.resolve().returncode, 0)
        self.assertFalse(sentinel.exists())

    def test_duplicate_addresses_from_different_sources_fail(self):
        self.configuration.write_text('WLAN_MAC=04:11:22:33:44:51\n')
        self.assertNotEqual(self.resolve().returncode, 0)

    def test_invalid_saved_fallback_is_not_silently_replaced(self):
        self.fail_reader()
        self.state.mkdir()
        saved = self.state / 'addresses'
        saved.write_text('damaged state\n')
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not replacing them', result.stderr)
        self.assertEqual(saved.read_text(), 'damaged state\n')

    def test_unwritable_state_fails_without_ephemeral_address(self):
        self.fail_reader()
        self.state.write_text('not a directory\n')
        self.assertNotEqual(self.resolve().returncode, 0)

    def mock_bluetooth(self, address=None, powered=False):
        binary = self.root / 'bin'
        binary.mkdir()
        program = binary / 'btmgmt'
        program.write_text('''#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$BT_CALLS"
case "$*" in
config)
    printf 'hci0: Unconfigured controller\\n'
    ;;
'--index hci0 info')
    if [[ ! -f $BT_ADDRESS ]]; then
        printf '    addr 00:00:00:00:00:00\\n'
        exit 0
    fi
    printf '    addr %s\\n' "$(cat "$BT_ADDRESS")"
    printf '    current settings:'
    [[ ! -f $BT_POWER ]] || printf ' powered'
    printf '\\n'
    ;;
'--index hci0 public-addr '*)
    [[ ${BT_FAIL:-0} == 0 ]] || exit 1
    printf '%s\\n' "$4" > "$BT_ADDRESS"
    ;;
'--index hci0 power off') rm -f "$BT_POWER" ;;
'--index hci0 power on') touch "$BT_POWER" ;;
*) exit 1 ;;
esac
''')
        program.chmod(0o700)
        self.environment.update(PATH=str(binary) + os.pathsep + os.environ['PATH'],
                                BT_CALLS=str(self.root / 'bt-calls'),
                                BT_ADDRESS=str(self.root / 'bt-address'),
                                BT_POWER=str(self.root / 'bt-power'))
        if address:
            (self.root / 'bt-address').write_text(address + '\n')
        if powered:
            (self.root / 'bt-power').touch()

    def test_fallback_configures_unconfigured_controller(self):
        self.fail_reader()
        self.mock_bluetooth()
        values = self.addresses(self.resolve('apply_bluetooth_address "$bluetooth_mac"'))
        self.assertEqual((self.root / 'bt-address').read_text().strip(), values['BLUETOOTH_MAC'])
        self.assertNotIn('power off', (self.root / 'bt-calls').read_text())

    def test_configured_controller_preserves_power_state(self):
        self.mock_bluetooth('02:11:22:33:44:55', powered=True)
        values = self.addresses(self.resolve('apply_bluetooth_address "$bluetooth_mac"'))
        calls = (self.root / 'bt-calls').read_text().splitlines()
        self.assertLess(calls.index('--index hci0 power off'),
                        calls.index('--index hci0 public-addr ' + values['BLUETOOTH_MAC']))
        self.assertEqual(calls[-1], '--index hci0 power on')
        self.assertTrue((self.root / 'bt-power').exists())

    def test_powered_off_controller_is_not_powered_on(self):
        self.mock_bluetooth('02:11:22:33:44:55')
        self.addresses(self.resolve('apply_bluetooth_address "$bluetooth_mac"'))
        self.assertFalse((self.root / 'bt-power').exists())
        self.assertNotIn('power on', (self.root / 'bt-calls').read_text())

    def test_programming_failure_is_not_reported_as_success(self):
        self.mock_bluetooth()
        self.environment['BT_FAIL'] = '1'
        result = self.resolve('apply_bluetooth_address "$bluetooth_mac"')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Bluetooth hci0:', result.stdout)


if __name__ == '__main__':
    unittest.main()
