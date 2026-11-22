"""Exercise the actual gate in a disposable tree, never the workspace."""
import importlib.util
from pathlib import Path
import shutil
import tempfile

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_gate', root / 'tests/verify_source.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
with tempfile.TemporaryDirectory(prefix='hermes-sourcegate-') as temp:
    copy = Path(temp) / 'source'
    shutil.copytree(root, copy, ignore=shutil.ignore_patterns(*gate.IGNORED))
    gate.verify(copy)
    cases = [
        ('Package.swift', lambda data: data + b'\n// unreviewed change\n'),
        ('tests/baseline-1.20.2-build64.json', lambda data: data + b'\n'),
        ('tests/baseline-1.19.1-build62.json', lambda data: data + b'\n'),
        ('Sources/HermesShell/LoginSettings.swift',
         lambda data: data.replace('清晰、可靠、顺手。'.encode(), b'', 1)),
        # 版本号必须从门禁自己的常量取：写死某一版的字面量，
        # 下次升版后 replace 匹配不到，文件其实没被改动，门禁照常通过，
        # 这个自检就会误报「门禁接受了篡改」。
        ('Resources/Info.plist', lambda data: data.replace(gate.VERSION.encode(), b'9.99.0')),
    ]
    for name, alter in cases:
        path = copy / name
        old = path.read_bytes()
        path.write_bytes(alter(old))
        try:
            gate.verify(copy)
        except ValueError:
            pass
        else:
            raise AssertionError(f'gate accepted tampering: {name}')
        path.write_bytes(old)
    # README is a pinned source file, so a change to its release title is
    # rejected by the hash check before the dedicated title assertion can run.
    # Disable only that first line of defence in the disposable copy so the
    # regression exercises the actual README semantic check, not the hash gate.
    gate_path = copy / 'tests/verify_source.py'
    original_gate = gate_path.read_text(encoding='utf-8')
    gate_path.write_text(original_gate.replace('if hashes:', 'if False:', 1), encoding='utf-8')
    # Reload the edited disposable module. The already-imported `gate` object
    # still contains the original code and would only exercise the hash gate.
    copy_spec = importlib.util.spec_from_file_location('release_gate_readme', gate_path)
    copy_gate = importlib.util.module_from_spec(copy_spec)
    copy_spec.loader.exec_module(copy_gate)
    readme = copy / 'README.md'
    original_readme = readme.read_bytes()
    readme.write_bytes(original_readme.replace(
        f'# Hermes {gate.VERSION} / build{gate.BUILD}'.encode(),
        b'# Hermes 9.99.0 / build999'))
    try:
        copy_gate.verify(copy)
    except ValueError as error:
        if 'README release mismatch' not in str(error):
            raise
    else:
        raise AssertionError('gate accepted README release tampering')
    readme.write_bytes(original_readme)
    gate_path.write_text(original_gate, encoding='utf-8')
    (copy / 'unregistered.swift').write_text('// not reviewed\n')
    try:
        gate.verify(copy)
    except ValueError:
        pass
    else:
        raise AssertionError('gate accepted unregistered source')
print('SOURCE_GATE_REGRESSION_PASS 8 scenarios')
