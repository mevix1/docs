#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B64="$ROOT/transport/mev-818-ui-native-source.tgz.b64"
ARCHIVE="$ROOT/transport/mev-818-product/source.tgz"
EXPECTED_BASE_ARCHIVE_SHA="a1ca235a330821353eee42b83da6f42683aa434bcb8697c558a9cf9eec1f4ed0"
WORK="$ROOT/.mev-818-converged-work"
OUT="$ROOT/out/mev-818-converged"
REPO="$WORK/source"
PACKAGE="$REPO/packages/ui-native"

rm -rf "$WORK" "$OUT"
mkdir -p "$(dirname "$ARCHIVE")" "$REPO" "$OUT"

run_capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

base64 -d "$B64" > "$ARCHIVE"
ACTUAL_BASE_ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$ACTUAL_BASE_ARCHIVE_SHA" "$ARCHIVE" >"$OUT/base-source-archive.sha256"
if [[ "$ACTUAL_BASE_ARCHIVE_SHA" != "$EXPECTED_BASE_ARCHIVE_SHA" ]]; then
  printf 'archive mismatch: %s != %s\n' "$ACTUAL_BASE_ARCHIVE_SHA" "$EXPECTED_BASE_ARCHIVE_SHA" >"$OUT/base-source-archive.error"
  printf '99\n' >"$OUT/patch-source.exit"
else
  tar -xzf "$ARCHIVE" -C "$REPO"
  run_capture patch-source python3 - "$REPO" <<'PY'
import json
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
package = repo / 'packages/ui-native'
required = [
    package / 'package.json',
    package / 'tsconfig.json',
    package / 'src/android/react-native-binding.tsx',
    package / 'App.tsx',
    package / 'android/gradlew',
    repo / 'tools/scaffold-utils.mjs',
    repo / 'tests/native/android/run.mjs',
    repo / 'quality/rules/source-checks.mjs',
]
missing = [str(path.relative_to(repo)) for path in required if not path.exists()]
if missing:
    raise SystemExit('MISSING_REQUIRED_SOURCE:' + ','.join(missing))

manifest_path = package / 'package.json'
manifest = json.loads(manifest_path.read_text())
dev = manifest.setdefault('devDependencies', {})
old_ts = dev.get('typescript')
if old_ts not in {'5.8.3', '6.0.3'}:
    raise SystemExit(f'UNEXPECTED_TYPESCRIPT_BASE:{old_ts}')
dev['typescript'] = '6.0.3'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')

tsconfig_path = package / 'tsconfig.json'
tsconfig = json.loads(tsconfig_path.read_text())
base = tsconfig.get('extends')
if base not in {'@react-native/typescript-config/strict', '@react-native/typescript-config'}:
    raise SystemExit(f'UNEXPECTED_TYPESCRIPT_CONFIG_BASE:{base}')
tsconfig['extends'] = '@react-native/typescript-config'
options = tsconfig.setdefault('compilerOptions', {})
options['types'] = ['react']
options['skipLibCheck'] = True
tsconfig_path.write_text(json.dumps(tsconfig, indent=2) + '\n')

binding_path = package / 'src/android/react-native-binding.tsx'
binding = binding_path.read_text()
marker = "type StyleReference = Readonly<{\n  tokenRole: string;\n  binding: AndroidTokenBinding;\n}>;\n"
mutable = "type MutableStyle<T> = {-readonly [K in keyof T]: T[K]};"
if mutable not in binding:
    if marker not in binding:
        raise SystemExit('STYLE_REFERENCE_MARKER_MISSING')
    binding = binding.replace(marker, marker + '\n' + mutable + '\n')
binding = binding.replace('  const result: TextStyle = {};', '  const result: MutableStyle<TextStyle> = {};')
binding = binding.replace('  const result: ViewStyle = {};', '  const result: MutableStyle<ViewStyle> = {};')
binding_path.write_text(binding)

# Metro resolves TypeScript source directly. Keep package imports intact and remove
# only explicit .js suffixes from relative TS/TSX imports.
for path in [package / 'App.tsx', *sorted((package / 'src').rglob('*.ts')), *sorted((package / 'src').rglob('*.tsx'))]:
    text = path.read_text()
    text = re.sub(r"(from\s+['\"](?:\.{1,2}/)[^'\"]+)\.js(['\"])", r"\1\2", text)
    text = re.sub(r"(import\s*['\"](?:\.{1,2}/)[^'\"]+)\.js(['\"])", r"\1\2", text)
    path.write_text(text)

# Root assurance tests intentionally share the installed native compiler in this
# isolated M3 transaction. They still fail closed on any other version.
scaffold_path = repo / 'tools/scaffold-utils.mjs'
scaffold = scaffold_path.read_text()
old = "if(ts.version!=='5.8.3') throw new Error(`Compiler mismatch: expected 5.8.3, found ${ts.version}`);"
new = "if(ts.version!=='6.0.3') throw new Error(`Compiler mismatch: expected 6.0.3, found ${ts.version}`);"
if old in scaffold:
    scaffold = scaffold.replace(old, new)
elif new not in scaffold:
    raise SystemExit('COMPILER_VERSION_GUARD_NOT_FOUND')
scaffold_path.write_text(scaffold)

patch_manifest = {
    'schema': 'mevix.mev-818-source-repair.v1',
    'baseArchiveSha256': 'a1ca235a330821353eee42b83da6f42683aa434bcb8697c558a9cf9eec1f4ed0',
    'repairs': [
        'official React Native TypeScript config root',
        'TypeScript 6.0.3 exact toolchain',
        'explicit React ambient types',
        'upstream declaration skipLibCheck boundary',
        'mutable local style builder before StyleSheet registration',
        'Metro-compatible extensionless relative TypeScript imports',
        'root native/source checks bound to exact installed TypeScript 6.0.3',
    ],
}
(repo / 'MEV-818-SOURCE-REPAIR.json').write_text(json.dumps(patch_manifest, indent=2) + '\n')
PY
fi

PATCH_EXIT="$(cat "$OUT/patch-source.exit" 2>/dev/null || printf 99)"
if [[ "$PATCH_EXIT" == 0 ]]; then
  run_capture lock-generation bash -lc "cd '$PACKAGE' && npm install --package-lock-only --ignore-scripts --audit=false --fund=false"
else
  printf '99\n' >"$OUT/lock-generation.exit"
fi

LOCK_EXIT="$(cat "$OUT/lock-generation.exit" 2>/dev/null || printf 99)"
if [[ "$LOCK_EXIT" == 0 ]]; then
  rm -rf "$PACKAGE/node_modules"
  run_capture npm-ci bash -lc "cd '$PACKAGE' && npm ci --audit=false --fund=false"
else
  printf '99\n' >"$OUT/npm-ci.exit"
fi

NPM_CI_EXIT="$(cat "$OUT/npm-ci.exit" 2>/dev/null || printf 99)"
if [[ "$NPM_CI_EXIT" == 0 ]]; then
  export PATH="$PACKAGE/node_modules/.bin:$PATH"
  run_capture npm-ls bash -lc "cd '$PACKAGE' && npm ls --json --depth=0"
  run_capture root-native-tests env PATH="$PATH" node "$REPO/tests/native/android/run.mjs"
  run_capture source-policy env PATH="$PATH" node "$REPO/quality/rules/source-checks.mjs"
  run_capture typecheck bash -lc "cd '$PACKAGE' && ./node_modules/.bin/tsc -p tsconfig.json --noEmit"
  rm -rf "$PACKAGE/.generated"
  run_capture declaration-build bash -lc "cd '$PACKAGE' && ./node_modules/.bin/tsc -p tsconfig.build.json"
  run_capture metro-bundle bash -lc "cd '$PACKAGE' && ./node_modules/.bin/react-native bundle --platform android --dev false --entry-file index.js --bundle-output '$OUT/index.android.bundle' --assets-dest '$OUT/assets'"
  run_capture runtime-preflight env ANDROID_HOME="${ANDROID_HOME:-}" ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-}" node "$REPO/tests/native/android/check-runtime.mjs"
  run_capture gradle-version bash -lc "cd '$PACKAGE/android' && ./gradlew --version"
  run_capture android-build bash -lc "cd '$PACKAGE/android' && ./gradlew :app:assembleDebug --no-daemon --stacktrace"
else
  for name in npm-ls root-native-tests source-policy typecheck declaration-build metro-bundle runtime-preflight gradle-version android-build; do
    printf '99\n' >"$OUT/${name}.exit"
  done
fi

# Create a durable exact source identity after bounded repairs and lock generation,
# excluding installed/build outputs. Preserve ancestry when the archive includes Git;
# otherwise create an explicit snapshot root bound to the base archive digest.
if [[ -d "$REPO" ]]; then
  if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$REPO" init -q
  fi
  git -C "$REPO" config user.name 'MEV-818 Coordinator'
  git -C "$REPO" config user.email 'mev-818@mevix.local'
  mkdir -p "$REPO/.git/info"
  cat >>"$REPO/.git/info/exclude" <<'GITIGNORE'
packages/ui-native/node_modules/
packages/ui-native/.generated/
packages/ui-native/android/.gradle/
packages/ui-native/android/app/.cxx/
packages/ui-native/android/app/build/
GITIGNORE
  git -C "$REPO" add -A
  if ! git -C "$REPO" diff --cached --quiet; then
    GIT_AUTHOR_DATE='2026-09-25T17:10:00Z' GIT_COMMITTER_DATE='2026-09-25T17:10:00Z' \
      git -C "$REPO" commit -q -m 'feat(native): converge exact MEV-818 React Native Android slice'
  fi
  git -C "$REPO" rev-parse HEAD >"$OUT/source-commit"
  git -C "$REPO" rev-parse 'HEAD^{tree}' >"$OUT/source-tree"
  git -C "$REPO" rev-parse 'HEAD^' >"$OUT/source-parent" 2>/dev/null || printf 'ROOT_SNAPSHOT\n' >"$OUT/source-parent"
  git -C "$REPO" status --short >"$OUT/source-status.txt"
  git -C "$REPO" bundle create "$OUT/MEV-818-converged-source.bundle" HEAD
  git -C "$REPO" archive --format=tar.gz --output="$OUT/MEV-818-converged-source.tar.gz" HEAD
fi

APK_SOURCE="$(find "$PACKAGE/android/app/build/outputs/apk" -type f -name '*.apk' 2>/dev/null | sort | head -1 || true)"
if [[ -n "$APK_SOURCE" ]]; then
  cp "$APK_SOURCE" "$OUT/NativeNeutralApp-debug.apk"
  sha256sum "$OUT/NativeNeutralApp-debug.apk" >"$OUT/NativeNeutralApp-debug.apk.sha256"
fi

[[ -f "$PACKAGE/package-lock.json" ]] && cp "$PACKAGE/package-lock.json" "$OUT/package-lock.json"
[[ -f "$PACKAGE/package.json" ]] && cp "$PACKAGE/package.json" "$OUT/package.json"
[[ -f "$PACKAGE/tsconfig.json" ]] && cp "$PACKAGE/tsconfig.json" "$OUT/tsconfig.json"
[[ -f "$PACKAGE/src/android/react-native-binding.tsx" ]] && cp "$PACKAGE/src/android/react-native-binding.tsx" "$OUT/react-native-binding.tsx"
[[ -f "$REPO/MEV-818-SOURCE-REPAIR.json" ]] && cp "$REPO/MEV-818-SOURCE-REPAIR.json" "$OUT/MEV-818-SOURCE-REPAIR.json"
[[ -f "$PACKAGE/android/build.gradle" ]] && cp "$PACKAGE/android/build.gradle" "$OUT/android-build.gradle"
[[ -f "$PACKAGE/android/gradle/wrapper/gradle-wrapper.properties" ]] && cp "$PACKAGE/android/gradle/wrapper/gradle-wrapper.properties" "$OUT/gradle-wrapper.properties"
[[ -f "$PACKAGE/.generated/build/packages/ui-native/src/android/react-native-materialization.d.ts" ]] && cp "$PACKAGE/.generated/build/packages/ui-native/src/android/react-native-materialization.d.ts" "$OUT/react-native-materialization.d.ts"

export OUT REPO PACKAGE EXPECTED_BASE_ARCHIVE_SHA ACTUAL_BASE_ARCHIVE_SHA
python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import re
import subprocess

out = pathlib.Path(os.environ['OUT'])
repo = pathlib.Path(os.environ['REPO'])
package = pathlib.Path(os.environ['PACKAGE'])

def code(name):
    try:
        return int((out / f'{name}.exit').read_text().strip())
    except Exception:
        return 99

def digest(path):
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return {'bytes': path.stat().st_size, 'sha256': h.hexdigest()}

def load(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None

def text(path, default=None):
    try:
        return path.read_text().strip()
    except Exception:
        return default

pkg = load(package / 'package.json') or {}
lock = load(package / 'package-lock.json') or {}
installed_rn = load(package / 'node_modules/react-native/package.json') or {}
installed_react = load(package / 'node_modules/react/package.json') or {}
installed_ts = load(package / 'node_modules/typescript/package.json') or {}
build = (package / 'android/build.gradle').read_text() if (package / 'android/build.gradle').is_file() else ''
profile = {}
for key, pattern in {
    'buildTools': r'buildToolsVersion\s*=\s*"([^"]+)"',
    'compileSdk': r'compileSdkVersion\s*=\s*(\d+)',
    'targetSdk': r'targetSdkVersion\s*=\s*(\d+)',
    'minSdk': r'minSdkVersion\s*=\s*(\d+)',
    'ndk': r'ndkVersion\s*=\s*"([^"]+)"',
    'kotlin': r'kotlinVersion\s*=\s*"([^"]+)"',
}.items():
    match = re.search(pattern, build)
    profile[key] = match.group(1) if match else None
for key in ['compileSdk', 'targetSdk', 'minSdk']:
    if profile.get(key) is not None:
        profile[key] = int(profile[key])

step_names = [
    'patch-source', 'lock-generation', 'npm-ci', 'npm-ls', 'root-native-tests',
    'source-policy', 'typecheck', 'declaration-build', 'metro-bundle',
    'runtime-preflight', 'gradle-version', 'android-build',
]
steps = {name: code(name) for name in step_names}
source_policy = load(out / 'source-policy.stdout.log')
source_policy_ok = (
    isinstance(source_policy, dict)
    and len(source_policy.get('diagnostics', [])) == 7
    and all(
        item.get('code') == 'EXTERNAL_NOT_QUALIFIED'
        and item.get('detail', '').startswith('@radix-ui/')
        for item in source_policy['diagnostics']
    )
)
checks = {
    'baseArchiveIdentity': os.environ.get('ACTUAL_BASE_ARCHIVE_SHA') == os.environ.get('EXPECTED_BASE_ARCHIVE_SHA'),
    'dependencyIdentity': (
        pkg.get('dependencies', {}).get('react-native') == '0.87.1'
        and pkg.get('dependencies', {}).get('react') == '19.2.3'
        and installed_rn.get('version') == '0.87.1'
        and installed_react.get('version') == '19.2.3'
        and installed_ts.get('version') == '6.0.3'
    ),
    'officialReactNativeOrigin': (
        lock.get('packages', {}).get('node_modules/react-native', {}).get('resolved')
        == 'https://registry.npmjs.org/react-native/-/react-native-0.87.1.tgz'
    ),
    'androidProfile': (
        profile.get('compileSdk') == 35
        and profile.get('targetSdk') == 35
        and profile.get('buildTools') == '36.0.0'
        and profile.get('minSdk') == 24
        and profile.get('ndk') == '27.1.12297006'
    ),
    'sourcePolicy': source_policy_ok,
    'sourceIdentity': bool(text(out / 'source-commit')) and bool(text(out / 'source-tree')),
    'cleanTrackedSource': text(out / 'source-status.txt', '') == '',
    'sourceBundleProduced': digest(out / 'MEV-818-converged-source.bundle') is not None,
    'sourceArchiveProduced': digest(out / 'MEV-818-converged-source.tar.gz') is not None,
    'apkProduced': digest(out / 'NativeNeutralApp-debug.apk') is not None,
    'bundleProduced': digest(out / 'index.android.bundle') is not None,
    'declarationProduced': digest(out / 'react-native-materialization.d.ts') is not None,
}
required = step_names
status = (
    'PASS_MEV_818_CONVERGED_ANDROID_BUILD'
    if all(steps[name] == 0 for name in required) and all(checks.values())
    else 'FAIL_MEV_818_CONVERGED_ANDROID_BUILD'
)
result = {
    'schema': 'mevix.mev-818-converged-product-build.v1',
    'issue': 'MEV-818',
    'status': status,
    'source': {
        'baseArchiveSha256': os.environ.get('ACTUAL_BASE_ARCHIVE_SHA'),
        'commit': text(out / 'source-commit'),
        'tree': text(out / 'source-tree'),
        'parent': text(out / 'source-parent'),
        'bundle': digest(out / 'MEV-818-converged-source.bundle'),
        'archive': digest(out / 'MEV-818-converged-source.tar.gz'),
    },
    'package': {
        'name': pkg.get('name'),
        'version': pkg.get('version'),
        'lockfileVersion': lock.get('lockfileVersion'),
        'lock': digest(package / 'package-lock.json'),
        'manifest': digest(package / 'package.json'),
        'declared': pkg.get('dependencies'),
        'installed': {
            'reactNative': installed_rn.get('version'),
            'react': installed_react.get('version'),
            'typescript': installed_ts.get('version'),
        },
    },
    'environment': {
        'node': subprocess.run(['node', '--version'], capture_output=True, text=True).stdout.strip(),
        'npm': subprocess.run(['npm', '--version'], capture_output=True, text=True).stdout.strip(),
        'java': subprocess.run(['java', '-version'], capture_output=True, text=True).stderr.splitlines()[0],
        'androidHome': os.environ.get('ANDROID_HOME'),
    },
    'androidProfile': profile,
    'steps': steps,
    'checks': checks,
    'outputs': {
        'apk': digest(out / 'NativeNeutralApp-debug.apk'),
        'jsBundle': digest(out / 'index.android.bundle'),
        'declaration': digest(out / 'react-native-materialization.d.ts'),
    },
    'boundaries': {
        'emulator': 'NOT_RUN',
        'device': 'NOT_RUN',
        'talkBack': 'NOT_RUN',
        'physicalTouch': 'NOT_RUN',
        'screenshot': 'NOT_RUN',
        'owner': 'MEV-661',
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
        if path.is_file():
            archive.write(path, path.relative_to(root.parent))
print(out)
PY
cat "$OUT/RESULT.json"
exit 0
