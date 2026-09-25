#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$ROOT/.github/scripts/mev-818-terminal-guard-base.sh"
APP="$ROOT/.mev-818-converged-work/candidate/NativeNeutralApp"
OUT="$ROOT/out/mev-818-converged"

# Preserve the terminal guard authored on the current authority. It already
# freezes a packed local package, commits the npm-generated lock, runs fresh
# npm ci, all source/type/Metro/Gradle contours and exact recovery.
bash "$BASE"

run_capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

# react-native's compatibility shim can emit a missing-CLI warning despite the
# exact CLI package being physically installed. Verify the actual runtime inputs
# directly. Metro and Gradle remain the executable product checks.
run_capture terminal-runtime-preflight node - "$APP" "${ANDROID_HOME:-}" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const app = process.argv[2];
const sdk = process.argv[3];
const required = [
  path.join(sdk, 'platforms/android-35'),
  path.join(sdk, 'build-tools/36.0.0'),
  path.join(sdk, 'ndk/27.1.12297006'),
  path.join(app, 'node_modules/react-native/package.json'),
  path.join(app, 'node_modules/@react-native-community/cli/package.json'),
  path.join(app, 'node_modules/@ui-foundation/ui-native/package.json'),
  path.join(app, 'android/gradlew'),
];
for (const item of required) {
  if (!fs.existsSync(item)) throw new Error(`PREFLIGHT_MISSING:${item}`);
}
const rn = JSON.parse(fs.readFileSync(path.join(app, 'node_modules/react-native/package.json'), 'utf8'));
const cli = JSON.parse(fs.readFileSync(path.join(app, 'node_modules/@react-native-community/cli/package.json'), 'utf8'));
const ui = JSON.parse(fs.readFileSync(path.join(app, 'node_modules/@ui-foundation/ui-native/package.json'), 'utf8'));
if (rn.version !== '0.87.1') throw new Error(`PREFLIGHT_RN:${rn.version}`);
if (ui.version !== '0.1.0') throw new Error(`PREFLIGHT_UI_NATIVE:${ui.version}`);
console.log(JSON.stringify({status: 'READY_FOR_ANDROID_RUNTIME_BUILD', reactNative: rn.version, cli: cli.version, uiNative: ui.version, sdk}, null, 2));
NODE

export OUT
python3 - <<'PY'
import hashlib
import json
import os
import pathlib

out = pathlib.Path(os.environ['OUT'])

def code(name):
    try: return int((out / f'{name}.exit').read_text().strip())
    except Exception: return 99

def digest(path):
    if not path.is_file(): return None
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''): h.update(chunk)
    return {'bytes': path.stat().st_size, 'sha256': h.hexdigest()}

result = json.loads((out / 'RESULT.json').read_text())
terminal_steps = [
    'terminal-preparation',
    'terminal-source-identity',
    'terminal-lock-binding',
    'terminal-npm-ci',
    'terminal-dependency-receipt',
    'terminal-source-policy',
    'terminal-native-tests',
    'terminal-library-typecheck',
    'terminal-library-declarations',
    'terminal-app-typecheck',
    'terminal-metro-bundle',
    'terminal-runtime-preflight',
    'terminal-gradle-version',
    'terminal-android-build',
    'terminal-source-recovery',
]
steps = {name: code(name) for name in terminal_steps}
checks = dict(result.get('checks', {}))
checks.update({
    'allTerminalStepsPassed': all(value == 0 for value in steps.values()),
    'sourceRecoveryExact': code('terminal-source-recovery') == 0,
    'metroBundleProduced': digest(out / 'terminal-index.android.bundle') is not None,
    'apkProduced': digest(out / 'NativeNeutralApp-terminal-debug.apk') is not None,
})
result['schema'] = 'mevix.mev-818-terminal-single-source-build.v2'
result['steps'] = steps
result['checks'] = checks
result['status'] = 'PASS_MEV_818_TERMINAL_SINGLE_SOURCE_BUILD' if all(checks.values()) else 'FAIL_MEV_818_TERMINAL_SINGLE_SOURCE_BUILD'
result['runtimePreflight'] = {
    'classification': 'direct-physical-input-check',
    'reactNativeCliShim': 'not used as an availability oracle',
}
(out / 'RESULT.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print(json.dumps(result, indent=2, sort_keys=True))
PY

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
rm -f "$ROOT/out/MEV-818-converged-product-build.zip"
python3 - <<'PY'
import pathlib
import zipfile
root = pathlib.Path('out/mev-818-converged')
out = pathlib.Path('out/MEV-818-converged-product-build.zip')
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(root.rglob('*')):
        if path.is_file(): archive.write(path, path.relative_to(root.parent))
print(out)
PY
cat "$OUT/RESULT.json"
exit 0
