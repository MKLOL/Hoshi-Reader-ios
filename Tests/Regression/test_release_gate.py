import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ios_parity_gate", ROOT / "tools/test_ios_parity.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.dependencies = patch.object(gate, "require_dependencies")
        self.dependencies.start()
        self.addCleanup(self.dependencies.stop)

    def test_missing_dependency_fails_before_creating_a_simulator(self):
        self.dependencies.stop()
        with patch.object(gate.importlib.util, "find_spec", return_value=None), \
             patch.object(gate.subprocess, "check_output") as command:
            with self.assertRaisesRegex(RuntimeError, "requires.*regex"):
                gate.main()
        command.assert_not_called()

    def test_missing_node_or_swift_fails_instead_of_skipping_behavior_tests(self):
        self.dependencies.stop()
        for missing in ("node", "swift", "swiftc"):
            with self.subTest(missing=missing), \
                 patch.object(gate.importlib.util, "find_spec", return_value=object()), \
                 patch.object(gate.shutil, "which", side_effect=lambda name: None if name == missing else "/tool/" + name), \
                 patch.object(gate.subprocess, "check_output") as command:
                with self.assertRaisesRegex(RuntimeError, missing):
                    gate.main()
                command.assert_not_called()

    def runtime(self):
        return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True,
                "supportedDeviceTypes": [{"identifier": "iphone-fixture", "productFamily": "iPhone"}]}

    def test_missing_runtime_fails_without_using_an_existing_device(self):
        with self.assertRaises(RuntimeError):
            gate.simulator_type([])
        unavailable = dict(self.runtime(), isAvailable=False)
        with self.assertRaises(RuntimeError):
            gate.simulator_type([unavailable])

    def test_test_failure_is_returned_and_only_owned_device_is_deleted(self):
        import json
        with patch.object(gate.subprocess, "check_output", side_effect=[json.dumps({"runtimes": [self.runtime()]}), "owned-device\n"]), \
             patch.object(gate.subprocess, "run", return_value=subprocess.CompletedProcess([], 7)) as run:
            self.assertEqual(gate.main(), 7)
        self.assertIn("Hoshi regression iPhone", run.call_args_list[0].kwargs["env"]["HOSHI_IOS_SIMULATOR"])
        self.assertEqual(run.call_args_list[1].args[0], ["xcrun", "simctl", "shutdown", "owned-device"])
        self.assertEqual(run.call_args_list[2].args[0], ["xcrun", "simctl", "delete", "owned-device"])

    def test_interruption_still_removes_only_owned_device(self):
        import json
        with patch.object(gate.subprocess, "check_output", side_effect=[json.dumps({"runtimes": [self.runtime()]}), "owned-device"]), \
             patch.object(gate.subprocess, "run", side_effect=[KeyboardInterrupt(), subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0)]) as run:
            with self.assertRaises(KeyboardInterrupt):
                gate.main()
        self.assertEqual(run.call_args_list[-1].args[0], ["xcrun", "simctl", "delete", "owned-device"])

    def test_ui_gate_must_execute_its_named_case_and_pass(self):
        import json
        playback_only = "Test Case '-[HoshiReaderUITests.PodcastTranscriptUITests testTimestampPlaybackWordLookupEnglishAndFollowing]' passed\n** TEST SUCCEEDED **"
        success = playback_only + "\nTest Case '-[HoshiReaderUITests.PodcastTranscriptUITests testReaderAppearanceIsAvailableInsideTranscript]' passed"
        for log, status, expected in [(success, 0, 0), (playback_only, 0, 1), ("** TEST SUCCEEDED **", 0, 1), (success, 65, 65)]:
            with self.subTest(status=status, log=log), tempfile.TemporaryDirectory() as directory:
                calls = []
                def run(command, **kwargs):
                    calls.append(command)
                    if command[0] == "xcodebuild":
                        kwargs["stdout"].write(log)
                        return subprocess.CompletedProcess(command, status)
                    return subprocess.CompletedProcess(command, 0)
                with patch.object(gate, "ROOT", Path(directory)), \
                     patch.object(gate.subprocess, "check_output", side_effect=[json.dumps({"runtimes": [self.runtime()]}), "owned-device"]), \
                     patch.object(gate.subprocess, "run", side_effect=run):
                    self.assertEqual(gate.main(), expected)
                self.assertIn("tools/sync-test-server", calls[0])
                self.assertIn("Tests/Regression", calls[1])
                self.assertIn("-only-testing:HoshiReaderUITests/PodcastTranscriptUITests", calls[2])
                self.assertEqual(calls[-1], ["xcrun", "simctl", "delete", "owned-device"])
