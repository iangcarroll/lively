#!/usr/bin/env python3
"""Test the production offline engine with controlled Speech and native audio.

No microphone, model download, network, or retained speech is used. These checks
validate app lifecycle and turn policy; device speech accuracy needs separate QA.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--negative-controls', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = (root / 'Lively/Networking/OfflineSpeechEngine.swift').read_text()
    source = source[:source.index('\nextension SpeechProvider {')]
    source = source.replace('import Speech\n', '')
    fixture = Path(__file__).with_name('OfflineSpeechRegression.swift').read_text()
    variants = [('current', source, False)]
    if args.negative_controls:
        mutations = {
            'wrong-speaker': ('self.spokenLanguage = languages.contains(chosen) ? chosen : languages.first', 'self.spokenLanguage = languages.first'),
            'stale-setup': ('if runID == self.runID { startTask = nil }', 'startTask = nil'),
            'missing-assets': ('guard status == .installed else { throw OfflineSpeechError.notDownloaded(language.englishName) }', '_ = status'),
            'old-turn-result': ('let lowerBound = max(turnStartTime, finalizedThrough)', 'let lowerBound = CMTime.negativeInfinity'),
        }
        for name, (old, replacement) in mutations.items():
            if source.count(old) != 1:
                raise RuntimeError('Review mutation for updated source: ' + name)
            variants.append((name, source.replace(old, replacement), True))
    with tempfile.TemporaryDirectory(prefix='lively-offline-engine-') as directory:
        work = Path(directory)
        for name, candidate, negative in variants:
            swift = work / 'Regression.swift'
            swift.write_text(fixture.replace('// INSERT_ACTUAL_OFFLINE_ENGINE', candidate))
            executable = work / name
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-module-cache-path', str(work / 'modules'), '-parse-as-library', str(swift), '-o', str(executable)], check=True, timeout=90)
            result = subprocess.run([str(executable)], capture_output=negative, text=negative, timeout=30)
            if negative:
                if result.returncode != 1 or 'FAIL:' not in result.stdout:
                    raise RuntimeError(f'Negative control {name} was not detected:\n{result.stdout}\n{result.stderr}')
                print('PASS: negative control ' + name + ' detected')
            elif result.returncode != 0:
                raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
