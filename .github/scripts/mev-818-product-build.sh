#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE="$ROOT/transport/mev-818-product/chat-ui-foundation-mev-818-65ebacd.tar.gz"
EXPECTED_ARCHIVE_SHA="e4f04de8ff6394c6b37913da63b145bb3517b2d8d509fca8472cbd1c9bfe71ba"
EXPECTED_COMMIT="65ebacd50d9578a3447ad93dcf3dae0500e74b95"
EXPECTED_TREE="507347e47c67f1608a556cc0066addd0006f7ec3"
EXPECTED_LOCK_SHA="a9c5baad3ff45aaf45b993c1ac62e513b671c69a276af2f7c94568ec076ed1af"
EXPECTED_MANIFEST_SHA="5b2b4d26d893a34214ce23e47d486ba49981948c643e466eea9339aced38fe40"
WORK="$ROOT/.mev-818-product-work"
OUT="$ROOT/out/mev-818-product-build"
REPO="$WORK/repo"
PACKAGE="$REPO/packages/ui-native"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

run_capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

sha256sum "$ARCHIVE" >"$OUT/source-archive.sha256"
ACTUAL_ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_ARCHIVE_SHA" != "$EXPECTED_ARCHIVE_SHA" ]]; then
  printf 'archive mismatch: %s != %s\n' "$ACTUAL_ARCHIVE_SHA" "$EXPECTED_ARCHIVE_SHA" >"$OUT/source-archive.error"
else
  tar -xzf "$ARCHIVE" -C "$WORK"
fi

if [[ -d "$REPO" ]]; then
  sha256sum "$PACKAGE/package-lock.json" "$PACKAGE/package.json" >"$OUT/source-identities.sha256"
  run_capture root-native-tests bash -lc "cd '$REPO' && node tests/native/android/run.mjs"
  run_capture source-policy bash -lc "cd '$REPO' && node quality/rules/source-checks.mjs"
  run_capture npm-ci bash -lc "cd '$PACKAGE' && npm ci --no-audit --no-fund"
else
  printf '99\n' >"$OUT/root-native-tests.exit"
  printf '99\n' >"$OUT/source-policy.exit"
  printf '99\n' >"$OUT/npm-ci.exit"
fi

NPM_CI_EXIT="$(cat "$OUT/npm-ci.exit")"
if [[ "$NPM_CI_EXIT" == 0 ]]; then
  run_capture npm-ls bash -lc "cd '$PACKAGE' && npm ls --json --depth=0"
  run_capture typecheck bash -lc "cd '$PACKAGE' && npx tsc --noEmit"
  rm -rf "$PACKAGE/.generated"
  run_capture declaration-build bash -lc "cd '$PACKAGE' && npx tsc -p tsconfig.build.json"
  run_capture metro-bundle bash -lc "cd '$PACKAGE' && npx react-native bundle --platform android --dev false --entry-file index.js --bundle-output '$OUT/index.android.bundle' --assets-dest '$OUT/assets'"
  run_capture runtime-preflight env ANDROID_HOME="${ANDROID_HOME:-}" ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-}" node "$REPO/tests/native/android/check-runtime.mjs"
  run_capture gradle-version bash -lc "cd '$PACKAGE/android' && ./gradlew --version"
  run_capture android-build bash -lc "cd '$PACKAGE/android' && ./gradlew :app:assembleDebug --no-daemon --stacktrace"
else
  for name in npm-ls typecheck declaration-build metro-bundle runtime-preflight gradle-version android-build; do printf '99\n' >"$OUT/${name}.exit"; done
fi

APK_SOURCE="$(find "$PACKAGE/android/app/build/outputs/apk" -type f -name '*.apk' 2>/dev/null | sort | head -1 || true)"
if [[ -n "$APK_SOURCE" ]]; then
  cp "$APK_SOURCE" "$OUT/NativeNeutralApp-debug.apk"
  sha256sum "$OUT/NativeNeutralApp-debug.apk" >"$OUT/NativeNeutralApp-debug.apk.sha256"
fi

[[ -f "$PACKAGE/package-lock.json" ]] && cp "$PACKAGE/package-lock.json" "$OUT/package-lock.json"
[[ -f "$PACKAGE/package.json" ]] && cp "$PACKAGE/package.json" "$OUT/package.json"
[[ -f "$PACKAGE/android/build.gradle" ]] && cp "$PACKAGE/android/build.gradle" "$OUT/android-build.gradle"
[[ -f "$PACKAGE/android/gradle/wrapper/gradle-wrapper.properties" ]] && cp "$PACKAGE/android/gradle/wrapper/gradle-wrapper.properties" "$OUT/gradle-wrapper.properties"
[[ -f "$PACKAGE/.generated/build/packages/ui-native/src/android/react-native-materialization.d.ts" ]] && cp "$PACKAGE/.generated/build/packages/ui-native/src/android/react-native-materialization.d.ts" "$OUT/react-native-materialization.d.ts"

export OUT REPO PACKAGE EXPECTED_ARCHIVE_SHA ACTUAL_ARCHIVE_SHA EXPECTED_COMMIT EXPECTED_TREE EXPECTED_LOCK_SHA EXPECTED_MANIFEST_SHA
python3 - <<'PY'
import hashlib, json, os, pathlib, re, subprocess
out=pathlib.Path(os.environ['OUT']); repo=pathlib.Path(os.environ['REPO']); package=pathlib.Path(os.environ['PACKAGE'])
def code(name):
    try:return int((out/f'{name}.exit').read_text().strip())
    except:return 99
def digest(path):
    if not path.is_file():return None
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return {'bytes':path.stat().st_size,'sha256':h.hexdigest()}
def load(path):
    try:return json.loads(path.read_text())
    except:return None
pkg=load(package/'package.json') or {}
lock=load(package/'package-lock.json') or {}
installed_rn=load(package/'node_modules/react-native/package.json') or {}
installed_react=load(package/'node_modules/react/package.json') or {}
build=(package/'android/build.gradle').read_text() if (package/'android/build.gradle').is_file() else ''
profile={}
for key,pattern in {
 'buildTools':r'buildToolsVersion\s*=\s*"([^"]+)"',
 'compileSdk':r'compileSdkVersion\s*=\s*(\d+)',
 'targetSdk':r'targetSdkVersion\s*=\s*(\d+)',
 'minSdk':r'minSdkVersion\s*=\s*(\d+)',
 'ndk':r'ndkVersion\s*=\s*"([^"]+)"',
 'kotlin':r'kotlinVersion\s*=\s*"([^"]+)"',
}.items():
 m=re.search(pattern,build);profile[key]=m.group(1) if m else None
for key in ['compileSdk','targetSdk','minSdk']:
 if profile.get(key) is not None: profile[key]=int(profile[key])
steps={name:code(name) for name in ['root-native-tests','source-policy','npm-ci','npm-ls','typecheck','declaration-build','metro-bundle','runtime-preflight','gradle-version','android-build']}
source_policy=None
try: source_policy=json.loads((out/'source-policy.stdout.log').read_text())
except: pass
expected_radix=7
source_policy_ok=isinstance(source_policy,dict) and len(source_policy.get('diagnostics',[]))==expected_radix and all(x.get('code')=='EXTERNAL_NOT_QUALIFIED' and x.get('detail','').startswith('@radix-ui/') for x in source_policy['diagnostics'])
checks={
 'archiveIdentity':os.environ['ACTUAL_ARCHIVE_SHA']==os.environ['EXPECTED_ARCHIVE_SHA'],
 'lockIdentity':digest(package/'package-lock.json') and digest(package/'package-lock.json')['sha256']==os.environ['EXPECTED_LOCK_SHA'],
 'manifestIdentity':digest(package/'package.json') and digest(package/'package.json')['sha256']==os.environ['EXPECTED_MANIFEST_SHA'],
 'dependencyIdentity':pkg.get('dependencies',{}).get('react-native')=='0.87.1' and pkg.get('dependencies',{}).get('react')=='19.2.3' and installed_rn.get('version')=='0.87.1' and installed_react.get('version')=='19.2.3',
 'androidProfile':profile.get('compileSdk')==35 and profile.get('targetSdk')==35 and profile.get('buildTools')=='36.0.0' and profile.get('minSdk')==24,
 'sourcePolicy':source_policy_ok,
 'apkProduced':digest(out/'NativeNeutralApp-debug.apk') is not None,
 'bundleProduced':digest(out/'index.android.bundle') is not None,
}
required=['root-native-tests','source-policy','npm-ci','npm-ls','typecheck','declaration-build','metro-bundle','runtime-preflight','gradle-version','android-build']
status='PASS_MEV_818_EXACT_ANDROID_BUILD' if all(steps[k]==0 for k in required) and all(checks.values()) else 'FAIL_MEV_818_EXACT_ANDROID_BUILD'
result={
 'schema':'mevix.mev-818-product-build.v1','issue':'MEV-818','status':status,
 'source':{'commit':os.environ['EXPECTED_COMMIT'],'tree':os.environ['EXPECTED_TREE'],'archive':{'sha256':os.environ['ACTUAL_ARCHIVE_SHA']}},
 'package':{'name':pkg.get('name'),'version':pkg.get('version'),'lockfileVersion':lock.get('lockfileVersion'),'lock':digest(package/'package-lock.json'),'manifest':digest(package/'package.json'),'declared':pkg.get('dependencies'),'installed':{'reactNative':installed_rn.get('version'),'react':installed_react.get('version')}},
 'environment':{'node':subprocess.run(['node','--version'],capture_output=True,text=True).stdout.strip(),'npm':subprocess.run(['npm','--version'],capture_output=True,text=True).stdout.strip(),'java':subprocess.run(['java','-version'],capture_output=True,text=True).stderr.splitlines()[0] if subprocess.run(['java','-version'],capture_output=True,text=True).stderr else None,'androidHome':os.environ.get('ANDROID_HOME')},
 'androidProfile':profile,'steps':steps,'checks':checks,
 'outputs':{'apk':digest(out/'NativeNeutralApp-debug.apk'),'jsBundle':digest(out/'index.android.bundle'),'declaration':digest(out/'react-native-materialization.d.ts')},
 'boundaries':{'emulator':'NOT_RUN','device':'NOT_RUN','talkBack':'NOT_RUN','physicalTouch':'NOT_RUN','screenshot':'NOT_RUN','owner':'MEV-661'},
}
(out/'RESULT.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
print(json.dumps(result,indent=2,sort_keys=True))
PY

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
python3 - <<'PY'
import pathlib, zipfile
root=pathlib.Path('out/mev-818-product-build')
out=pathlib.Path('out/MEV-818-exact-product-build.zip')
with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file(): z.write(p,p.relative_to(root.parent))
print(out)
PY
cat "$OUT/RESULT.json"
exit 0
