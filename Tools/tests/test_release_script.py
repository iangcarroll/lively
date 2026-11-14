#!/usr/bin/env python3
"""Release-script contract tests; Xcode is replaced by a temporary stub.

Run with: python3 Tools/tests/test_release_script.py
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "release" / "testflight.sh"
TEAM = "AB123CD456"

# This stub records only the public xcodebuild arguments and input artifacts.
# It never delegates to the real executable, even for unexpected arguments.
XCODE_STUB = r'''
#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
args = sys.argv[1:]
def value(flag):
    return args[args.index(flag) + 1]
record = {"args": args}
if args and args[0] == "archive":
    record["xcconfig"] = pathlib.Path(value("-xcconfig")).read_text()
    stage = "archive"
elif args and args[0] == "-exportArchive":
    record["options"] = plistlib.loads(pathlib.Path(value("-exportOptionsPlist")).read_bytes())
    stage = "export"
else:
    sys.exit("Unexpected xcodebuild command")
with open(os.environ["RELEASE_TEST_CALLS"], "a") as log:
    log.write(json.dumps(record) + "\n")
if os.environ.get("RELEASE_TEST_FAIL") == stage:
    sys.exit(9)
if stage == "archive":
    pathlib.Path(value("-archivePath")).mkdir(parents=True)
else:
    output = pathlib.Path(value("-exportPath"))
    output.mkdir(parents=True)
    (output / "Lively.ipa").write_bytes(b"stub export, not an application")
'''


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lively release tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "stub commands"
        self.bin.mkdir()
        stub = self.bin / "xcodebuild"
        stub.write_text(textwrap.dedent(XCODE_STUB).lstrip())
        stub.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        self.output = self.root / "release artifacts"
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith("LIVELY_")}
        self.environment.update(
            PATH=str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
            RELEASE_TEST_CALLS=str(self.log),
            # Fail closed if a future script bypasses PATH and calls Apple's shim.
            DEVELOPER_DIR=str(self.root / "not an Xcode installation"),
        )
        self.environment.pop("RELEASE_TEST_FAIL", None)

    def run_script(self, *args, team=TEAM, build="1", env=None, output=None):
        command = [str(SCRIPT)]
        if team is not None:
            command += ["--team", team]
        if build is not None:
            command += ["--build-number", build]
        if output is not False:
            command += ["--output", str(output or self.output)]
        environment = self.environment | (env or {})
        return subprocess.run(command + list(args), env=environment, cwd=self.root,
                              capture_output=True, text=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [], "Rejected input must not invoke Xcode")
        self.assertFalse(self.output.exists(), "Rejected input must not create artifacts")

    def config_file(self):
        path = self.root / "local configuration with spaces.xcconfig"
        path.write_text("LIVELY_APP_BUNDLE_ID = net.config.lively\n"
                        "LIVELY_APP_GROUP = group.net.config.lively\n"
                        "LIVELY_URL_SCHEME = config-lively\n"
                        "LIVELY_KEY_BROKER_URL = https:/$()/config.example.com\n")
        return path

    @staticmethod
    def explicit_settings(configuration):
        return dict(line.split(" = ", 1) for line in configuration.splitlines()
                    if " = " in line and not line.lstrip().startswith("//"))

    def test_help_and_dry_run_do_not_invoke_xcode_or_create_files(self):
        self.assert_success(self.run_script("--help", team=None, build=None))
        config = self.config_file()
        before = {path.relative_to(self.root): path.read_bytes()
                  for path in self.root.rglob("*") if path.is_file()}
        for mode in ((), ("--upload",)):
            with self.subTest(mode=mode):
                result = self.run_script("--config", str(config), "--dry-run", *mode)
                self.assert_success(result)
                self.assertIn("destination=" + ("upload" if mode else "export"), result.stdout)
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.output.exists())
                after = {path.relative_to(self.root): path.read_bytes()
                         for path in self.root.rglob("*") if path.is_file()}
                self.assertEqual(after, before)

    def test_team_and_build_are_required_and_validated(self):
        cases = [dict(team=None), dict(team=""), dict(team="short"),
                 dict(team="ab123cd456"), dict(team="AB123CD45!"), dict(build=None)]
        cases += [dict(build=value) for value in ("", "0", "-1", "10000", "1.100", "1.2.3.4", "202611140101", "1a")]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.assert_rejected(self.run_script("--dry-run", **arguments))
        for build in ("1", "42.1", "9999.99.99"):
            with self.subTest(build=build):
                self.assert_success(self.run_script("--dry-run", build=build))

    def test_invalid_overrides_and_arguments_fail_before_any_side_effect(self):
        cases = [
            ("--bundle-id", ""), ("--bundle-id", "bad id"), ("--bundle-id", "net..lively"),
            ("--app-group", "net.example.lively"), ("--app-group", "group.net.bad\"id"),
            ("--url-scheme", "1lively"), ("--url-scheme", "lively://listen"),
            ("--broker-url", "http://example.com"),
            ("--broker-url", "https://user:password@example.com"),
            ("--broker-url", "https://example.com/#fragment"),
            ("--broker-url", 'https://example.com/a"b'),
            ("--broker-url", "https://example.com/a\\b"),
            ("--broker-url", "https://example.com/a b"),
            ("--broker-url", "https://example.com/$(OTHER)"),
            ("--broker-url", "https://example.com/a/*/b"),
            ("--broker-url", "https://example.com/a*/b"),
            ("--output", ""), ("--config", str(self.root / "missing.xcconfig")),
            ("--configuration", "Debug"), ("--unknown",), ("--team",),
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.assert_rejected(self.run_script(*arguments))
        for name in ('quote".xcconfig', "line\nbreak.xcconfig", "back\\slash.xcconfig"):
            path = self.root / name
            path.write_text("")
            with self.subTest(config=name):
                self.assert_rejected(self.run_script("--config", str(path)))

    def test_default_export_and_explicit_upload_use_release_and_selected_team(self):
        for number, mode, destination in (("1", (), "export"), ("2", ("--upload",), "upload")):
            with self.subTest(destination=destination):
                self.assert_success(self.run_script(*mode, build=number))
                archive, export = self.calls()[-2:]
                args = archive["args"]
                self.assertEqual(args[0], "archive")
                self.assertEqual(args[args.index("-configuration") + 1], "Release")
                self.assertEqual(args[args.index("-destination") + 1], "generic/platform=iOS")
                self.assertEqual(export["args"][0], "-exportArchive")
                self.assertEqual(args[args.index("-archivePath") + 1],
                                 export["args"][export["args"].index("-archivePath") + 1])
                self.assertEqual(export["options"]["destination"], destination)
                self.assertEqual(export["options"]["method"], "app-store-connect")
                self.assertEqual(export["options"]["teamID"], TEAM)
                self.assertFalse(export["options"]["manageAppVersionAndBuildNumber"])
                settings = self.explicit_settings(archive["xcconfig"])
                self.assertEqual(settings["DEVELOPMENT_TEAM"], TEAM)
                self.assertEqual(settings["CURRENT_PROJECT_VERSION"], number)
                self.assertEqual(settings["CODE_SIGN_STYLE"], "Automatic")
                self.assertNotIn("PRODUCT_BUNDLE_IDENTIFIER", settings)
                self.assertNotIn("-allowProvisioningDeviceRegistration", args + export["args"])

    def test_config_is_preserved_then_environment_and_flags_override_it(self):
        config = self.config_file()
        original = config.read_bytes()
        env_config = self.root / "environment configuration.xcconfig"
        env_config.write_text("LIVELY_APP_BUNDLE_ID = net.environment.config\n")
        env = dict(LIVELY_RELEASE_CONFIG=str(env_config), LIVELY_RELEASE_DIR=str(self.output),
                   LIVELY_TEAM_ID="ZY987XW654", LIVELY_BUILD_NUMBER="7",
                   LIVELY_APP_BUNDLE_ID="net.environment.lively",
                   LIVELY_APP_GROUP="group.net.environment.lively",
                   LIVELY_URL_SCHEME="environment-lively",
                   LIVELY_KEY_BROKER_URL="https://environment.example.com")
        self.assert_success(self.run_script(env=env, team=None, build=None, output=False))
        generated = self.calls()[0]["xcconfig"]
        self.assertEqual(generated.splitlines()[0], '#include "' + str(env_config) + '"')
        settings = self.explicit_settings(generated)
        self.assertEqual(settings["DEVELOPMENT_TEAM"], env["LIVELY_TEAM_ID"])
        self.assertEqual(settings["CURRENT_PROJECT_VERSION"], "7")
        self.assertEqual(settings["LIVELY_APP_BUNDLE_ID"], env["LIVELY_APP_BUNDLE_ID"])
        self.assertEqual(settings["LIVELY_APP_GROUP"], env["LIVELY_APP_GROUP"])
        self.assertEqual(settings["LIVELY_URL_SCHEME"], env["LIVELY_URL_SCHEME"])
        self.assertEqual(settings["LIVELY_KEY_BROKER_URL"], "https:/$()/environment.example.com")
        self.assert_success(self.run_script("--config", str(config),
            "--bundle-id", "net.flags.lively", "--app-group", "group.net.flags.lively",
            "--url-scheme", "flags-lively", "--broker-url", "", env=env, build="8"))
        generated = self.calls()[-2]["xcconfig"]
        lines = generated.splitlines()
        self.assertEqual(lines[0], '#include "' + str(config) + '"')
        settings = self.explicit_settings(generated)
        self.assertEqual(settings["DEVELOPMENT_TEAM"], TEAM)
        self.assertEqual(settings["CURRENT_PROJECT_VERSION"], "8")
        self.assertEqual(settings["LIVELY_APP_BUNDLE_ID"], "net.flags.lively")
        self.assertEqual(settings["LIVELY_APP_GROUP"], "group.net.flags.lively")
        self.assertEqual(settings["LIVELY_URL_SCHEME"], "flags-lively")
        self.assertEqual(settings["LIVELY_KEY_BROKER_URL"], "")
        self.assertEqual(config.read_bytes(), original)

    def test_omitted_settings_preserve_config_and_explicit_empty_broker_disables_it(self):
        config = self.config_file()
        self.assert_success(self.run_script("--config", str(config)))
        generated = self.calls()[0]["xcconfig"]
        self.assertEqual(generated.splitlines()[0], '#include "' + str(config) + '"')
        settings = self.explicit_settings(generated)
        self.assertNotIn("LIVELY_APP_BUNDLE_ID", settings)
        self.assertNotIn("LIVELY_APP_GROUP", settings)
        self.assertNotIn("LIVELY_URL_SCHEME", settings)
        self.assertNotIn("LIVELY_KEY_BROKER_URL", settings)
        self.assert_success(self.run_script("--config", str(config), build="2",
                                           env={"LIVELY_KEY_BROKER_URL": ""}))
        self.assertEqual(self.explicit_settings(self.calls()[-2]["xcconfig"])["LIVELY_KEY_BROKER_URL"], "")

    def test_url_escaping_and_paths_with_spaces_reach_xcode_as_single_arguments(self):
        config = self.config_file()
        url = "https://broker.example.com/api//v1/%2A?x=1&y=2"
        self.assert_success(self.run_script("--config", str(config), "--broker-url", url))
        archive, export = self.calls()
        config_argument = Path(archive["args"][archive["args"].index("-xcconfig") + 1])
        self.assertEqual(config_argument.parent, self.output)
        self.assertTrue(config_argument.is_file())
        export_path = Path(export["args"][export["args"].index("-exportPath") + 1])
        self.assertEqual(export_path.parent, self.output)
        self.assertTrue((export_path / "Lively.ipa").is_file())
        escaped = self.explicit_settings(archive["xcconfig"])["LIVELY_KEY_BROKER_URL"]
        self.assertNotIn("//", escaped)
        self.assertEqual(escaped.replace("$()", ""), url)

    def test_failed_archive_cannot_export_or_upload(self):
        result = self.run_script("--upload", env={"RELEASE_TEST_FAIL": "archive"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse(any(path.name == "Lively.ipa" for path in self.root.rglob("*")))

    def test_existing_artifacts_are_not_overwritten(self):
        self.assert_success(self.run_script())
        original_calls = self.calls()
        archive_args, export_args = (call["args"] for call in original_calls)
        archive = Path(archive_args[archive_args.index("-archivePath") + 1])
        export = Path(export_args[export_args.index("-exportPath") + 1])
        for existing in ("both", "export only", "archive only"):
            with self.subTest(existing=existing):
                if existing == "export only":
                    shutil.rmtree(archive)
                elif existing == "archive only":
                    archive.mkdir()
                    shutil.rmtree(export)
                result = self.run_script("--upload")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), original_calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
