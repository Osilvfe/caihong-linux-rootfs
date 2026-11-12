from pathlib import Path
import os
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SERIAL = PROJECT / 'rootfs/archlinuxarm/usr/local/libexec/caihong-adbd-serial'
GADGET = PROJECT / 'rootfs/archlinuxarm/usr/local/sbin/caihong-adbd-gadget'


class AdbdSerialTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-adbd-serial-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.cmdline = self.work / 'cmdline'
        self.environment = dict(
            os.environ,
            CAIHONG_ADBD_SERIAL_FILE=str(self.work / 'serial'),
            CAIHONG_ADBD_CMDLINE_FILE=str(self.cmdline),
            CAIHONG_ADBD_MACHINE_ID_FILE=str(self.work / 'machine-id'),
        )

    def run_helper(self, cmdline=None):
        if cmdline is not None:
            self.cmdline.write_text(cmdline)
        return subprocess.run(
            ['sh', str(SERIAL)], env=self.environment,
            text=True, capture_output=True,
        )

    def test_bootloader_serial_is_used(self):
        result = self.run_helper(
            'console=tty0 oplusboot.serialno=95ced872 root=PARTLABEL=linux\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '95ced872\n')

    def test_android_serial_is_used_when_oplus_serial_is_absent(self):
        result = self.run_helper('androidboot.serialno=ABC123 root=PARTLABEL=linux\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'ABC123\n')

    def test_oplus_serial_wins_over_android_serial(self):
        result = self.run_helper(
            'androidboot.serialno=ABC123 oplusboot.serialno=95ced872\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '95ced872\n')

    def test_explicit_override_wins(self):
        (self.work / 'serial').write_text('MYDEVICE\r\n')
        result = self.run_helper('oplusboot.serialno=95ced872\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'MYDEVICE\n')

    def test_invalid_override_falls_through_to_cmdline(self):
        (self.work / 'serial').write_text('bad value\n')
        result = self.run_helper('oplusboot.serialno=95ced872\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '95ced872\n')

    def test_fallback_is_used_without_any_serial(self):
        result = self.run_helper('console=tty0 root=PARTLABEL=linux\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'caihong-adb\n')

    def test_machine_id_provides_a_stable_fallback(self):
        (self.work / 'machine-id').write_text(
            '0123456789abcdef0123456789abcdef\n')
        result = self.run_helper('console=tty0 root=PARTLABEL=linux\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'caihong-0123456789abcdef\n')

    def test_invalid_machine_id_uses_the_last_fallback(self):
        (self.work / 'machine-id').write_text('not-a-machine-id\n')
        result = self.run_helper('console=tty0 root=PARTLABEL=linux\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'caihong-adb\n')

    def test_gadget_uses_the_helper(self):
        source = GADGET.read_text()
        self.assertIn('/usr/local/libexec/caihong-adbd-serial', source)
        self.assertNotIn("printf 'caihong-adb\\n' > \"$gadget_dir/strings/0x409/serialnumber\"",
                         source)


if __name__ == '__main__':
    unittest.main()
