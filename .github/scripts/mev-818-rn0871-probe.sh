#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/out/mev-818-rn0871-probe"
WORK="$ROOT/.mev-818-work"
APP="$WORK/NativeNeutralApp"
mkdir -p "$OUT"
rm -rf "$WORK"
mkdir -p "$WORK"

run_capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

set -e
{
  echo "node=$(node --version 2>/dev/null || true)"
  echo "npm=$(npm --version 2>/dev/null || true)"
  echo "java=$(java -version 2>&1 | head -1 || true)"
  echo "gradle=$(gradle --version 2>/dev/null | head -1 || true)"
  echo "ANDROID_HOME=${ANDROID_HOME:-}"
  echo "ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-}"
} >"$OUT/environment.txt"

run_capture npm-view-react-native npm view react-native@0.87.1 name version engines peerDependencies dependencies dist.integrity dist.tarball --json
run_capture npm-view-cli npm view @react-native-community/cli@latest name version engines dist.integrity dist.tarball --json
run_capture cli-help npx --yes @react-native-community/cli@latest init --help

set +e
(
  cd "$WORK"
  CI=1 npx --yes @react-native-community/cli@latest init NativeNeutralApp \
    --version 0.87.1 \
    --skip-git-init
) >"$OUT/init.stdout.log" 2>"$OUT/init.stderr.log"
INIT_EXIT=$?
set -e
printf '%s\n' "$INIT_EXIT" >"$OUT/init.exit"

TYPECHECK_EXIT=99
BUNDLE_EXIT=99
ANDROID_EXIT=99
APK_PATH=""

if [[ "$INIT_EXIT" -eq 0 && -d "$APP" ]]; then
  cp "$APP/package.json" "$OUT/scaffold-package.json"
  [[ -f "$APP/package-lock.json" ]] && cp "$APP/package-lock.json" "$OUT/scaffold-package-lock.json"
  [[ -f "$APP/tsconfig.json" ]] && cp "$APP/tsconfig.json" "$OUT/scaffold-tsconfig.json"
  [[ -f "$APP/App.tsx" ]] && cp "$APP/App.tsx" "$OUT/scaffold-App.tsx"
  [[ -f "$APP/index.js" ]] && cp "$APP/index.js" "$OUT/scaffold-index.js"
  find "$APP/android" -maxdepth 4 -type f \
    \( -name '*.gradle' -o -name '*.gradle.kts' -o -name 'gradle.properties' -o -name 'gradle-wrapper.properties' -o -name 'AndroidManifest.xml' \) \
    -print | sort >"$OUT/android-files.txt"
  tar -C "$APP" -czf "$OUT/scaffold-android-source.tar.gz" \
    --exclude='android/.gradle' --exclude='android/app/build' --exclude='android/build' android package.json package-lock.json tsconfig.json App.tsx index.js 2>"$OUT/scaffold-tar.stderr.log" || true

  set +e
  (cd "$APP" && npx tsc --noEmit) >"$OUT/typecheck.stdout.log" 2>"$OUT/typecheck.stderr.log"
  TYPECHECK_EXIT=$?
  set -e
  printf '%s\n' "$TYPECHECK_EXIT" >"$OUT/typecheck.exit"

  set +e
  (cd "$APP" && npx react-native bundle --platform android --dev false --entry-file index.js --bundle-output "$OUT/index.android.bundle" --assets-dest "$OUT/assets") \
    >"$OUT/bundle.stdout.log" 2>"$OUT/bundle.stderr.log"
  BUNDLE_EXIT=$?
  set -e
  printf '%s\n' "$BUNDLE_EXIT" >"$OUT/bundle.exit"

  set +e
  (cd "$APP/android" && ./gradlew :app:assembleDebug --no-daemon --stacktrace) \
    >"$OUT/android-build.stdout.log" 2>"$OUT/android-build.stderr.log"
  ANDROID_EXIT=$?
  set -e
  printf '%s\n' "$ANDROID_EXIT" >"$OUT/android-build.exit"

  APK_PATH="$(find "$APP/android/app/build/outputs/apk" -type f -name '*.apk' 2>/dev/null | sort | head -1 || true)"
  if [[ -n "$APK_PATH" ]]; then
    cp "$APK_PATH" "$OUT/NativeNeutralApp-debug.apk"
    sha256sum "$OUT/NativeNeutralApp-debug.apk" >"$OUT/NativeNeutralApp-debug.apk.sha256"
  fi

  (cd "$APP" && npm ls --json --depth=0) >"$OUT/npm-ls-depth0.json" 2>"$OUT/npm-ls-depth0.stderr.log" || true
  node -e 'const p=require(process.argv[1]); console.log(JSON.stringify({name:p.name,version:p.version,dependencies:p.dependencies,devDependencies:p.devDependencies,engines:p.engines},null,2))' "$APP/package.json" >"$OUT/package-summary.json"
fi

export OUT WORK APP INIT_EXIT TYPECHECK_EXIT BUNDLE_EXIT ANDROID_EXIT APK_PATH
python3 - <<'PY'
import hashlib, json, os, pathlib, platform, subprocess
out = pathlib.Path(os.environ['OUT'])
app = pathlib.Path(os.environ['APP'])

def read_json(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None

def digest(path):
    if not path.is_file(): return None
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
    return {'bytes':path.stat().st_size,'sha256':h.hexdigest()}

package = read_json(app/'package.json') if app.exists() else None
lock = read_json(app/'package-lock.json') if app.exists() else None
apk = out/'NativeNeutralApp-debug.apk'
bundle = out/'index.android.bundle'
result = {
  'schema':'mevix.mev-818-rn0871-hosted-probe.v1',
  'issue':'MEV-818',
  'target':{'reactNative':'0.87.1','androidSdkPlatform':35,'androidBuildTools':'36.0.0','jdk':17},
  'environment':{
    'python':platform.python_version(),
    'node':subprocess.run(['node','--version'],capture_output=True,text=True).stdout.strip(),
    'npm':subprocess.run(['npm','--version'],capture_output=True,text=True).stdout.strip(),
    'java':subprocess.run(['java','-version'],capture_output=True,text=True).stderr.splitlines()[0] if subprocess.run(['java','-version'],capture_output=True,text=True).stderr else None,
    'androidHome':os.environ.get('ANDROID_HOME'),
  },
  'steps':{
    'init':int(os.environ['INIT_EXIT']),
    'typecheck':int(os.environ['TYPECHECK_EXIT']),
    'bundle':int(os.environ['BUNDLE_EXIT']),
    'androidBuild':int(os.environ['ANDROID_EXIT']),
  },
  'package':package,
  'lock':{'lockfileVersion':lock.get('lockfileVersion') if isinstance(lock,dict) else None,'sha256':digest(app/'package-lock.json')},
  'outputs':{'apk':digest(apk),'jsBundle':digest(bundle)},
}
result['status'] = 'PASS_HOSTED_RN0871_ANDROID_BUILD' if all(result['steps'][k] == 0 for k in ['init','typecheck','bundle','androidBuild']) and result['outputs']['apk'] else 'FAIL_HOSTED_RN0871_PROBE'
(out/'RESULT.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
PY

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)

python3 - <<'PY'
import pathlib, zipfile
root=pathlib.Path('out/mev-818-rn0871-probe')
out=pathlib.Path('out/MEV-818-rn0871-hosted-probe.zip')
with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file(): z.write(p,p.relative_to(root.parent))
print(out)
PY

cat "$OUT/RESULT.json"
exit 0
