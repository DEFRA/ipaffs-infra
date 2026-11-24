"""Verify that Bicep compilation uses the pinned Azure CLI-managed binary."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("ensure-bicep-version.sh")
VERSION = "0.49.2"


class BicepCompilerPreparationTests(unittest.TestCase):
    def prepare(self, initial, install_fails=False, install_version=VERSION):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            state, calls = directory / "version", directory / "calls"
            state.write_text(initial)
            fake = directory / "az"
            fake.write_text("#!/usr/bin/env python3\n" +
                "import json,os,sys\nfrom pathlib import Path\n" +
                f"state=Path({str(state)!r}); calls=Path({str(calls)!r})\n" +
                "with calls.open('a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')\n" +
                "if os.environ.get('AZURE_BICEP_USE_BINARY_FROM_PATH') != 'false': sys.exit(98)\n" +
                "if sys.argv[1:3] == ['bicep','version']:\n" +
                " version=state.read_text(); print('Bicep CLI version '+version+' (fixture)') if version else None\n" +
                " sys.exit(0 if version else 1)\n" +
                "if sys.argv[1:3] == ['bicep','install']:\n" +
                f" sys.exit(9) if {install_fails!r} else state.write_text({install_version!r})\n" +
                " sys.exit(0)\n" +
                "sys.exit(99)\n")
            fake.chmod(0o755)
            result = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True,
                                    env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                                         "AZURE_BICEP_USE_BINARY_FROM_PATH": "true"}, timeout=10)
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_matching_compiler_needs_no_installation(self):
        result, calls = self.prepare(VERSION)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(any(call[:2] == ["bicep", "install"] for call in calls))
        self.assertEqual(f"Verified Bicep CLI version {VERSION}", result.stdout.strip())

    def test_missing_older_and_newer_compilers_are_pinned(self):
        for initial in ("", "0.36.1", "0.49.3", f"{VERSION}-preview"):
            with self.subTest(initial=initial):
                result, calls = self.prepare(initial)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(["bicep", "install", "--version", f"v{VERSION}", "--only-show-errors"], calls[1])
                self.assertEqual(["bicep", "version", "--only-show-errors"], calls[-1])

    def test_failed_installation_stops_preparation(self):
        result, calls = self.prepare("0.36.1", install_fails=True)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(2, len(calls))

    def test_unexpected_compiler_after_installation_is_rejected(self):
        result, _ = self.prepare("0.36.1", install_version="0.37.0")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("refusing to compile", result.stderr)


if __name__ == "__main__":
    unittest.main()
