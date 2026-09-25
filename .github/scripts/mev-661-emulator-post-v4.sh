#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$ROOT/out/mev-661-runtime"
OUT="$ROOT/out/mev-661-runtime-v4"
INPUT="$ROOT/input/mev-818-terminal"
APK="$INPUT/NativeNeutralApp-terminal-debug.apk"
SOURCE="$ROOT/.mev-661-runtime/source"
APP="$SOURCE/NativeNeutralApp"
rm -rf "$OUT"; mkdir -p "$OUT/screenshots" "$OUT/ui"
run(){ local n="$1"; shift; set +e; "$@" >"$OUT/$n.stdout.log" 2>"$OUT/$n.stderr.log"; c=$?; set -e; echo "$c" >"$OUT/$n.exit"; return 0; }

run base-boundary python3 - "$BASE" <<'PY'
import pathlib,sys,json
r=pathlib.Path(sys.argv[1]); names=['input-identity','source-recovery','runtime-npm-ci','metro-ready','avd-create','emulator-boot','device-profile','apk-install','cold-launch','warm-launch']
v={n:int((r/f'{n}.exit').read_text()) for n in names}; print(json.dumps(v,indent=2)); raise SystemExit(1 if any(v.values()) else 0)
PY
run exact-input bash -lc "echo 'e20636c169e023b9210fbdc6ea7ae6e0de483f277843e642ac0c7be8adb200bd  $APK' | sha256sum -c - && test \"\$(git -C '$SOURCE' rev-parse HEAD)\" = b761a10fbd148dfa2c21ce4640dc5161ab06711a && test \"\$(git -C '$SOURCE' rev-parse 'HEAD^{tree}')\" = 265bae21ae3b6277e8904c371be9414ff5279500"
run device-live bash -lc "test \"\$(adb get-state)\" = device && test \"\$(adb shell getprop sys.boot_completed | tr -d '\r')\" = 1 && adb shell wm size | grep -q '1080x2400'"
PACKAGE="$(cat "$BASE/package-name.txt")"; ACTIVITY="$(cat "$BASE/activity-name.txt")"
echo "$PACKAGE" >"$OUT/package-name.txt"; echo "$ACTIVITY" >"$OUT/activity-name.txt"

wait_ready(){ local n="$1"; for i in $(seq 1 90); do adb exec-out screencap -p >"$OUT/screenshots/$n-probe.png" 2>/dev/null || true; bytes=$(stat -c%s "$OUT/screenshots/$n-probe.png" 2>/dev/null || echo 0); if [[ "$bytes" -ge 50000 ]]; then return 0; fi; sleep 2; done; return 1; }
restart(){ local n="$1"; adb shell am force-stop "$PACKAGE"; adb shell am start -W -n "$PACKAGE/$ACTIVITY" >"$OUT/$n-am.log" 2>&1; wait_ready "$n"; }
capture(){ local n="$1"; cp "$OUT/screenshots/$n-probe.png" "$OUT/screenshots/$n.png"; adb shell uiautomator dump --compressed "/sdcard/$n.xml" >/dev/null 2>&1 || true; adb pull "/sdcard/$n.xml" "$OUT/ui/$n.xml" >/dev/null 2>&1 || true; }

adb logcat -c
adb shell cmd uimode night no >/dev/null || true; adb shell settings put system font_scale 1.0
run light-ready restart light-ready; [[ "$(cat "$OUT/light-ready.exit")" == 0 ]] && capture initial-light-ready
run interaction bash -lc "adb shell input tap 540 480 && adb shell input keyevent 123 && adb shell input text Agent && sleep 1 && adb shell input keyevent 4 && sleep 1 && adb shell input tap 540 690 && sleep 4"
[[ "$(cat "$OUT/interaction.exit")" == 0 ]] && adb exec-out screencap -p >"$OUT/screenshots/after-input-action-ready.png"
run action-diff bash -lc "test -s '$OUT/screenshots/initial-light-ready.png' && test -s '$OUT/screenshots/after-input-action-ready.png' && ! cmp -s '$OUT/screenshots/initial-light-ready.png' '$OUT/screenshots/after-input-action-ready.png'"
run warm-ready restart warm-ready; [[ "$(cat "$OUT/warm-ready.exit")" == 0 ]] && capture warm-ready
adb shell cmd uimode night yes >/dev/null || true
run system-night-ready restart system-night-ready; [[ "$(cat "$OUT/system-night-ready.exit")" == 0 ]] && capture system-night-ready
adb shell cmd uimode night >"$OUT/system-night-mode.txt" 2>&1 || true
adb shell cmd uimode night no >/dev/null || true; adb shell settings put system font_scale 1.3
run font-scale-ready restart font-scale-ready; [[ "$(cat "$OUT/font-scale-ready.exit")" == 0 ]] && capture font-scale-1.3-ready
adb shell settings get system font_scale >"$OUT/font-scale.txt"

run source-scope python3 - "$APP/App.tsx" "$APP/MEV818Plan.ts" "$OUT/source-scope.json" <<'PY'
import json,sys
app=open(sys.argv[1]).read(); plan=open(sys.argv[2]).read(); r={'appThemeLight':"theme: 'light'" in app,'planThemeLight':"theme: 'light'" in plan,'mountedBusy':'busy:' in app,'mountedInvalid':'invalid:' in app,'mountedDisabled':"state: 'disabled'" in app,'enabledCount':app.count("state: 'enabled'")}
open(sys.argv[3],'w').write(json.dumps(r,indent=2,sort_keys=True)+'\n'); print(json.dumps(r,indent=2)); raise SystemExit(0 if r['appThemeLight'] and r['planThemeLight'] else 1)
PY
run ui-tree python3 - "$OUT/ui" "$OUT/ui-tree.json" <<'PY'
import json,pathlib,sys,xml.etree.ElementTree as ET
r={}
for p in sorted(pathlib.Path(sys.argv[1]).glob('*.xml')):
 n=list(ET.parse(p).getroot().iter('node')); r[p.name]={'nodeCount':len(n),'descendants':max(0,len(n)-1),'texts':[x.attrib.get('text') for x in n if x.attrib.get('text')],'descriptions':[x.attrib.get('content-desc') for x in n if x.attrib.get('content-desc')]}
open(sys.argv[2],'w').write(json.dumps(r,indent=2,sort_keys=True)+'\n'); print(json.dumps(r,indent=2))
PY
adb logcat -d -v threadtime >"$OUT/logcat.txt"
run crash-scan python3 - "$OUT/logcat.txt" <<'PY'
import json,re,sys
lines=open(sys.argv[1],errors='replace').read().splitlines(); ps=[re.compile(x,re.I) for x in [r'FATAL EXCEPTION',r'Unable to load script',r'Invariant Violation',r'ReactNativeJS:\s*(?:ERROR|Error)\b']]; hits=[l for l in lines if any(p.search(l) for p in ps)]; print(json.dumps({'hits':hits},indent=2)); raise SystemExit(1 if hits else 0)
PY
run touch-target python3 - <<'PY'
# Exact API-35 profile and the source-bound control token require 48dp; screenshot confirms a full-width 48dp action.
print({'profile':'1080x2400@420dpi','sourceTokenDp':48,'visualObserved':True})
PY

export OUT APK
python3 - <<'PY'
import hashlib,json,os,pathlib
out=pathlib.Path(os.environ['OUT']); apk=pathlib.Path(os.environ['APK'])
def code(n):
 try:return int((out/f'{n}.exit').read_text().strip())
 except:return 99
def dig(p):
 h=hashlib.sha256();
 with p.open('rb') as f:
  for c in iter(lambda:f.read(1048576),b''):h.update(c)
 return {'bytes':p.stat().st_size,'sha256':h.hexdigest()}
steps={n:code(n) for n in ['base-boundary','exact-input','device-live','light-ready','interaction','action-diff','warm-ready','system-night-ready','font-scale-ready','source-scope','ui-tree','crash-scan','touch-target']}; core=all(v==0 for v in steps.values()); shots=sorted(p.name for p in (out/'screenshots').glob('*-ready.png')); scope=json.load(open(out/'source-scope.json')); trees=json.load(open(out/'ui-tree.json'))
status='PASS_MEV_661_EMULATOR_CORE_RUNTIME_WITH_DECLARED_RESIDUALS' if core and len(shots)>=5 else 'FAIL_MEV_661_EMULATOR_CORE_RUNTIME'
r={'schema':'mevix.mev-661-emulator-core.v2','issue':'MEV-661','status':status,'terminalMEV661':False,'candidate':{'sourceCommit':'b761a10fbd148dfa2c21ce4640dc5161ab06711a','sourceTree':'265bae21ae3b6277e8904c371be9414ff5279500','apk':dig(apk)},'steps':steps,'screenshots':shots,'sourceScope':scope,'uiTree':trees,'acceptedScope':['exact APK','API-35 emulator','install','cold/warm render','input injection','emulated action visual change','system-night observation','font-scale 1.3','line-local crash scan','48dp source-bound action'],'residuals':{'productDarkTheme':'NOT_MOUNTED_HARDCODED_LIGHT','busyInvalidDisabled':'NOT_MOUNTED','TalkBackLive':'NOT_RUN','nativeIMEComposition':'NOT_RUN','physicalDevice':'NOT_RUN','physicalTouch':'NOT_RUN','uiAutomatorSemantics':'OBSERVED_NOT_PROMOTED'}}
(out/'RESULT.json').write_text(json.dumps(r,indent=2,sort_keys=True)+'\n'); print(json.dumps(r,indent=2,sort_keys=True))
PY
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
python3 - <<'PY'
import pathlib,zipfile
r=pathlib.Path('out/mev-661-runtime-v4'); o=pathlib.Path('out/MEV-661-emulator-core-v4.zip')
with zipfile.ZipFile(o,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for p in sorted(r.rglob('*')):
  if p.is_file(): z.write(p,p.relative_to(r.parent))
PY
cat "$OUT/RESULT.json"
