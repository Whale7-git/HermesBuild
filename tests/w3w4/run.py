#!/usr/bin/env python3
"""Offline independent runner; never changes production files or release scope."""
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
BUILD = ROOT / '.build' / 'w3w4'
BUILD.mkdir(parents=True, exist_ok=True)
(BUILD / 'tmp').mkdir(exist_ok=True)
os.environ['TMPDIR'] = str(BUILD / 'tmp')


def run(argv):
    print('+ ' + shlex.join(map(str, argv)), flush=True)
    result = subprocess.run(list(map(str, argv)))
    print('EXIT_CODE=' + str(result.returncode), flush=True)
    return result.returncode


def sources_for(suite):
    line = next(line for line in (ROOT / 'tests/run_container.sh').read_text().splitlines()
                if line.startswith('run ' + suite + ' '))
    return [part.replace('$S/', 'Sources/HermesShell/') for part in shlex.split(line)[2:]]


def main():
    suite = sys.argv[1] if len(sys.argv) > 1 else 'races'
    if suite == 'observation':
        # Reuse existing transport/UI fixtures, not another AppState implementation.
        appstate_test = (ROOT / 'tests/appstate/main.swift').read_text()
        fixtures = (appstate_test.split('@main struct AppStateTests')[0]
                    + appstate_test[appstate_test.index('extension HermesAPI: HermesBackend'):])
        race = (ROOT / 'tests/w3w4/main.swift').read_text()
        service = race[race.index('@MainActor final class RaceService'):race.index('enum RaceFailure')]
        view = (ROOT / 'Sources/HermesShell/NativeChatView.swift').read_text()
        begin = view.index('    private func recordTaskSignals()')
        end = view.index('\n    var body:', begin)
        harness = ('@MainActor struct ObservationHarness {\n'
                   'let model: NativeChatModel\nlet app: AppState\nlet sessionID: String\n'
                   'func observe() { recordTaskSignals() }\n' + view[begin:end] + '\n}\n')
        generated = BUILD / 'ObservationMain.swift'
        generated.write_text(fixtures + service + harness + (ROOT / 'tests/w3w4/TaskObservation.swift').read_text())
        sources = [p for p in sources_for('model') if not p.startswith('tests/model/')]
        for p in sources_for('appstate'):
            if p.endswith('.swift') and not p.startswith('tests/') and p not in sources:
                sources.append(p)
        sources.append(str(generated))
        binary = BUILD / 'observation'
    elif suite == 'export-recovery':
        generated = BUILD / 'ChatExportController.swift'
        # The production controller is unchanged except for its UI-only import.
        original = (ROOT / 'Sources/HermesShell/ChatExportController.swift').read_text()
        assert original.startswith('import SwiftUI\n')
        generated.write_text(original.replace('import SwiftUI\n', 'import Foundation\n', 1))
        sources = ['-swift-version', '5', '-parse-as-library',
                   'Sources/HermesShell/AttachmentHistory.swift', 'Sources/HermesShell/ChatCore.swift',
                   'Sources/HermesShell/TranscriptPager.swift', str(generated), 'tests/w3w4/ExportRecovery.swift']
        binary = BUILD / 'export-recovery'
    elif suite == 'races':
        sources = [p for p in sources_for('model') if not p.startswith('tests/model/')]
        sources += ['tests/w3w4/main.swift']
        binary = BUILD / 'races'
    else:
        sources = sources_for(suite)
        binary = BUILD / suite
    result = run(['swiftc', '-warnings-as-errors', *sources, '-o', binary])
    if result:
        return result
    if suite != 'races':
        return run([binary])
    cases = sys.argv[2:] or [
        'approval-background-success', 'approval-background-error',
        'approval-return-replacement', 'approval-return-same', 'stop-failure',
        'stop-background-failure', 'stop-old-completion-new-stop', 'run-recovery-stickiness',
    ]
    outcomes = [(case, run([binary, case])) for case in cases]
    print('RESULTS=' + repr(outcomes), flush=True)
    return int(any(code for _, code in outcomes))


if __name__ == '__main__':
    sys.exit(main())
