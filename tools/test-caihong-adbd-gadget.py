#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
GADGET = PROJECT / 'rootfs/archlinuxarm/usr/local/sbin/caihong-adbd-gadget'


class AdbGadgetIdTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-adbd-gadget-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.compatible = self.work / 'compatible'
        self.ids = self.work / 'ids'
        self.cmdline = self.work / 'cmdline'
        self.serial_file = self.work / 'serial'
        self.hostname = self.work / 'hostname'
        self.compatible.write_bytes(b'oneplus,caihong\0qcom,sm8650\0')
        self.ids.write_text('oneplus,caihong 0x22d9 0x2769\n')
        self.cmdline.write_text(
            'console=tty0 oplusboot.serialno=8eab51c8 '
            'androidboot.serialno=ffffffff\n')
        self.serial_file.write_text('file-serial\n')
        self.hostname.write_text('hostname-serial\n')

    def run_ids(self, **extra):
        environment = dict(
            os.environ,
            CAIHONG_ADB_USB_IDS_FILE=str(self.ids),
            CAIHONG_ADB_COMPATIBLE_FILE=str(self.compatible),
            CAIHONG_ADB_SERIAL_FILE=str(self.serial_file),
            CAIHONG_ADB_CMDLINE_FILE=str(self.cmdline),
            CAIHONG_ADB_HOSTNAME_FILE=str(self.hostname),
        )
        environment.update(extra)
        return subprocess.run(
            [str(GADGET), 'ids'], env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def test_board_compatible_selects_factory_ids_and_kernel_serial(self):
        result = self.run_ids()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0x22d9 0x2769 8eab51c8\n')

    def test_multiple_board_entries_select_each_factory_identity(self):
        self.ids.write_text(
            'example,first 0x1111 0x2222\n'
            'example,second 0x3333 0x4444\n')
        for compatible, expected in [
            (b'example,first\0', '0x1111 0x2222 8eab51c8\n'),
            (b'example,second\0', '0x3333 0x4444 8eab51c8\n'),
        ]:
            self.compatible.write_bytes(compatible)
            result = self.run_ids()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_unknown_board_uses_standard_adb_ids(self):
        self.compatible.write_bytes(b'example,other\0')
        result = self.run_ids()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0x18d1 0x4ee7 8eab51c8\n')

    def test_environment_overrides_are_both_required(self):
        result = self.run_ids(CAIHONG_ADB_USB_VID='0x1234',
                              CAIHONG_ADB_USB_PID='0x5678')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0x1234 0x5678 8eab51c8\n')

        result = self.run_ids(CAIHONG_ADB_USB_VID='0x1234')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('set both', result.stderr)

    def test_serial_falls_back_to_board_file(self):
        self.cmdline.write_text('console=tty0\n')
        result = self.run_ids()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0x22d9 0x2769 file-serial\n')


if __name__ == '__main__':
    unittest.main()
