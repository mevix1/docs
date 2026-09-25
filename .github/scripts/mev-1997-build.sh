#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$ROOT/input/MEV-1997-native-state-matrix-source.bundle"
WORK="$ROOT/.mev-1997-work"
REPO="$WORK/repo"
APP="$REPO/NativeNeutralApp"
OUT="$ROOT/out/mev-1997-build"
EXPECTED_COMMIT="a54e8d08f5cbb1d2d769053a2902cfab4f0df739"
EXPECTED_TREE="5d0eeafed328f779e7d40878be5e5aafc8ea4499"
EXPECTED_PARENT="b761a10fbd148dfa2c21ce4640dc5161ab06711a"
EXPECTED_BUNDLE_SHA="7431a95aa7e3299ec99ceee6fc98c5edd4e5bbd8f77d4a78a84c65ecabd4ecb6"
EXPECTED_LOCK_SHA="d3c1b1716cb5c8be45b35372a627327c19065e9590900a213c531c015e967776"
EXPECTED_MANIFEST_SHA="ea9d2deff510d34cf3fbb6d20243dc34a4cdac76845dc34df3d3e155953ccb25"
EXPECTED_LIBRARY_PACK_SHA="9b7f459917989ce35ed4211717fc6bfd6aafba68d77ac697176184511e20adfe"

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

run_capture bundle-verify bash -lc "echo '$EXPECTED_BUNDLE_SHA  $BUNDLE' | sha256sum -c - && git bundle verify '$BUNDLE'"
run_capture source-clone git clone "$BUNDLE" "$REPO"
if [[ "$(cat "$OUT/source-clone.exit")" == 0 ]]; then
  run_capture source-checkout git -C "$REPO" checkout "$EXPECTED_COMMIT"
else
  printf '99\n' >"$OUT/source-checkout.exit"
fi

if [[ "$(cat "$OUT/source-checkout.exit")" == 0 ]]; then
  run_capture source-identity bash -lc "test \"\$(git -C '$REPO' rev-parse HEAD)\" = '$EXPECTED_COMMIT' && test \"\$(git -C '$REPO' rev-parse 'HEAD^{tree}')\" = '$EXPECTED_TREE' && test \"\$(git -C '$REPO' rev-parse 'HEAD^')\" = '$EXPECTED_PARENT' && test -z \"\$(git -C '$REPO' status --porcelain)\""
  run_capture changed-paths bash -lc "cd '$REPO' && test \"\$(git diff --name-only HEAD^ HEAD | sort | tr '\n' '|')\" = 'NativeNeutralApp/App.tsx|NativeNeutralApp/MEV818Plan.ts|NativeNeutralApp/mev818-tests/contract.test.ts|'"
  run_capture locked-input bash -lc "echo '$EXPECTED_LOCK_SHA  $APP/package-lock.json' | sha256sum -c - && echo '$EXPECTED_MANIFEST_SHA  $APP/package.json' | sha256sum -c - && echo '$EXPECTED_LIBRARY_PACK_SHA  $REPO/library-pack/ui-foundation-ui-native-0.1.0.tgz' | sha256sum -c -"
  git -C "$REPO" ls-files -z | sort -z | xargs -0 -I{} sha256sum "$REPO/{}" >"$OUT/tracked-files.sha256"
  git -C "$REPO" format-patch -1 --stdout >"$OUT/MEV-1997.patch"
  cp "$BUNDLE" "$OUT/MEV-1997-source.bundle"
else
  for name in source-identity changed-paths locked-input; do printf '99\n' >"$OUT/${name}.exit"; done
fi

if [[ "$(cat "$OUT/locked-input.exit")" == 0 ]]; then
  run_capture npm-ci bash -lc "cd '$APP' && npm ci --no-audit --no-fund"
else
  printf '99\n' >"$OUT/npm-ci.exit"
fi

if [[ "$(cat "$OUT/npm-ci.exit")" == 0 ]]; then
  run_capture dependency-receipt bash -lc "cd '$APP' && npm ls --json --depth=0"
  run_capture contract-test bash -lc "cd '$APP' && npx tsx mev818-tests/contract.test.ts"
  run_capture typecheck bash -lc "cd '$APP' && npx tsc --noEmit"
  run_capture jest bash -lc "cd '$APP' && npm test -- --runInBand"
  run_capture metro-bundle bash -lc "cd '$APP' && npx react-native bundle --platform android --dev false --entry-file index.js --bundle-output '$OUT/index.android.bundle' --assets-dest '$OUT/assets'"
  run_capture gradle-version bash -lc "cd '$APP/android' && ./gradlew --version"
  run_capture android-build bash -lc "cd '$APP/android' && ./gradlew :app:assembleDebug --no-daemon --stacktrace"
else
  for name in dependency-receipt contract-test typecheck jest metro-bundle gradle-version android-build; do printf '99\n' >"$OUT/${name}.exit"; done
fi

APK_SOURCE="$(find "$APP/android/app/build/outputs/apk" -type f -name '*.apk' 2>/dev/null | sort | head -1 || true)"
if [[ -n "$APK_SOURCE" ]]; then
  cp "$APK_SOURCE" "$OUT/MEV-1997-state-matrix-debug.apk"
  sha256sum "$OUT/MEV-1997-state-matrix-debug.apk" >"$OUT/MEV-1997-state-matrix-debug.apk.sha256"
fi
cp "$APP/package.json" "$OUT/package.json" 2>/dev/null || true
cp "$APP/package-lock.json" "$OUT/package-lock.json" 2>/dev/null || true
cp "$APP/App.tsx" "$OUT/App.tsx" 2>/dev/null || true
cp "$APP/MEV818Plan.ts" "$OUT/MEV818Plan.ts" 2>/dev/null || true
cp "$APP/mev818-tests/contract.test.ts" "$OUT/contract.test.ts" 2>/dev/null || true

after_lock="$(sha256sum "$APP/package-lock.json" 2>/dev/null | awk '{print $1}')"
after_manifest="$(sha256sum "$APP/package.json" 2>/dev/null | awk '{print $1}')"
run_capture final-source-clean bash -lc "test '$after_lock' = '$EXPECTED_LOCK_SHA' && test '$after_manifest' = '$EXPECTED_MANIFEST_SHA' && test -z \"\$(git -C '$REPO' status --porcelain)\""

export OUT REPO APP EXPECTED_COMMIT EXPECTED_TREE EXPECTED_PARENT EXPECTED_BUNDLE_SHA EXPECTED_LOCK_SHA EXPECTED_MANIFEST_SHA EXPECTED_LIBRARY_PACK_SHA
python3 - <<'PY'
import hashlib,json,os,pathlib,subprocess,re
out=pathlib.Path(os.environ['OUT']); repo=pathlib.Path(os.environ['REPO']); app=pathlib.Path(os.environ['APP'])
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
steps={name:code(name) for name in [
 'bundle-verify','source-clone','source-checkout','source-identity','changed-paths','locked-input','npm-ci','dependency-receipt','contract-test','typecheck','jest','metro-bundle','gradle-version','android-build','final-source-clean'
]}
pkg=load(app/'package.json') or {}; lock=load(app/'package-lock.json') or {}
contract=(out/'contract-test.stdout.log').read_text(errors='replace') if (out/'contract-test.stdout.log').is_file() else ''
scenarios=['light-enabled','dark-enabled','busy','invalid','disabled']
checks={
 'sourceIdentity':all(steps[n]==0 for n in ['bundle-verify','source-clone','source-checkout','source-identity','changed-paths']),
 'lockedInputs':steps['locked-input']==0 and steps['final-source-clean']==0,
 'exactDependencies':pkg.get('dependencies',{}).get('react-native')=='0.87.1' and pkg.get('dependencies',{}).get('react')=='19.2.3',
 'contractScenarios':all(x in contract for x in scenarios) and 'PASS_MEV_1997_STATE_MATRIX_CONTRACT' in contract,
 'metroProduced':digest(out/'index.android.bundle') is not None,
 'apkProduced':digest(out/'MEV-1997-state-matrix-debug.apk') is not None,
}
required=list(steps)
status='PASS_MEV_1997_STATE_MATRIX_BUILD' if all(steps[n]==0 for n in required) and all(checks.values()) else 'FAIL_MEV_1997_STATE_MATRIX_BUILD'
result={
 'schema':'mevix.mev-1997-state-matrix-build.v1','issue':'MEV-1997','status':status,
 'source':{'commit':os.environ['EXPECTED_COMMIT'],'tree':os.environ['EXPECTED_TREE'],'parent':os.environ['EXPECTED_PARENT'],'bundle':digest(out/'MEV-1997-source.bundle'),'trackedFiles':len(subprocess.check_output(['git','-C',str(repo),'ls-files'],text=True).splitlines()),'changedPaths':subprocess.check_output(['git','-C',str(repo),'diff','--name-only','HEAD^','HEAD'],text=True).splitlines()},
 'package':{'manifest':digest(app/'package.json'),'lock':digest(app/'package-lock.json'),'libraryPack':digest(repo/'library-pack/ui-foundation-ui-native-0.1.0.tgz'),'lockfileVersion':lock.get('lockfileVersion')},
 'steps':steps,'checks':checks,'scenarios':scenarios,
 'outputs':{'apk':digest(out/'MEV-1997-state-matrix-debug.apk'),'metroBundle':digest(out/'index.android.bundle')},
 'boundaries':{'emulatorStateMatrix':'NOT_RUN','TalkBackLive':'NOT_RUN','nativeIMEComposition':'NOT_RUN','physicalDevice':'NOT_RUN','physicalTouch':'NOT_RUN','owner':'MEV-661'},
}
(out/'RESULT.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
print(json.dumps(result,indent=2,sort_keys=True))
PY

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
python3 - <<'PY'
import pathlib,zipfile
root=pathlib.Path('out/mev-1997-build'); target=pathlib.Path('out/MEV-1997-state-matrix-build.zip')
with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file(): z.write(p,p.relative_to(root.parent))
print(target)
PY
cat "$OUT/RESULT.json"
