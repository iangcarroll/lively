#!/usr/bin/env python3
"""Opt-in Simulator checks for production conversation view states.

Run on a booted simulator with Xcode installed:
  python3 Tools/tests/ui_state_regression.py --device-id UUID --negative-controls

The generated host is separate from Lively. Actual view/model sources are copied
at runtime; only the Store, settings and unrelated controls are substituted.
No microphone, network, credentials, or main-app QA launch arguments are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).parent
SOURCES = [
    "Lively/Model/Language.swift", "Lively/Model/Utterance.swift",
    "Lively/Model/Filler.swift", "Lively/Model/Phrases.swift",
    "Lively/Views/Theme.swift", "Lively/Views/FaceToFaceScreen.swift",
    "Lively/Model/ListeningPromptPolicy.swift", "Lively/Views/ListeningPromptVisibility.swift",
    "Lively/Views/Transcripts.swift", "Lively/Views/UtteranceBubble.swift",
    "Lively/Views/ConversationTranscriptLayout.swift",
]
EXTRACTED_SOURCES = ["Lively/Views/Controls.swift", "Lively/Views/ConversationScreen.swift"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, *, check=True, timeout=180):
    environment = os.environ.copy()
    environment.pop("SDKROOT", None)
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, env=environment,
                                stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
    return result.returncode


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Production UI changed; update the focused fault control: " + old)
    return source.replace(old, new)


def declaration(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def production_footer():
    # Exercise the actual footer that is mounted by ConversationScreen. Only
    # unrelated audio/icon controls and the text-input dependency are stubbed.
    controls = (ROOT / EXTRACTED_SOURCES[0]).read_text()
    screen = (ROOT / EXTRACTED_SOURCES[1]).read_text()
    return "\n".join([
        "import SwiftUI", declaration(controls, "struct TranscriptListeningStatus: View"),
        declaration(controls, "struct MicButton: View"),
        declaration(controls, "private struct PressReportingStyle: ButtonStyle"),
        declaration(controls, "struct GlassIconButton: View"),
        declaration(controls, "struct StatusPill: View").replace("struct StatusPill: View", "struct FixtureStatusPill: View", 1),
        declaration(screen, "private struct KeyboardButtonBounds: PreferenceKey"),
        """struct ProductionTranscriptFooter: View {
 let store: ConversationStore
 let settings = AppSettings.shared
 @Binding var showsTextInput: Bool
 @Binding var editing: Utterance?
 let showsListeningPrompt: Bool
 @FocusState private var textInputFocused: Bool
 @Environment(\\.accessibilityReduceMotion) private var reduceMotion
 var body: some View { controls(column: nil) }
 private func setTextInput(_ shown: Bool) { showsTextInput = shown; textInputFocused = shown }
""",
        declaration(screen, "private func controls(column: StatusColumn?)"),
        declaration(screen, "private func controlRow(column: StatusColumn?)"), "}",
        """struct ProductionTranscriptHeader: View {
 let store: ConversationStore
 let wide: Bool
 let settings = AppSettings.shared
 @State private var phoneShowsTranscript = true
 @State private var showSettings = false
 private func openAddress() {}
 var body: some View { topBar(wide: wide, column: nil) }
""",
        declaration(screen, "private func topBar(wide: Bool, column: StatusColumn?)"),
        "@ViewBuilder\n" + declaration(screen, "private func trailingButtons(wide: Bool)"), "}",
    ])


def build_host(work, bundle_id, variant, original):
    source_dir = work / "Sources"
    for name, source in original.items():
        (source_dir / name).write_text(source)
    if variant == "missing-empty-error":
        path = source_dir / "FaceToFaceScreen.swift"
        path.write_text(replace_once(path.read_text(),
            "if !ownWords && !neutral && utterance.hasTranslationProblem {\n"
            "                        statusLine(utterance, language: rowLanguage)\n"
            "                    } else if utterance.showsLanguagePrompt {",
            "if utterance.showsLanguagePrompt {"))
    elif variant == "false-partner-wait":
        path = source_dir / "Theme.swift"
        path.write_text(replace_once(path.read_text(),
            "} else if utterance.waitsForAutomaticPartner {",
            "} else if utterance.isAwaitingLanguage {"))
    elif variant == "footer-overlays-transcript":
        path = source_dir / "ConversationTranscriptLayout.swift"
        path.write_text(replace_once(path.read_text(),
            "            footer.layoutPriority(1)\n        }",
            "        }\n        .overlay(alignment: .bottom) { footer.layoutPriority(1) }"))
    elif variant == "native-layout-unavailable":
        path = source_dir / "ConversationTranscriptLayout.swift"
        source = replace_once(path.read_text(), "                viewportSize = metrics.viewport\n", "")
        path.write_text(replace_once(source, "                contentSize = metrics.content\n", ""))
    elif variant == "native-viewport-unobserved":
        path = source_dir / "ConversationTranscriptLayout.swift"
        path.write_text(replace_once(path.read_text(), "                viewportSize = metrics.viewport\n", ""))
    elif variant == "manual-scroll-intent-ignored":
        path = source_dir / "ConversationTranscriptLayout.swift"
        path.write_text(replace_once(path.read_text(),
            "phase == .tracking || phase == .interacting || phase == .decelerating", "false"))
    elif variant == "streaming-alignment-removed":
        path = source_dir / "ConversationTranscriptLayout.swift"
        source = path.read_text()
        source = replace_once(source, declaration(source, ".onChange(of: textRevision)"), "")
        source = replace_once(source, declaration(source, "private func requestAlignment(for change: Reflow)"),
                              "private func requestAlignment(for change: Reflow) {}")
        if ".defaultScrollAnchor(followsBottom ? .bottom : nil, for: .sizeChanges)" in source:
            source = replace_once(source,
                ".defaultScrollAnchor(followsBottom ? .bottom : nil, for: .sizeChanges)",
                ".defaultScrollAnchor(nil, for: .sizeChanges)")
        path.write_text(source)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
    app = work / "StateFixture.app"
    files = [*sorted(source_dir.glob("*.swift")), work / "UIStateBoundaries.swift", work / "UIStateHost.swift"]
    run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
         "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
         "-sdk", sdk, "-target", f"{architecture}-apple-ios26.0-simulator",
         "-module-cache-path", str(work / "modules"), "-module-name", "StateFixture",
         *map(str, files), "-o", str(app / "StateFixture")], work / f"build-{variant}.log")
    info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "StateFixture",
            "NSAccentColorName": "AccentColor",
            "CFBundleName": "StateFixture", "CFBundleDisplayName": "UI State Checks",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "26.0",
            "UIDeviceFamily": [1, 2], "UIApplicationSceneManifest": {
                "UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {}},
            "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    run(["codesign", "--force", "--sign", "-", str(app)], work / f"sign-{variant}.log")
    return app


PROJECT = r'''
// !$*UTF8*$!
{
 archiveVersion = 1; classes = {}; objectVersion = 56;
 objects = {
 A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2600;}; buildConfigurationList = A00000000000000000000010; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A00000000000000000000002; productRefGroup = A00000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000004); };
 A00000000000000000000002 = {isa = PBXGroup; children = (A00000000000000000000005, A00000000000000000000003); sourceTree = "<group>";};
 A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000006); name = Products; sourceTree = "<group>";};
 A00000000000000000000004 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000011; buildPhases = (A00000000000000000000007, A00000000000000000000008, A00000000000000000000009); buildRules = (); dependencies = (); name = UIStateRegression; productName = UIStateRegression; productReference = A00000000000000000000006; productType = "com.apple.product-type.bundle.ui-testing";};
 A00000000000000000000005 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UIStateRegression.swift; sourceTree = "<group>";};
 A00000000000000000000006 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = UIStateRegression.xctest; sourceTree = BUILT_PRODUCTS_DIR;};
 A00000000000000000000007 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000012); runOnlyForDeploymentPostprocessing = 0;};
 A00000000000000000000008 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
 A00000000000000000000009 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
 A00000000000000000000010 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000013); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;};
 A00000000000000000000011 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000014); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;};
 A00000000000000000000012 = {isa = PBXBuildFile; fileRef = A00000000000000000000005;};
 A00000000000000000000013 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphonesimulator; SWIFT_VERSION = 6.0; IPHONEOS_DEPLOYMENT_TARGET = 26.0;}; name = Debug;};
 A00000000000000000000014 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = NO; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = __RUNNER_ID__; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphonesimulator; SUPPORTED_PLATFORMS = iphonesimulator; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = "1,2"; IPHONEOS_DEPLOYMENT_TARGET = 26.0;}; name = Debug;};
 }; rootObject = A00000000000000000000001;
}
'''

SCHEME = r'''
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000004" BuildableName="UIStateRegression.xctest" BlueprintName="UIStateRegression" ReferencedContainer="container:UIStateRegression.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000004" BuildableName="UIStateRegression.xctest" BlueprintName="UIStateRegression" ReferencedContainer="container:UIStateRegression.xcodeproj"/></TestableReference></Testables></TestAction>
</Scheme>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-id", required=True, help="UDID of an already booted iOS Simulator")
    parser.add_argument("--negative-controls", action="store_true")
    parser.add_argument("--output-dir", type=Path, help="keep build logs and xcresults here (must be empty)")
    parser.add_argument("--only-testing", action="append", default=[], metavar="METHOD",
                        help="run selected production fixture methods during focused development")
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))
    selected = [d for group in devices["devices"].values() for d in group if d["udid"] == args.device_id]
    if len(selected) != 1 or selected[0]["state"] != "Booted":
        parser.error("Select one already booted Simulator; physical devices are not supported")
    test_names = re.findall(r"    func (test\w+)\(", (TESTS / "UIStateRegression.swift").read_text())
    if any(name not in test_names for name in args.only_testing):
        parser.error("--only-testing must name an existing UIStateRegression test")
    expected_tests = len(set(args.only_testing)) if args.only_testing else len(test_names)
    work = args.output_dir.resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix="lively-ui-states-"))
    if args.output_dir and work.exists() and any(work.iterdir()):
        parser.error("--output-dir must be empty to preserve earlier evidence")
    work.mkdir(parents=True, exist_ok=True)
    suffix = uuid.uuid4().hex
    host_id = "org.lively.regression.ui." + suffix
    runner_id = "org.lively.regression.runner." + suffix
    source_dir = work / "Sources"
    source_dir.mkdir()
    hashes = {}
    for source in [*SOURCES, *EXTRACTED_SOURCES]:
        path = ROOT / source
        hashes[source] = digest(path)
        if source in SOURCES:
            shutil.copy2(path, source_dir / path.name)
    (source_dir / "ProductionTranscriptFooter.swift").write_text(production_footer())
    for name in ["UIStateBoundaries.swift", "UIStateHost.swift"]:
        shutil.copy2(TESTS / name, work / name)
    (work / "UIStateRegression.swift").write_text((TESTS / "UIStateRegression.swift").read_text().replace("__UI_STATE_BUNDLE_ID__", host_id))
    project = work / "UIStateRegression.xcodeproj"
    scheme = project / "xcshareddata/xcschemes/UIStateRegression.xcscheme"
    scheme.parent.mkdir(parents=True)
    (project / "project.pbxproj").write_text(PROJECT.replace("__RUNNER_ID__", runner_id))
    scheme.write_text(SCHEME.lstrip())
    app = work / "StateFixture.app"
    app.mkdir()
    asset_command = ["xcrun", "actool", str(ROOT / "Lively/Assets.xcassets"), "--compile", str(app),
         "--output-format", "human-readable-text", "--output-partial-info-plist", str(work / "asset-info.plist"),
         "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", "26.0",
         "--platform", "iphonesimulator", "--bundle-identifier", host_id]
    # Symbol generation is a separate actool action: combining the actions
    # silently omits Assets.car and makes named colors disappear in the host.
    run(asset_command, work / "assets.log")
    if not (app / "Assets.car").is_file():
        raise RuntimeError("The UI host must contain its actual color catalog")
    run([*asset_command, "--generate-swift-asset-symbols", str(source_dir / "GeneratedAssetSymbols.swift")],
        work / "asset-symbols.log")
    original = {p.name: p.read_text() for p in source_dir.glob("*.swift")}
    variants = [("production", None, False)]
    if args.negative_controls:
        variants += [("native-layout-unavailable", "testPopulatedChatKeepsNewestAboveGuidance", False),
                     ("missing-empty-error", "testControlledFaceFailureAndNetwork", True),
                     ("false-partner-wait", "testControlledKnownPartnerLiveAndUnknown", True),
                     ("footer-overlays-transcript", "testPopulatedChatKeepsNewestAboveGuidance", True),
                     ("native-viewport-unobserved", "testPopulatedFaceKeepsNewestAboveGuidance", True),
                     ("manual-scroll-intent-ignored", "testManualHistoryPositionSurvivesGuidanceAndRevision", True),
                     ("streaming-alignment-removed", "testContinuousSameRowUpdatesKeepNewestBottomVisible", True)]
    report = {"scope": "Actual view/model sources; controlled Store/settings/unrelated UI boundary only. No speech or hardware proof.",
              "device": selected[0], "source_sha256": hashes, "custom_main_app_qa_arguments": [],
              "asset_catalog_sha256": digest(app / "Assets.car"),
              "instrumented_host_copy": False,
              "selected_production_tests": args.only_testing or test_names, "variants": []}
    try:
        for variant, test, is_fault in variants:
            app = build_host(work, host_id, variant, original)
            binary_hash = digest(app / "StateFixture")
            run(["xcrun", "simctl", "install", args.device_id, str(app)], work / f"install-{variant}.log")
            result = work / f"{variant}.xcresult"
            log = work / f"test-{variant}.log"
            command = ["xcodebuild", "-project", str(project), "-scheme", "UIStateRegression",
                       "-destination", f"platform=iOS Simulator,id={args.device_id}",
                       "-derivedDataPath", str(work / "Derived"), "-parallel-testing-enabled", "NO",
                       "-resultBundlePath", str(result)]
            if test:
                command += ["-only-testing:UIStateRegression/UIStateRegression/" + test]
            else:
                for name in args.only_testing:
                    command += ["-only-testing:UIStateRegression/UIStateRegression/" + name]
            code = run([*command, "test"], log, check=False, timeout=600)
            text = log.read_text()
            count = 1 if test else expected_tests
            passed = code == 0 and f"Executed {count} test" in text and "with 0 failures" in text
            assertion = "XCTAssertTrue failed" if variant in {"missing-empty-error", "false-partner-wait"} else "XCTAssert"
            detected = (code != 0 and "** TEST FAILED **" in text and assertion in text
                        and "with 1 failure (0 unexpected)" in text and "** BUILD FAILED **" not in text)
            record = {"name": variant, "host_binary_sha256": binary_hash, "exit_code": code,
                      "log": str(log), "log_sha256": digest(log), "result": str(result),
                      "production_cases_passed": passed if not is_fault else None,
                      "unavailable_native_geometry_boundary": variant == "native-layout-unavailable",
                      "assertion_control_detected": detected if is_fault else None}
            report["variants"].append(record)
            if (is_fault and not detected) or (not is_fault and not passed):
                raise RuntimeError(f"Unexpected UI result for {variant}; see {log}")
            print(f"PASS: {variant}" + (" (assertion control detected)" if is_fault else f" ({count} cases, transcript states and viewport geometry)"), flush=True)
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        for identifier in [host_id, runner_id + ".xctrunner"]:
            run(["xcrun", "simctl", "terminate", args.device_id, identifier], work / (identifier + "-stop.log"), check=False)
            run(["xcrun", "simctl", "uninstall", args.device_id, identifier], work / (identifier + "-remove.log"), check=False)
        report["source_unchanged"] = all(digest(ROOT / p) == value for p, value in hashes.items())
        (work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["source_unchanged"]:
        raise RuntimeError("Production source changed during the run; evidence records the copied snapshot")
    print(f"UI regression evidence: {work / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
