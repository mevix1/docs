#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/.mev-818-converged-work"
CANDIDATE="$WORK/candidate"
LIBRARY="$CANDIDATE/library"
LIBPKG="$LIBRARY/packages/ui-native"
APP="$CANDIDATE/NativeNeutralApp"
OUT="$ROOT/out/mev-818-converged"
RECOVERY="$WORK/terminal-recovery"

mkdir -p "$OUT"

run_capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

write_exit() {
  printf '%s\n' "$2" >"$OUT/$1.exit"
}

required_paths=(
  "$CANDIDATE/.git"
  "$APP/package.json"
  "$APP/package-lock.json"
  "$LIBPKG/package.json"
  "$LIBPKG/src/android/index.ts"
  "$APP/mev818-tests/contract.test.ts"
)
missing=()
for path in "${required_paths[@]}"; do
  [[ -e "$path" ]] || missing+=("$path")
done
if ((${#missing[@]})); then
  printf '%s\n' "${missing[@]}" >"$OUT/terminal-prerequisites-missing.txt"
  for name in terminal-source-identity terminal-lock-binding terminal-npm-ci terminal-dependency-receipt terminal-source-policy terminal-native-tests terminal-library-typecheck terminal-library-declarations terminal-app-typecheck terminal-metro-bundle terminal-runtime-preflight terminal-gradle-version terminal-android-build terminal-source-recovery; do
    write_exit "$name" 99
  done
else
  run_capture terminal-source-identity bash -lc "
    set -euo pipefail
    cd '$CANDIDATE'
    git rev-parse HEAD > '$OUT/terminal-source-commit'
    git rev-parse 'HEAD^{tree}' > '$OUT/terminal-source-tree'
    git status --short > '$OUT/terminal-source-status-before.txt'
    test ! -s '$OUT/terminal-source-status-before.txt'
    git ls-files -s > '$OUT/terminal-tracked-index.tsv'
    git ls-files -z | sort -z | xargs -0 sha256sum > '$OUT/terminal-tracked-sha256.txt'
    git fsck --full --strict > '$OUT/terminal-source-fsck.log'
  "

  run_capture terminal-lock-binding python3 - "$CANDIDATE" "$OUT" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
paths = [
    'NativeNeutralApp/package.json',
    'NativeNeutralApp/package-lock.json',
    'library/packages/ui-native/package.json',
    'library/packages/ui-native/MEV-818-LIBRARY-REPAIR.json',
    'MEV-818-CANDIDATE.json',
]

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

rows = []
for rel in paths:
    working = (root / rel).read_bytes()
    committed = subprocess.check_output(['git', '-C', str(root), 'show', f'HEAD:{rel}'])
    if working != committed:
        raise SystemExit(f'COMMITTED_FILE_DRIFT:{rel}')
    rows.append({'path': rel, 'bytes': len(working), 'sha256': sha(working)})

lock = json.loads((root / 'NativeNeutralApp/package-lock.json').read_text())
packages = lock.get('packages', {})
checks = {
    'reactNative': packages.get('node_modules/react-native', {}).get('version') == '0.87.1',
    'react': packages.get('node_modules/react', {}).get('version') == '19.2.3',
    'typescript': packages.get('node_modules/typescript', {}).get('version') == '6.0.3',
    'localLibrary': packages.get('node_modules/@ui-foundation/ui-native', {}).get('link') is True,
}
if not all(checks.values()):
    raise SystemExit('LOCK_DEPENDENCY_IDENTITY:' + json.dumps(checks, sort_keys=True))
receipt = {'schema': 'mevix.mev-818.committed-lock-binding.v1', 'files': rows, 'checks': checks}
(out / 'terminal-lock-binding.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
PY

  rm -rf "$APP/node_modules" "$LIBPKG/node_modules"
  run_capture terminal-npm-ci bash -lc "cd '$APP' && npm ci --ignore-scripts --audit=false --fund=false"

  TERMINAL_CI_EXIT="$(cat "$OUT/terminal-npm-ci.exit" 2>/dev/null || printf 99)"
  if [[ "$TERMINAL_CI_EXIT" == 0 ]]; then
    ln -s "$APP/node_modules" "$LIBPKG/node_modules"

    run_capture terminal-dependency-receipt node - "$APP" "$OUT" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const app = process.argv[2];
const out = process.argv[3];
const lock = JSON.parse(fs.readFileSync(path.join(app, 'package-lock.json'), 'utf8'));
const packages = lock.packages;
const receipt = {
  schema: 'mevix.mev-818.terminal-dependency-receipt.v1',
  reactNative: packages['node_modules/react-native'],
  react: packages['node_modules/react'],
  typescript: packages['node_modules/typescript'],
  uiNative: packages['node_modules/@ui-foundation/ui-native'],
};
if (receipt.reactNative?.version !== '0.87.1') throw new Error(`RN_VERSION:${receipt.reactNative?.version}`);
if (receipt.react?.version !== '19.2.3') throw new Error(`REACT_VERSION:${receipt.react?.version}`);
if (receipt.typescript?.version !== '6.0.3') throw new Error(`TS_VERSION:${receipt.typescript?.version}`);
if (!String(receipt.reactNative?.resolved).includes('registry.npmjs.org/react-native/-/react-native-0.87.1.tgz')) throw new Error(`RN_ORIGIN:${receipt.reactNative?.resolved}`);
if (receipt.uiNative?.link !== true) throw new Error('LOCAL_UI_NATIVE_NOT_LINKED');
fs.writeFileSync(path.join(out, 'terminal-dependency-receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
console.log(JSON.stringify(receipt, null, 2));
NODE

    run_capture terminal-source-policy python3 - "$CANDIDATE" "$OUT" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
lib = root / 'library/packages/ui-native'
app = root / 'NativeNeutralApp'
source_files = sorted([*lib.glob('src/**/*.ts'), *lib.glob('src/**/*.tsx'), app / 'App.tsx', app / 'MEV818Plan.ts'])
forbidden = {
    'CSS_VARIABLE': re.compile(r'var\(--'),
    'DOM_DOCUMENT': re.compile(r'\bdocument\.'),
    'DOM_WINDOW': re.compile(r'\bwindow\.'),
    'RN_WEB': re.compile(r'react-native-web'),
    'UNSUPPORTED_ARIA_INVALID': re.compile(r'aria-invalid'),
    'RELATIVE_JS_SUFFIX': re.compile(r"(?:from\s+|import\s*)['\"](?:\.{1,2}/)[^'\"]+\.js['\"]"),
}
diagnostics = []
for path in source_files:
    if not path.is_file():
        diagnostics.append({'code': 'MISSING_SOURCE', 'path': str(path.relative_to(root))})
        continue
    text = path.read_text()
    for code, pattern in forbidden.items():
        for match in pattern.finditer(text):
            diagnostics.append({'code': code, 'path': str(path.relative_to(root)), 'offset': match.start()})
required_exports = [
    lib / 'src/android/index.ts',
    lib / 'src/android/react-native.ts',
    lib / 'src/android/generated-token-adapter.ts',
    lib / 'src/android/NativeNeutralSlice.ts',
]
for path in required_exports:
    if not path.is_file(): diagnostics.append({'code': 'MISSING_REQUIRED_EXPORT_SOURCE', 'path': str(path.relative_to(root))})
receipt = {
    'schema': 'mevix.mev-818.terminal-native-source-policy.v1',
    'filesScanned': len(source_files),
    'diagnostics': diagnostics,
    'status': 'PASS' if not diagnostics else 'FAIL',
}
(out / 'terminal-source-policy.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
print(json.dumps(receipt, indent=2, sort_keys=True))
if diagnostics: raise SystemExit(1)
PY

    run_capture terminal-native-tests bash -lc "cd '$APP' && ./node_modules/.bin/tsx mev818-tests/contract.test.ts"
    run_capture terminal-library-typecheck bash -lc "cd '$LIBPKG' && '$APP/node_modules/.bin/tsc' -p tsconfig.json --noEmit"
    run_capture terminal-library-declarations bash -lc "cd '$LIBPKG' && rm -rf dist && '$APP/node_modules/.bin/tsc' -p tsconfig.json"
    run_capture terminal-app-typecheck bash -lc "cd '$APP' && ./node_modules/.bin/tsc --noEmit"
    rm -rf "$OUT/terminal-assets" "$OUT/terminal-index.android.bundle"
    run_capture terminal-metro-bundle bash -lc "cd '$APP' && ./node_modules/.bin/react-native bundle --platform android --dev false --entry-file index.js --bundle-output '$OUT/terminal-index.android.bundle' --assets-dest '$OUT/terminal-assets'"
    run_capture terminal-runtime-preflight bash -lc "test -d '${ANDROID_HOME:-}/platforms/android-35' && test -d '${ANDROID_HOME:-}/build-tools/36.0.0' && test -d '${ANDROID_HOME:-}/ndk/27.1.12297006' && cd '$APP' && ./node_modules/.bin/react-native config >/dev/null"
    run_capture terminal-gradle-version bash -lc "cd '$APP/android' && ./gradlew --version"
    run_capture terminal-android-build bash -lc "cd '$APP/android' && ./gradlew :app:assembleDebug --no-daemon --stacktrace"
  else
    for name in terminal-dependency-receipt terminal-source-policy terminal-native-tests terminal-library-typecheck terminal-library-declarations terminal-app-typecheck terminal-metro-bundle terminal-runtime-preflight terminal-gradle-version terminal-android-build; do
      write_exit "$name" 99
    done
  fi

  TERMINAL_APK="$(find "$APP/android/app/build/outputs/apk" -type f -name '*.apk' 2>/dev/null | sort | head -1 || true)"
  if [[ -n "$TERMINAL_APK" ]]; then
    cp "$TERMINAL_APK" "$OUT/NativeNeutralApp-terminal-debug.apk"
    sha256sum "$OUT/NativeNeutralApp-terminal-debug.apk" >"$OUT/NativeNeutralApp-terminal-debug.apk.sha256"
    unzip -l "$OUT/NativeNeutralApp-terminal-debug.apk" >"$OUT/NativeNeutralApp-terminal-debug.apk.entries.txt"
  fi

  git -C "$CANDIDATE" status --short >"$OUT/terminal-source-status-after.txt"
  rm -rf "$RECOVERY"
  mkdir -p "$RECOVERY"
  git -C "$CANDIDATE" bundle create "$OUT/MEV-818-terminal-source.bundle" HEAD
  git -C "$CANDIDATE" archive --format=tar.gz --output="$OUT/MEV-818-terminal-source.tar.gz" HEAD
  run_capture terminal-source-recovery bash -lc "
    set -euo pipefail
    git clone -q '$OUT/MEV-818-terminal-source.bundle' '$RECOVERY/repo'
    test \"\$(git -C '$RECOVERY/repo' rev-parse HEAD)\" = \"\$(cat '$OUT/terminal-source-commit')\"
    test \"\$(git -C '$RECOVERY/repo' rev-parse 'HEAD^{tree}')\" = \"\$(cat '$OUT/terminal-source-tree')\"
    git -C '$RECOVERY/repo' fsck --full --strict
    test -z \"\$(git -C '$RECOVERY/repo' status --short)\"
    git -C '$RECOVERY/repo' ls-files -z | sort -z | xargs -0 sha256sum > '$OUT/terminal-recovered-tracked-sha256.txt'
    cmp '$OUT/terminal-tracked-sha256.txt' '$OUT/terminal-recovered-tracked-sha256.txt'
  "
fi

export OUT APP LIBPKG CANDIDATE
python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess

out = pathlib.Path(os.environ['OUT'])
app = pathlib.Path(os.environ['APP'])
lib = pathlib.Path(os.environ['LIBPKG'])
candidate = pathlib.Path(os.environ['CANDIDATE'])

def code(name):
    try: return int((out / f'{name}.exit').read_text().strip())
    except Exception: return 99

def digest(path):
    if not path.is_file(): return None
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''): h.update(chunk)
    return {'bytes': path.stat().st_size, 'sha256': h.hexdigest()}

def text(path, default=None):
    try: return path.read_text().strip()
    except Exception: return default

def load(path):
    try: return json.loads(path.read_text())
    except Exception: return None

base = load(out / 'RESULT.json') or {}
steps = {name: code(name) for name in [
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
]}
source_commit = text(out / 'terminal-source-commit')
source_tree = text(out / 'terminal-source-tree')
status_before = text(out / 'terminal-source-status-before.txt', '')
status_after = text(out / 'terminal-source-status-after.txt', '')
policy = load(out / 'terminal-source-policy.json') or {}
dependency = load(out / 'terminal-dependency-receipt.json') or {}
checks = {
    'allTerminalStepsPassed': all(value == 0 for value in steps.values()),
    'sourceIdentityDerived': bool(source_commit) and bool(source_tree),
    'sourceCleanBefore': status_before == '',
    'sourceCleanAfter': status_after == '',
    'committedLockBound': code('terminal-lock-binding') == 0,
    'freshNpmCiAfterCommit': code('terminal-npm-ci') == 0,
    'sourcePolicyClean': policy.get('status') == 'PASS' and policy.get('diagnostics') == [],
    'dependencyIdentity': dependency.get('reactNative', {}).get('version') == '0.87.1' and dependency.get('react', {}).get('version') == '19.2.3' and dependency.get('typescript', {}).get('version') == '6.0.3',
    'sourceRecoveryExact': code('terminal-source-recovery') == 0,
    'sourceBundleProduced': digest(out / 'MEV-818-terminal-source.bundle') is not None,
    'sourceArchiveProduced': digest(out / 'MEV-818-terminal-source.tar.gz') is not None,
    'metroBundleProduced': digest(out / 'terminal-index.android.bundle') is not None,
    'apkProduced': digest(out / 'NativeNeutralApp-terminal-debug.apk') is not None,
}
status = 'PASS_MEV_818_TERMINAL_SINGLE_SOURCE_BUILD' if all(checks.values()) else 'FAIL_MEV_818_TERMINAL_SINGLE_SOURCE_BUILD'
result = {
    'schema': 'mevix.mev-818-terminal-single-source-build.v1',
    'issue': 'MEV-818',
    'status': status,
    'preparation': {
        'baseResultStatus': base.get('status'),
        'lockGeneration': 'npm install before candidate freeze',
        'qualification': 'fresh npm ci after committed candidate freeze',
    },
    'source': {
        'commit': source_commit,
        'tree': source_tree,
        'parent': 'ROOT_SNAPSHOT',
        'bundle': digest(out / 'MEV-818-terminal-source.bundle'),
        'archive': digest(out / 'MEV-818-terminal-source.tar.gz'),
        'trackedManifest': digest(out / 'terminal-tracked-sha256.txt'),
    },
    'package': {
        'appManifest': digest(app / 'package.json'),
        'appLock': digest(app / 'package-lock.json'),
        'libraryManifest': digest(lib / 'package.json'),
        'dependencyReceipt': dependency,
    },
    'steps': steps,
    'checks': checks,
    'outputs': {
        'apk': digest(out / 'NativeNeutralApp-terminal-debug.apk'),
        'jsBundle': digest(out / 'terminal-index.android.bundle'),
    },
    'boundaries': {
        'emulator': 'NOT_RUN',
        'device': 'NOT_RUN',
        'talkBack': 'NOT_RUN',
        'physicalTouch': 'NOT_RUN',
        'runtimeOwner': 'MEV-661',
    },
}
(out / 'RESULT.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print(json.dumps(result, indent=2, sort_keys=True))
PY

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
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
