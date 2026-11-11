import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / 'rootfs/archlinuxarm/usr/local/sbin/caihong-autocharge'
loader = importlib.machinery.SourceFileLoader('caihong_autocharge', str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
autocharge = importlib.util.module_from_spec(spec)
loader.exec_module(autocharge)


class AutoChargeTests(unittest.TestCase):
    def setUp(self):
        output = PROJECT.parent / 'build/caihong-autocharge-tests'
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=output)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.battery = self.root / 'battery'
        (self.battery / 'device').mkdir(parents=True)
        self.diagnostic = self.battery / 'device/oneplus_charge_control_status'
        self.helper = self.root / 'caihong-charge'
        self.helper.write_text('#!/bin/sh\nexit 0\n')
        self.helper.chmod(0o755)
        self.config = self.root / 'caihong-autocharge.json'
        self.write('capacity', '72')
        self.write('charge_behaviour', '[auto] inhibit-charge')
        self.write('charge_control_start_threshold', '95')
        self.write('charge_control_end_threshold', '100')
        self.write_diagnostic(70)
        self.patch('BATTERY', self.battery)
        self.patch('DIAGNOSTIC', self.diagnostic)
        self.patch('HELPER', self.helper)
        self.patch('CONFIG', self.config)
        self.run = patch.object(autocharge.subprocess, 'run')
        self.run_mock = self.run.start()
        self.run_mock.return_value = Mock(returncode=0, stdout='', stderr='')
        self.addCleanup(self.run.stop)

    def patch(self, name, value):
        item = patch.object(autocharge, name, value)
        item.start()
        self.addCleanup(item.stop)

    def write(self, name, value):
        (self.battery / name).write_text(value + '\n')

    def write_diagnostic(self, raw_soc):
        self.diagnostic.write_text(
            'inhibited=0 applied=0 pending=0 latched=0 suspended=0 '
            f'raw_soc={raw_soc} last_rc=0\n')

    def settings(self, **overrides):
        config = dict(autocharge.DEFAULTS)
        config.update(overrides)
        return autocharge.validate(config)

    def test_raw_soc_is_preferred_over_capacity(self):
        self.assertEqual(autocharge.state_of_charge(), (70, 'raw_soc'))

    def test_capacity_is_used_without_diagnostic(self):
        self.diagnostic.unlink()
        self.assertEqual(autocharge.state_of_charge(), (72, 'capacity'))

    def test_inhibits_charging_at_stop_threshold(self):
        self.write_diagnostic(80)
        self.assertEqual(autocharge.evaluate(self.settings()), ('inhibit', 80, 'raw_soc'))
        self.run_mock.assert_called_once()
        self.assertEqual(self.run_mock.call_args.args[0],
                         [str(self.helper), 'bypass', 'on'])

    def test_allows_charging_at_resume_threshold(self):
        self.write('charge_behaviour', '[inhibit-charge] auto')
        self.write_diagnostic(79)
        self.assertEqual(autocharge.evaluate(self.settings()), ('allow', 79, 'raw_soc'))
        self.run_mock.assert_called_once()
        self.assertEqual(self.run_mock.call_args.args[0],
                         [str(self.helper), 'bypass', 'off'])

    def test_deadband_leaves_state_alone(self):
        self.write_diagnostic(75)
        self.assertEqual(autocharge.evaluate(self.settings(resume=70)), ('none', 75, 'raw_soc'))
        self.run_mock.assert_not_called()

    def test_already_inhibited_is_not_rewritten(self):
        self.write('charge_behaviour', '[inhibit-charge] auto')
        self.write_diagnostic(85)
        self.assertEqual(autocharge.evaluate(self.settings()), ('none', 85, 'raw_soc'))
        self.run_mock.assert_not_called()

    def test_dry_run_does_not_apply(self):
        self.write_diagnostic(85)
        with contextlib.redirect_stdout(io.StringIO()):
            result = autocharge.evaluate(self.settings(), dry_run=True)
        self.assertEqual(result, ('inhibit', 85, 'raw_soc'))
        self.run_mock.assert_not_called()
        self.assertEqual((self.battery / 'charge_behaviour').read_text().strip(),
                         '[auto] inhibit-charge')

    def test_helper_failure_is_reported(self):
        self.run_mock.return_value = Mock(returncode=1, stdout='', stderr='controller busy')
        self.write_diagnostic(85)
        with self.assertRaisesRegex(RuntimeError, 'controller busy'):
            autocharge.evaluate(self.settings())

    def test_missing_helper_writes_behaviour_directly(self):
        missing = self.root / 'missing-caihong-charge'
        with patch.object(autocharge, 'HELPER', missing):
            self.write_diagnostic(85)
            autocharge.evaluate(self.settings())
        self.run_mock.assert_not_called()
        self.assertEqual((self.battery / 'charge_behaviour').read_text().strip(),
                         'inhibit-charge')

    def test_defaults_are_used_without_config_file(self):
        self.assertEqual(autocharge.load(self.config), autocharge.DEFAULTS)

    def test_config_file_is_loaded(self):
        self.config.write_text(json.dumps({'stop': 75, 'resume': 70, 'interval': 60}) + '\n')
        self.assertEqual(autocharge.load(self.config),
                         {'stop': 75, 'resume': 70, 'interval': 60})

    def test_config_rejects_resume_not_lower_than_stop(self):
        with self.assertRaisesRegex(ValueError, 'resume must be lower than stop'):
            autocharge.validate({'stop': 80, 'resume': 80, 'interval': 30})

    def test_config_rejects_non_finite_interval(self):
        for interval in (float('inf'), float('nan'), 0, -1, 10 ** 9):
            with self.subTest(interval=interval):
                with self.assertRaisesRegex(ValueError, 'interval must be'):
                    autocharge.validate({'stop': 80, 'resume': 79, 'interval': interval})

    def test_config_rejects_unknown_keys(self):
        self.config.write_text(json.dumps({'stop': 80, 'resume': 79, 'interval': 30,
                                           'charge_limit': 80}) + '\n')
        with self.assertRaisesRegex(ValueError, 'unsupported keys'):
            autocharge.load(self.config)

    def test_status_reports_thresholds_and_warns(self):
        self.write('charge_control_end_threshold', '75')
        self.write_diagnostic(70)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            autocharge.status(self.settings())
        text = output.getvalue()
        self.assertIn('state of charge: 70% (raw_soc)', text)
        self.assertIn('decision: allow', text)
        self.assertIn('stop / resume: 80% / 79%', text)
        self.assertIn('kernel thresholds: start=95 end=75', text)
        self.assertIn('warning: kernel end threshold 75%', text)

    def test_status_warns_when_kernel_start_is_below_resume(self):
        self.write('charge_control_start_threshold', '75')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            autocharge.status(self.settings())
        self.assertIn('kernel start threshold 75%', output.getvalue())

    def test_status_survives_missing_sysfs(self):
        missing = self.root / 'missing'
        with patch.object(autocharge, 'BATTERY', missing), \
                patch.object(autocharge, 'DIAGNOSTIC', missing / 'status'):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                autocharge.status(self.settings())
        text = output.getvalue()
        self.assertIn('state of charge: unavailable', text)
        self.assertIn('charge_behaviour: unavailable', text)
        self.assertIn('decision: unavailable', text)


if __name__ == '__main__':
    unittest.main()
