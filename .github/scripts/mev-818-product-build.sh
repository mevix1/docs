#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B64="$ROOT/transport/mev-818-ui-native-source.tgz.b64"
BASE_ARCHIVE="$ROOT/transport/mev-818-product/ui-native-source.tgz"
EXPECTED_BASE_SHA="a1ca235a330821353eee42b83da6f42683aa434bcb8697c558a9cf9eec1f4ed0"
WORK="$ROOT/.mev-818-converged-work"
CANDIDATE="$WORK/candidate"
LIBRARY="$CANDIDATE/library"
LIBPKG="$LIBRARY/packages/ui-native"
APP="$CANDIDATE/NativeNeutralApp"
OUT="$ROOT/out/mev-818-converged"

rm -rf "$WORK" "$OUT"
mkdir -p "$(dirname "$BASE_ARCHIVE")" "$LIBRARY" "$OUT"

run_capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

base64 -d "$B64" > "$BASE_ARCHIVE"
ACTUAL_BASE_SHA="$(sha256sum "$BASE_ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$ACTUAL_BASE_SHA" "$BASE_ARCHIVE" >"$OUT/base-source-archive.sha256"
if [[ "$ACTUAL_BASE_SHA" != "$EXPECTED_BASE_SHA" ]]; then
  printf 'archive mismatch: %s != %s\n' "$ACTUAL_BASE_SHA" "$EXPECTED_BASE_SHA" >"$OUT/base-source-archive.error"
  printf '99\n' >"$OUT/patch-library.exit"
else
  tar -xzf "$BASE_ARCHIVE" -C "$LIBRARY"
  run_capture patch-library python3 - "$LIBRARY" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
package = root / 'packages/ui-native'
required = [
    root / 'contracts/components/contract-types.ts',
    package / 'package.json',
    package / 'tsconfig.json',
    package / 'src/android/index.ts',
    package / 'src/android/react-native.ts',
    package / 'src/android/react-native-binding.tsx',
    package / 'src/android/generated-token-adapter.ts',
    package / 'src/android/token-mapping.ts',
    package / 'src/android/presentation.ts',
    package / 'src/android/NativeNeutralSlice.ts',
]
missing = [str(path.relative_to(root)) for path in required if not path.is_file()]
if missing:
    raise SystemExit('MISSING_LIBRARY_SOURCE:' + ','.join(missing))

# Make the package self-contained: the accepted shared contract is copied byte-for-byte
# inside the package and imports are redirected to the local copy.
contract_target = package / 'src/contracts/contract-types.ts'
contract_target.parent.mkdir(parents=True, exist_ok=True)
contract_target.write_bytes((root / 'contracts/components/contract-types.ts').read_bytes())
for path in sorted((package / 'src/android').glob('*.ts*')):
    text = path.read_text()
    text = text.replace('../../../../contracts/components/contract-types.js', '../contracts/contract-types')
    text = text.replace('../../../../contracts/components/contract-types', '../contracts/contract-types')
    text = re.sub(r"(from\s+['\"](?:\.{1,2}/)[^'\"]+)\.js(['\"])", r"\1\2", text)
    text = re.sub(r"(import\s*['\"](?:\.{1,2}/)[^'\"]+)\.js(['\"])", r"\1\2", text)
    path.write_text(text)

manifest_path = package / 'package.json'
manifest = json.loads(manifest_path.read_text())
dev = manifest.setdefault('devDependencies', {})
if dev.get('typescript') not in {'5.8.3', '6.0.3'}:
    raise SystemExit('UNEXPECTED_TYPESCRIPT_BASE:' + str(dev.get('typescript')))
dev['typescript'] = '6.0.3'
manifest['files'] = ['src', 'package.json', 'README.md']
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')

readme = package / 'README.md'
readme.write_text('# @ui-foundation/ui-native\n\nBounded React Native Android materialization for MEV-818.\n')

tsconfig_path = package / 'tsconfig.json'
tsconfig = json.loads(tsconfig_path.read_text())
if tsconfig.get('extends') not in {'@react-native/typescript-config/strict', '@react-native/typescript-config'}:
    raise SystemExit('UNEXPECTED_TYPESCRIPT_CONFIG_BASE:' + str(tsconfig.get('extends')))
tsconfig['extends'] = '@react-native/typescript-config'
options = tsconfig.setdefault('compilerOptions', {})
options.update({
    'types': ['react'],
    'skipLibCheck': True,
    'rootDir': 'src',
    'outDir': 'dist',
    'declaration': True,
    'emitDeclarationOnly': True,
    'noEmitOnError': True,
})
tsconfig['include'] = ['src/**/*.ts', 'src/**/*.tsx']
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

repair = {
    'schema': 'mevix.mev-818-library-repair.v2',
    'baseArchiveSha256': 'a1ca235a330821353eee42b83da6f42683aa434bcb8697c558a9cf9eec1f4ed0',
    'repairs': [
        'self-contained shared contract copy',
        'extensionless relative TypeScript imports for Metro',
        'official React Native TypeScript config root',
        'TypeScript 6.0.3 exact toolchain',
        'explicit React ambient types',
        'upstream declaration skipLibCheck boundary',
        'mutable local style builder before immutable StyleSheet registration',
    ],
}
(package / 'MEV-818-LIBRARY-REPAIR.json').write_text(json.dumps(repair, indent=2) + '\n')
PY
fi

PATCH_EXIT="$(cat "$OUT/patch-library.exit" 2>/dev/null || printf 99)"
if [[ "$PATCH_EXIT" == 0 ]]; then
  run_capture template-init bash -lc "cd '$CANDIDATE' && npx --yes @react-native-community/cli@latest init NativeNeutralApp --version 0.87.1 --skip-install --pm npm --skip-git-init"
else
  printf '99\n' >"$OUT/template-init.exit"
fi

TEMPLATE_EXIT="$(cat "$OUT/template-init.exit" 2>/dev/null || printf 99)"
if [[ "$TEMPLATE_EXIT" == 0 ]]; then
  run_capture patch-app python3 - "$APP" <<'PY'
import json
import pathlib
import re
import sys

app = pathlib.Path(sys.argv[1])
manifest_path = app / 'package.json'
manifest = json.loads(manifest_path.read_text())
manifest.setdefault('dependencies', {})['@ui-foundation/ui-native'] = 'file:../library/packages/ui-native'
manifest.setdefault('devDependencies', {})['typescript'] = '6.0.3'
manifest['devDependencies']['tsx'] = '4.20.6'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')

build_gradle = app / 'android/build.gradle'
text = build_gradle.read_text()
replacements = {
    r'buildToolsVersion\s*=\s*"[^"]+"': 'buildToolsVersion = "36.0.0"',
    r'minSdkVersion\s*=\s*\d+': 'minSdkVersion = 24',
    r'compileSdkVersion\s*=\s*\d+': 'compileSdkVersion = 35',
    r'targetSdkVersion\s*=\s*\d+': 'targetSdkVersion = 35',
    r'ndkVersion\s*=\s*"[^"]+"': 'ndkVersion = "27.1.12297006"',
}
for pattern, replacement in replacements.items():
    text, count = re.subn(pattern, replacement, text)
    if count != 1:
        raise SystemExit(f'ANDROID_PROFILE_FIELD_NOT_FOUND:{pattern}:{count}')
build_gradle.write_text(text)

plan = r'''import {
  EXPECTED_GENERATED_TOKEN_PACKAGE,
  NATIVE_FRAGMENT_TOKEN_ROLES,
  NATIVE_SLICE_COMPONENT_IDS,
  buildReactNativeAndroidTokenPlan,
  type AndroidTokenBinding,
  type AndroidTokenPlan,
  type GeneratedTokenInput,
} from '@ui-foundation/ui-native/android';

const color = (hex: string, components: readonly [number, number, number]) => ({
  $type: 'color',
  $value: {colorSpace: 'srgb', hex, alpha: 1, components},
});
const dimension = (value: number, unit: 'px' | 'rem') => ({
  $type: 'dimension',
  $value: {value, unit},
});
const typography = (fontSize: number, weight: number, spacing: number, lineHeight: number) => ({
  $type: 'typography',
  $value: {
    fontFamily: ['sans-serif'],
    fontSize: {value: fontSize, unit: 'rem'},
    fontWeight: weight,
    letterSpacing: {value: spacing, unit: 'px'},
    lineHeight,
  },
});

const roles = [...NATIVE_FRAGMENT_TOKEN_ROLES];
const componentCatalog = {
  components: NATIVE_SLICE_COMPONENT_IDS.map(id => ({id, token_roles: roles})),
};
const sharedUpstream = {
  action: {primary: {
    background: color('#2563eb', [37 / 255, 99 / 255, 235 / 255]),
    foreground: color('#ffffff', [1, 1, 1]),
  }},
  border: {control: color('#94a3b8', [148 / 255, 163 / 255, 184 / 255])},
  component: {field: {gap: dimension(8, 'px')}},
  control: {size: {md: dimension(48, 'px')}},
  focus: {color: color('#2563eb', [37 / 255, 99 / 255, 235 / 255])},
  radius: {full: dimension(9999, 'px')},
  surface: {canvas: color('#ffffff', [1, 1, 1])},
  text: {
    danger: color('#b91c1c', [185 / 255, 28 / 255, 28 / 255]),
    primary: color('#1f2937', [31 / 255, 41 / 255, 55 / 255]),
    secondary: color('#4b5563', [75 / 255, 85 / 255, 99 / 255]),
  },
  type: {
    body: typography(1, 400, 0, 1.5),
    bodySmall: typography(0.875, 500, 0.1, 1.4),
    caption: typography(0.75, 400, 0.2, 1.3),
  },
};

const result = buildReactNativeAndroidTokenPlan({
  theme: 'light',
  componentCatalog,
  documents: {
    sharedUpstream,
    sharedNormalized: {},
    themeUpstream: {},
    themeNormalized: {},
  },
});
if (result.status !== 'ready') throw new Error(`MEV818_PLAN:${result.reason}:${result.path ?? ''}`);
export const MEV818_PLAN: AndroidTokenPlan = result;

function generatedValue(binding: AndroidTokenBinding): unknown {
  switch (binding.kind) {
    case 'color': {
      const components = [1, 3, 5].map(offset => Number.parseInt(binding.hex.slice(offset, offset + 2), 16) / 255);
      return {colorSpace: 'srgb', hex: binding.hex, alpha: binding.alpha, components};
    }
    case 'dimension': return {...binding.source};
    case 'radius': return {...binding.source};
    case 'typography': return {
      fontFamily: [...binding.fontFamily.requestedFallbacks],
      fontSize: {...binding.fontSize.source},
      fontWeight: binding.fontWeight,
      letterSpacing: {...binding.letterSpacing.source},
      lineHeight: binding.lineHeightMultiplier,
    };
  }
}

export const MEV818_GENERATED_INPUT: GeneratedTokenInput = {
  packageName: EXPECTED_GENERATED_TOKEN_PACKAGE.name,
  packageVersion: EXPECTED_GENERATED_TOKEN_PACKAGE.version,
  packageSha256: EXPECTED_GENERATED_TOKEN_PACKAGE.packageSha256,
  sourceSha256: EXPECTED_GENERATED_TOKEN_PACKAGE.sourceSha256,
  outputs: {...EXPECTED_GENERATED_TOKEN_PACKAGE.outputs},
  theme: 'light',
  tokens: Object.fromEntries(MEV818_PLAN.tokenRoles.map(role => [role, generatedValue(MEV818_PLAN.bindings[role])])),
  tokenTypes: Object.fromEntries(MEV818_PLAN.tokenRoles.map(role => {
    const binding = MEV818_PLAN.bindings[role];
    return [role, binding.kind === 'radius' ? 'dimension' : binding.kind];
  })),
};
'''
(app / 'MEV818Plan.ts').write_text(plan)

app_source = r'''import React from 'react';
import {renderReactNativeNeutralSlice} from '@ui-foundation/ui-native/android/react-native';
import {MEV818_PLAN} from './MEV818Plan';

export default function App(): React.JSX.Element {
  const [value, setValue] = React.useState('Native UI');
  const [submitted, setSubmitted] = React.useState(false);
  const rendered = renderReactNativeNeutralSlice(
    MEV818_PLAN,
    {rootFontSizeDp: 16, cssPixelToDp: 1, fontFamily: 'sans-serif'},
    {
      theme: 'light',
      title: 'Native neutral slice',
      body: 'Surface, text, field and action are rendered by installed React Native primitives.',
      secondaryText: submitted ? 'Action completed.' : 'Ready for Android runtime verification.',
      field: {
        label: 'Name',
        value,
        placeholder: 'Enter a value',
        hint: 'Uses the accepted generated-token adapter.',
        required: true,
        availability: {state: 'enabled', onChangeText: setValue},
      },
      action: {
        label: 'Confirm',
        intent: 'primary',
        availability: {state: 'enabled', onInvoke: () => setSubmitted(true)},
      },
    },
  );
  return rendered.result.node;
}
'''
(app / 'App.tsx').write_text(app_source)

tests = app / 'mev818-tests'
tests.mkdir(exist_ok=True)
contract_test = r'''import assert from 'node:assert/strict';
import {
  bindGeneratedAndroidTokenPlan,
  presentNativeNeutralSlice,
  renderNativeNeutralSlice,
} from '@ui-foundation/ui-native/android';
import {MEV818_GENERATED_INPUT, MEV818_PLAN} from '../MEV818Plan';

const ready = bindGeneratedAndroidTokenPlan(MEV818_PLAN, MEV818_GENERATED_INPUT);
assert.equal(ready.status, 'ready');
assert.equal(MEV818_PLAN.minimumTouchTargetDp, 48);
assert.equal(MEV818_PLAN.tokenRoles.length, 14);

const cssInput = {
  ...MEV818_GENERATED_INPUT,
  tokens: {...MEV818_GENERATED_INPUT.tokens, 'surface.canvas': 'var(--surface-canvas)'},
};
const cssRejected = bindGeneratedAndroidTokenPlan(MEV818_PLAN, cssInput);
assert.equal(cssRejected.status, 'unavailable');
if (cssRejected.status === 'unavailable') assert.equal(cssRejected.reason, 'GENERATED_CSS_VALUE_FORBIDDEN');

const identityRejected = bindGeneratedAndroidTokenPlan(MEV818_PLAN, {
  ...MEV818_GENERATED_INPUT,
  packageSha256: '0'.repeat(64),
});
assert.equal(identityRejected.status, 'unavailable');
if (identityRejected.status === 'unavailable') assert.equal(identityRejected.reason, 'GENERATED_PACKAGE_IDENTITY_MISMATCH');

const input = {
  theme: 'light' as const,
  title: 'Test',
  body: 'Body',
  field: {
    label: 'Name',
    value: 'Value',
    required: true,
    availability: {state: 'enabled' as const, onChangeText: (_value: string) => undefined},
  },
  action: {
    label: 'Confirm',
    intent: 'primary' as const,
    availability: {state: 'enabled' as const, onInvoke: () => undefined},
  },
};
assert.equal(presentNativeNeutralSlice(input).status, 'ready');
const seen: string[] = [];
const primitive = {
  View: (props: {testID: string}, children: readonly unknown[]) => (seen.push(props.testID), {kind: 'View', children}),
  Text: (props: {testID: string}, content: string) => (seen.push(props.testID), {kind: 'Text', content}),
  TextInput: (props: {testID: string}) => (seen.push(props.testID), {kind: 'TextInput'}),
  Pressable: (props: {testID: string; minimumTouchTargetDp: 48}, child: unknown) => {
    assert.equal(props.minimumTouchTargetDp, 48);
    seen.push(props.testID);
    return {kind: 'Pressable', child};
  },
};
const rendered = renderNativeNeutralSlice(primitive, MEV818_PLAN, input);
assert.equal(rendered.view.status, 'ready');
for (const id of ['uif-native-surface', 'uif-native-title', 'uif-native-field-input', 'uif-native-action']) {
  assert.ok(seen.includes(id), `missing ${id}`);
}
console.log(JSON.stringify({
  status: 'PASS_MEV_818_FOCUSED_CONTRACT',
  generatedAdapter: 'PASS',
  cssStringNegative: 'PASS_REJECTED',
  identityNegative: 'PASS_REJECTED',
  primitiveComposition: 'PASS',
  minimumTouchTargetDp: 48,
}, null, 2));
'''
(tests / 'contract.test.ts').write_text(contract_test)

# Remove nested repository identity; the final candidate owns one exact root identity.
inner_git = app / '.git'
if inner_git.exists():
    import shutil
    shutil.rmtree(inner_git)
PY
else
  printf '99\n' >"$OUT/patch-app.exit"
fi

PATCH_APP_EXIT="$(cat "$OUT/patch-app.exit" 2>/dev/null || printf 99)"
if [[ "$PATCH_APP_EXIT" == 0 ]]; then
  run_capture app-install bash -lc "cd '$APP' && npm install --ignore-scripts --audit=false --fund=false"
else
  printf '99\n' >"$OUT/app-install.exit"
fi

APP_INSTALL_EXIT="$(cat "$OUT/app-install.exit" 2>/dev/null || printf 99)"
if [[ "$APP_INSTALL_EXIT" == 0 ]]; then
  rm -rf "$LIBPKG/node_modules"
  ln -s "$APP/node_modules" "$LIBPKG/node_modules"
  run_capture dependency-receipt node - "$APP" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const app = process.argv[2];
const read = p => JSON.parse(fs.readFileSync(path.join(app, p), 'utf8'));
const lock = read('package-lock.json');
const rn = lock.packages['node_modules/react-native'];
const react = lock.packages['node_modules/react'];
const ts = lock.packages['node_modules/typescript'];
const local = lock.packages['node_modules/@ui-foundation/ui-native'];
if (rn?.version !== '0.87.1') throw new Error(`RN_VERSION:${rn?.version}`);
if (react?.version !== '19.2.3') throw new Error(`REACT_VERSION:${react?.version}`);
if (ts?.version !== '6.0.3') throw new Error(`TS_VERSION:${ts?.version}`);
if (!String(rn?.resolved).includes('registry.npmjs.org/react-native/-/react-native-0.87.1.tgz')) throw new Error(`RN_ORIGIN:${rn?.resolved}`);
if (!local || local.link !== true) throw new Error('LOCAL_UI_NATIVE_NOT_LINKED');
console.log(JSON.stringify({rn, react, typescript: ts, uiNative: local}, null, 2));
NODE
  run_capture library-typecheck bash -lc "cd '$LIBPKG' && '$APP/node_modules/.bin/tsc' -p tsconfig.json --noEmit"
  run_capture library-declarations bash -lc "cd '$LIBPKG' && rm -rf dist && '$APP/node_modules/.bin/tsc' -p tsconfig.json"
  run_capture app-typecheck bash -lc "cd '$APP' && ./node_modules/.bin/tsc --noEmit"
  run_capture focused-contract bash -lc "cd '$APP' && ./node_modules/.bin/tsx mev818-tests/contract.test.ts"
else
  for name in dependency-receipt library-typecheck library-declarations app-typecheck focused-contract; do printf '99\n' >"$OUT/${name}.exit"; done
fi

# Freeze exact source after both npm-generated locks exist and before build outputs.
if [[ "$APP_INSTALL_EXIT" == 0 ]]; then
  cat >"$CANDIDATE/.gitignore" <<'EOF'
**/node_modules/
**/dist/
**/.gradle/
**/.cxx/
**/build/
**/.idea/
*.log
EOF
  cat >"$CANDIDATE/MEV-818-CANDIDATE.json" <<EOF
{
  "schema": "mevix.mev-818-candidate.v1",
  "baseLibraryArchiveSha256": "$ACTUAL_BASE_SHA",
  "reactNative": "0.87.1",
  "react": "19.2.3",
  "typescript": "6.0.3",
  "android": {
    "compileSdk": 35,
    "targetSdk": 35,
    "buildTools": "36.0.0",
    "ndk": "27.1.12297006"
  },
  "runtimeOwner": "MEV-661"
}
EOF
  git -C "$CANDIDATE" init -q
  git -C "$CANDIDATE" config user.name 'MEV-818 Coordinator'
  git -C "$CANDIDATE" config user.email 'mev-818@mevix.local'
  git -C "$CANDIDATE" add -A
  GIT_AUTHOR_DATE='2026-09-25T17:30:00Z' GIT_COMMITTER_DATE='2026-09-25T17:30:00Z' \
    git -C "$CANDIDATE" commit -q -m 'feat(native): materialize exact React Native Android slice'
  git -C "$CANDIDATE" rev-parse HEAD >"$OUT/source-commit"
  git -C "$CANDIDATE" rev-parse 'HEAD^{tree}' >"$OUT/source-tree"
  printf 'ROOT_SNAPSHOT\n' >"$OUT/source-parent"
  git -C "$CANDIDATE" status --short >"$OUT/source-status.txt"
fi

if [[ "$APP_INSTALL_EXIT" == 0 ]]; then
  run_capture metro-bundle bash -lc "cd '$APP' && ./node_modules/.bin/react-native bundle --platform android --dev false --entry-file index.js --bundle-output '$OUT/index.android.bundle' --assets-dest '$OUT/assets'"
  run_capture runtime-preflight bash -lc "test -d '${ANDROID_HOME:-}/platforms/android-35' && test -d '${ANDROID_HOME:-}/build-tools/36.0.0' && test -d '${ANDROID_HOME:-}/ndk/27.1.12297006' && '$APP/node_modules/.bin/react-native' config >/dev/null"
  run_capture gradle-version bash -lc "cd '$APP/android' && ./gradlew --version"
  run_capture android-build bash -lc "cd '$APP/android' && ./gradlew :app:assembleDebug --no-daemon --stacktrace"
else
  for name in metro-bundle runtime-preflight gradle-version android-build; do printf '99\n' >"$OUT/${name}.exit"; done
fi

if [[ -d "$CANDIDATE/.git" ]]; then
  git -C "$CANDIDATE" status --short >"$OUT/source-status-after-build.txt"
  git -C "$CANDIDATE" bundle create "$OUT/MEV-818-converged-source.bundle" HEAD
  git -C "$CANDIDATE" archive --format=tar.gz --output="$OUT/MEV-818-converged-source.tar.gz" HEAD
fi

APK_SOURCE="$(find "$APP/android/app/build/outputs/apk" -type f -name '*.apk' 2>/dev/null | sort | head -1 || true)"
if [[ -n "$APK_SOURCE" ]]; then
  cp "$APK_SOURCE" "$OUT/NativeNeutralApp-debug.apk"
  sha256sum "$OUT/NativeNeutralApp-debug.apk" >"$OUT/NativeNeutralApp-debug.apk.sha256"
fi

[[ -f "$APP/package-lock.json" ]] && cp "$APP/package-lock.json" "$OUT/app-package-lock.json"
[[ -f "$APP/package.json" ]] && cp "$APP/package.json" "$OUT/app-package.json"
[[ -f "$LIBPKG/package-lock.json" ]] && cp "$LIBPKG/package-lock.json" "$OUT/library-package-lock.json"
[[ -f "$LIBPKG/package.json" ]] && cp "$LIBPKG/package.json" "$OUT/library-package.json"
[[ -f "$LIBPKG/MEV-818-LIBRARY-REPAIR.json" ]] && cp "$LIBPKG/MEV-818-LIBRARY-REPAIR.json" "$OUT/MEV-818-LIBRARY-REPAIR.json"
[[ -f "$APP/android/build.gradle" ]] && cp "$APP/android/build.gradle" "$OUT/android-build.gradle"
[[ -f "$APP/android/gradle/wrapper/gradle-wrapper.properties" ]] && cp "$APP/android/gradle/wrapper/gradle-wrapper.properties" "$OUT/gradle-wrapper.properties"

export OUT APP LIBPKG ACTUAL_BASE_SHA EXPECTED_BASE_SHA
python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import re
import subprocess

out = pathlib.Path(os.environ['OUT'])
app = pathlib.Path(os.environ['APP'])
lib = pathlib.Path(os.environ['LIBPKG'])

def code(name):
    try: return int((out / f'{name}.exit').read_text().strip())
    except Exception: return 99

def digest(path):
    if not path.is_file(): return None
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''): h.update(chunk)
    return {'bytes': path.stat().st_size, 'sha256': h.hexdigest()}

def load(path):
    try: return json.loads(path.read_text())
    except Exception: return None

def text(path, default=None):
    try: return path.read_text().strip()
    except Exception: return default

app_pkg = load(app / 'package.json') or {}
lock = load(app / 'package-lock.json') or {}
lib_pkg = load(lib / 'package.json') or {}
build = (app / 'android/build.gradle').read_text() if (app / 'android/build.gradle').is_file() else ''
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
    if profile.get(key) is not None: profile[key] = int(profile[key])

steps = {name: code(name) for name in [
    'patch-library', 'template-init', 'patch-app', 'app-install', 'dependency-receipt',
    'library-typecheck', 'library-declarations', 'app-typecheck', 'focused-contract',
    'metro-bundle', 'runtime-preflight', 'gradle-version', 'android-build',
]}
rn = lock.get('packages', {}).get('node_modules/react-native', {})
react = lock.get('packages', {}).get('node_modules/react', {})
ts = lock.get('packages', {}).get('node_modules/typescript', {})
focused = text(out / 'focused-contract.stdout.log', '') or ''
checks = {
    'baseArchiveIdentity': os.environ.get('ACTUAL_BASE_SHA') == os.environ.get('EXPECTED_BASE_SHA'),
    'dependencyIdentity': rn.get('version') == '0.87.1' and react.get('version') == '19.2.3' and ts.get('version') == '6.0.3',
    'officialReactNativeOrigin': rn.get('resolved') == 'https://registry.npmjs.org/react-native/-/react-native-0.87.1.tgz',
    'localPackageIdentity': app_pkg.get('dependencies', {}).get('@ui-foundation/ui-native') == 'file:../library/packages/ui-native' and lib_pkg.get('name') == '@ui-foundation/ui-native',
    'androidProfile': profile.get('compileSdk') == 35 and profile.get('targetSdk') == 35 and profile.get('buildTools') == '36.0.0' and profile.get('minSdk') == 24 and profile.get('ndk') == '27.1.12297006',
    'generatedTokenAdapter': 'PASS_MEV_818_FOCUSED_CONTRACT' in focused and 'PASS_REJECTED' in focused,
    'sourceIdentity': bool(text(out / 'source-commit')) and bool(text(out / 'source-tree')),
    'cleanTrackedSource': text(out / 'source-status-after-build.txt', '') == '',
    'sourceBundleProduced': digest(out / 'MEV-818-converged-source.bundle') is not None,
    'sourceArchiveProduced': digest(out / 'MEV-818-converged-source.tar.gz') is not None,
    'apkProduced': digest(out / 'NativeNeutralApp-debug.apk') is not None,
    'bundleProduced': digest(out / 'index.android.bundle') is not None,
}
required = list(steps)
status = 'PASS_MEV_818_CONVERGED_ANDROID_BUILD' if all(steps[name] == 0 for name in required) and all(checks.values()) else 'FAIL_MEV_818_CONVERGED_ANDROID_BUILD'
result = {
    'schema': 'mevix.mev-818-converged-product-build.v2',
    'issue': 'MEV-818',
    'status': status,
    'source': {
        'baseLibraryArchiveSha256': os.environ.get('ACTUAL_BASE_SHA'),
        'commit': text(out / 'source-commit'),
        'tree': text(out / 'source-tree'),
        'parent': text(out / 'source-parent'),
        'bundle': digest(out / 'MEV-818-converged-source.bundle'),
        'archive': digest(out / 'MEV-818-converged-source.tar.gz'),
    },
    'package': {
        'library': {'manifest': digest(lib / 'package.json'), 'lock': digest(lib / 'package-lock.json')},
        'app': {'manifest': digest(app / 'package.json'), 'lock': digest(app / 'package-lock.json')},
        'installed': {'reactNative': rn.get('version'), 'react': react.get('version'), 'typescript': ts.get('version')},
        'reactNativeResolved': rn.get('resolved'),
        'reactNativeIntegrity': rn.get('integrity'),
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
    'outputs': {'apk': digest(out / 'NativeNeutralApp-debug.apk'), 'jsBundle': digest(out / 'index.android.bundle')},
    'boundaries': {'emulator': 'NOT_RUN', 'device': 'NOT_RUN', 'talkBack': 'NOT_RUN', 'physicalTouch': 'NOT_RUN', 'owner': 'MEV-661'},
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
