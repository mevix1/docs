#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INPUT="$ROOT/input/mev-1997-build"
WORK="$ROOT/.mev-1997-emulator-work"
SOURCE="$WORK/source"
APP="$SOURCE/NativeNeutralApp"
OUT="$ROOT/out/mev-1997-emulator"
APK="$INPUT/MEV-1997-state-matrix-debug.apk"
BUNDLE="$INPUT/MEV-1997-source.bundle"
BUILD_RESULT="$INPUT/RESULT.json"
EXPECTED_COMMIT="f54cd82421aff5921f141b935daab55bcba67226"
EXPECTED_TREE="7e0c2bbf6afdbadd0cefcb00b496fe6a21c14d10"
EXPECTED_PARENT="b761a10fbd148dfa2c21ce4640dc5161ab06711a"
EXPECTED_APK_SHA="7c5eda7c57d0bf86aad44ee6f7dd0c04bda87141a98b981207ec50cd426ec7aa"
EXPECTED_LOCK_SHA="d3c1b1716cb5c8be45b35372a627327c19065e9590900a213c531c015e967776"
AVD_NAME="mev1997-api35"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT/screenshots" "$OUT/ui"

run_capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

run_capture input-identity python3 - "$BUILD_RESULT" "$APK" "$BUNDLE" <<'PY'
import hashlib,json,pathlib,sys
def digest(path):
 h=hashlib.sha256();
 with path.open('rb') as f:
  for c in iter(lambda:f.read(1048576),b''):h.update(c)
 return h.hexdigest()
r=json.load(open(sys.argv[1])); apk=pathlib.Path(sys.argv[2]); bundle=pathlib.Path(sys.argv[3])
assert r['status']=='PASS_MEV_1997_STATE_MATRIX_BUILD'
assert r['source']['commit']=='f54cd82421aff5921f141b935daab55bcba67226'
assert r['source']['tree']=='7e0c2bbf6afdbadd0cefcb00b496fe6a21c14d10'
assert r['source']['parent']=='b761a10fbd148dfa2c21ce4640dc5161ab06711a'
assert r['package']['lock']['sha256']=='d3c1b1716cb5c8be45b35372a627327c19065e9590900a213c531c015e967776'
assert digest(apk)=='7c5eda7c57d0bf86aad44ee6f7dd0c04bda87141a98b981207ec50cd426ec7aa'
assert digest(bundle)=='ea7f1f3821508e1d0b932451e5702496789acf4dfc6d84fec6e76ac57d96ee83'
PY
run_capture source-clone git clone "$BUNDLE" "$SOURCE"
if [[ "$(cat "$OUT/source-clone.exit")" == 0 ]]; then
  run_capture source-checkout git -C "$SOURCE" checkout "$EXPECTED_COMMIT"
  run_capture source-identity bash -lc "test \"\$(git -C '$SOURCE' rev-parse HEAD)\" = '$EXPECTED_COMMIT' && test \"\$(git -C '$SOURCE' rev-parse 'HEAD^{tree}')\" = '$EXPECTED_TREE' && test \"\$(git -C '$SOURCE' rev-parse 'HEAD^')\" = '$EXPECTED_PARENT' && test -z \"\$(git -C '$SOURCE' status --porcelain)\" && echo '$EXPECTED_LOCK_SHA  $APP/package-lock.json' | sha256sum -c -"
else
  printf '99\n' >"$OUT/source-checkout.exit"; printf '99\n' >"$OUT/source-identity.exit"
fi

if [[ "$(cat "$OUT/source-identity.exit")" == 0 ]]; then
  run_capture npm-ci bash -lc "cd '$APP' && npm ci --no-audit --no-fund"
else
  printf '99\n' >"$OUT/npm-ci.exit"
fi

if [[ "$(cat "$OUT/npm-ci.exit")" == 0 ]]; then
  set +e
  (cd "$APP" && npx react-native start --host 127.0.0.1 --port 8081 --reset-cache) >"$OUT/metro.log" 2>&1 &
  METRO_PID=$!
  set -e
  echo "$METRO_PID" >"$OUT/metro.pid"
  run_capture metro-ready bash -lc "for i in \$(seq 1 120); do curl -fsS http://127.0.0.1:8081/status | grep -q 'packager-status:running' && exit 0; sleep 1; done; exit 1"
else
  printf '99\n' >"$OUT/metro-ready.exit"
fi

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
AVDMANAGER="$(find "$SDK_ROOT/cmdline-tools" -type f -name avdmanager -perm -u+x 2>/dev/null | sort | tail -1)"
EMULATOR="$SDK_ROOT/emulator/emulator"
ADB="$SDK_ROOT/platform-tools/adb"
AAPT="$SDK_ROOT/build-tools/35.0.0/aapt"
mkdir -p "${ANDROID_USER_HOME:-$HOME/.android}" "${ANDROID_AVD_HOME:-${ANDROID_USER_HOME:-$HOME/.android}/avd}"
run_capture avd-create bash -lc "echo no | '$AVDMANAGER' create avd --force --name '$AVD_NAME' --package 'system-images;android-35;google_apis;x86_64' --device pixel_6"
if [[ "$(cat "$OUT/avd-create.exit")" == 0 ]]; then
  set +e
  "$EMULATOR" -avd "$AVD_NAME" -no-window -gpu swiftshader_indirect -no-audio -no-boot-anim -no-snapshot -wipe-data >"$OUT/emulator.log" 2>&1 &
  EMULATOR_PID=$!
  set -e
  echo "$EMULATOR_PID" >"$OUT/emulator.pid"
  run_capture emulator-boot bash -lc "'$ADB' wait-for-device; for i in \$(seq 1 240); do test \"\$('$ADB' shell getprop sys.boot_completed 2>/dev/null | tr -d '\\r')\" = 1 && exit 0; sleep 2; done; exit 1"
else
  printf '99\n' >"$OUT/emulator-boot.exit"
fi

if [[ "$(cat "$OUT/emulator-boot.exit")" == 0 ]]; then
  run_capture device-profile bash -lc "'$ADB' shell getprop ro.build.version.sdk; '$ADB' shell getprop ro.build.version.release; '$ADB' shell getprop ro.product.model; '$ADB' shell getprop ro.product.cpu.abi; '$ADB' shell wm size; '$ADB' shell wm density"
  run_capture apk-install "$ADB" install -r -t "$APK"
  run_capture adb-reverse "$ADB" reverse tcp:8081 tcp:8081
else
  for n in device-profile apk-install adb-reverse; do printf '99\n' >"$OUT/$n.exit"; done
fi

PACKAGE="$($AAPT dump badging "$APK" | sed -n "s/package: name='\([^']*\)'.*/\1/p" | head -1)"
ACTIVITY="$($AAPT dump badging "$APK" | sed -n "s/launchable-activity: name='\([^']*\)'.*/\1/p" | head -1)"
printf '%s\n' "$PACKAGE" >"$OUT/package-name.txt"; printf '%s\n' "$ACTIVITY" >"$OUT/activity-name.txt"

ui_dump() {
  local name="$1"
  "$ADB" shell uiautomator dump --compressed "/sdcard/$name.xml" >/dev/null 2>&1 || return 1
  "$ADB" pull "/sdcard/$name.xml" "$OUT/ui/$name.xml" >/dev/null 2>&1 || return 1
}
wait_desc() {
  local fragment="$1" name="$2"
  for i in $(seq 1 120); do
    ui_dump "$name" || true
    grep -Fq "$fragment" "$OUT/ui/$name.xml" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
node_center() {
  python3 - "$1" "$2" <<'PY'
import re,sys,xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot(); target=sys.argv[2]
for n in root.iter('node'):
 d=n.attrib.get('content-desc',''); t=n.attrib.get('text','')
 if target==d or target==t or target in d:
  m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',n.attrib.get('bounds',''))
  if m:
   x1,y1,x2,y2=map(int,m.groups()); print((x1+x2)//2,(y1+y2)//2); raise SystemExit(0)
raise SystemExit(1)
PY
}
tap_node() {
  local dump="$1" label="$2" coords
  coords="$(node_center "$dump" "$label")" || return 1
  "$ADB" shell input tap $coords
}
capture() {
  local name="$1"
  "$ADB" exec-out screencap -p >"$OUT/screenshots/$name.png"
  ui_dump "$name"
}

if [[ "$(cat "$OUT/apk-install.exit")" == 0 && "$(cat "$OUT/metro-ready.exit")" == 0 ]]; then
  "$ADB" logcat -c
  "$ADB" shell settings put global hide_error_dialogs 1 || true
  run_capture cold-launch "$ADB" shell am start -W -n "$PACKAGE/$ACTIVITY"
  run_capture light-ready wait_desc "Light native state" light-ready
  if [[ "$(cat "$OUT/light-ready.exit")" == 0 ]]; then capture light-enabled; fi
  run_capture local-state bash -lc "coords=\$(python3 - '$OUT/ui/light-enabled.xml' <<'PY'
import re,sys,xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
 if n.attrib.get('content-desc','').startswith('Name'):
  m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',n.attrib['bounds']); x1,y1,x2,y2=map(int,m.groups()); print((x1+x2)//2,(y1+y2)//2); break
PY
); '$ADB' shell input tap \$coords; '$ADB' shell input keyevent 123; '$ADB' shell input text Agent; sleep 1; '$ADB' shell input keyevent 4; sleep 1; coords=\$(python3 - '$OUT/ui/light-enabled.xml' <<'PY'
import re,sys,xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
 if n.attrib.get('content-desc')=='Confirm':
  m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',n.attrib['bounds']); x1,y1,x2,y2=map(int,m.groups()); print((x1+x2)//2,(y1+y2)//2); break
PY
); '$ADB' shell input tap \$coords; sleep 2"
  run_capture local-state-ready wait_desc "Action completed." light-after-action
  if [[ "$(cat "$OUT/local-state-ready.exit")" == 0 ]]; then capture light-after-action; fi
  for spec in "Dark enabled|Dark native state|dark-enabled" "Busy|Busy native state|busy" "Invalid|Invalid native state|invalid" "Disabled|Disabled native state|disabled"; do
    IFS='|' read -r label root name <<<"$spec"
    ui_dump selector-current
    run_capture "tap-$name" tap_node "$OUT/ui/selector-current.xml" "Scenario $label"
    run_capture "ready-$name" wait_desc "$root" "$name-ready"
    if [[ "$(cat "$OUT/ready-$name.exit")" == 0 ]]; then capture "$name"; fi
  done
  run_capture warm-launch bash -lc "'$ADB' shell am force-stop '$PACKAGE'; '$ADB' shell am start -W -n '$PACKAGE/$ACTIVITY'"
else
  for n in cold-launch light-ready local-state local-state-ready tap-dark-enabled ready-dark-enabled tap-busy ready-busy tap-invalid ready-invalid tap-disabled ready-disabled warm-launch; do printf '99\n' >"$OUT/$n.exit"; done
fi

"$ADB" logcat -d -v threadtime >"$OUT/logcat.txt" 2>/dev/null || true
run_capture crash-scan python3 - "$OUT/logcat.txt" <<'PY'
import json,re,sys
lines=open(sys.argv[1],errors='replace').read().splitlines(); ps=[re.compile(x,re.I) for x in [r'FATAL EXCEPTION',r'Unable to load script',r'Invariant Violation',r'ReactNativeJS:\s*(?:ERROR|Error)\b']]; hits=[l for l in lines if any(p.search(l) for p in ps)]; print(json.dumps({'hits':hits},indent=2)); raise SystemExit(1 if hits else 0)
PY

export OUT APK BUNDLE SOURCE APP EXPECTED_COMMIT EXPECTED_TREE EXPECTED_PARENT EXPECTED_APK_SHA EXPECTED_LOCK_SHA
python3 - <<'PY'
import hashlib,json,os,pathlib,re,subprocess,xml.etree.ElementTree as ET
out=pathlib.Path(os.environ['OUT']); apk=pathlib.Path(os.environ['APK']); bundle=pathlib.Path(os.environ['BUNDLE'])
def code(n):
 try:return int((out/f'{n}.exit').read_text().strip())
 except:return 99
def digest(p):
 if not p.is_file():return None
 h=hashlib.sha256()
 with p.open('rb') as f:
  for c in iter(lambda:f.read(1048576),b''):h.update(c)
 return {'bytes':p.stat().st_size,'sha256':h.hexdigest()}
def parse(name):
 p=out/'ui'/f'{name}.xml'; nodes=list(ET.parse(p).getroot().iter('node')) if p.is_file() else []
 return [{k:n.attrib.get(k,'') for k in ['text','content-desc','enabled','focusable','selected','clickable','bounds','class']} for n in nodes]
def find(nodes,needle): return [n for n in nodes if needle in n['content-desc'] or needle in n['text']]
def height_dp(node,density=420):
 m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',node.get('bounds',''))
 return None if not m else (int(m.group(4))-int(m.group(2)))*160/density
names=['light-enabled','light-after-action','dark-enabled','busy','invalid','disabled']; trees={n:parse(n) for n in names}
light=trees['light-enabled']; after=trees['light-after-action']; dark=trees['dark-enabled']; busy=trees['busy']; invalid=trees['invalid']; disabled=trees['disabled']
confirm=(find(light,'Confirm') or [{}])[0]
checks={
 'lightRuntime':bool(find(light,'Light native state')) and bool(find(light,'Scenario Light enabled')),
 'localState':bool(find(after,'Native UIAgent')) and bool(find(after,'Action completed.')),
 'darkRuntime':bool(find(dark,'Dark native state')) and bool(find(dark,'Scenario Dark enabled')),
 'busyRuntime':bool(find(busy,'Busy native state')) and bool(find(busy,'Confirming')),
 'invalidRuntime':bool(find(invalid,'Invalid native state')) and bool(find(invalid,'Name is required.')),
 'disabledRuntime':bool(find(disabled,'Disabled native state')) and bool(find(disabled,'Confirm')),
 'minimumTouchTarget':(height_dp(confirm) or 0)>=48,
 'screenshots':all((out/'screenshots'/f'{n}.png').is_file() and (out/'screenshots'/f'{n}.png').stat().st_size>50000 for n in names),
 'crashFree':code('crash-scan')==0,
}
steps={n:code(n) for n in ['input-identity','source-clone','source-checkout','source-identity','npm-ci','metro-ready','avd-create','emulator-boot','device-profile','apk-install','adb-reverse','cold-launch','light-ready','local-state','local-state-ready','tap-dark-enabled','ready-dark-enabled','tap-busy','ready-busy','tap-invalid','ready-invalid','tap-disabled','ready-disabled','warm-launch','crash-scan']}
status='PASS_MEV_1997_EMULATOR_STATE_MATRIX' if all(steps.values().__iter__()) is False else 'PENDING'
# Do not use truthiness of integer exit values: all required exits must be exactly zero.
status='PASS_MEV_1997_EMULATOR_STATE_MATRIX' if all(v==0 for v in steps.values()) and all(checks.values()) else 'FAIL_MEV_1997_EMULATOR_STATE_MATRIX'
result={'schema':'mevix.mev-1997-emulator-state-matrix.v1','issue':'MEV-1997','status':status,'terminalMEV661':False,'candidate':{'sourceCommit':os.environ['EXPECTED_COMMIT'],'sourceTree':os.environ['EXPECTED_TREE'],'sourceParent':os.environ['EXPECTED_PARENT'],'bundle':digest(bundle),'apk':digest(apk),'lockSha256':os.environ['EXPECTED_LOCK_SHA']},'environment':{'androidApi':35,'androidRelease':15,'model':'sdk_gphone64_x86_64','abi':'x86_64','viewport':'1080x2400','densityDpi':420},'steps':steps,'checks':checks,'ui':trees,'screenshots':names,'boundaries':{'TalkBackLive':'NOT_RUN','nativeIMEComposition':'NOT_RUN','physicalDevice':'NOT_RUN','physicalTouch':'NOT_RUN','owner':'MEV-661'}}
(out/'RESULT.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n'); print(json.dumps(result,indent=2,sort_keys=True))
PY

cp "$BUNDLE" "$OUT/MEV-1997-source.bundle" 2>/dev/null || true
cp "$APK" "$OUT/MEV-1997-state-matrix-debug.apk" 2>/dev/null || true
cp "$APP/App.tsx" "$OUT/App.tsx" 2>/dev/null || true
cp "$APP/MEV818Plan.ts" "$OUT/MEV818Plan.ts" 2>/dev/null || true
(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
python3 - <<'PY'
import pathlib,zipfile
root=pathlib.Path('out/mev-1997-emulator'); target=pathlib.Path('out/MEV-1997-emulator-state-matrix.zip')
with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for p in sorted(root.rglob('*')):
  if p.is_file(): z.write(p,p.relative_to(root.parent))
PY
cat "$OUT/RESULT.json"
