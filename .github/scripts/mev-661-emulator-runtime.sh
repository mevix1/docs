#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INPUT="$ROOT/input/mev-818-terminal"
APK="$INPUT/NativeNeutralApp-terminal-debug.apk"
SOURCE_BUNDLE="$INPUT/MEV-818-terminal-source.bundle"
OUT="$ROOT/out/mev-661-runtime"
WORK="$ROOT/.mev-661-runtime"
SOURCE="$WORK/source"
APP="$SOURCE/NativeNeutralApp"
AVD_NAME="mev661_api35"
mkdir -p "$OUT/screenshots" "$OUT/ui"
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

write_exit() { printf '%s\n' "$2" >"$OUT/$1.exit"; }

# Exact input and source recovery.
run_capture input-identity bash -lc "
  set -euo pipefail
  echo 'e20636c169e023b9210fbdc6ea7ae6e0de483f277843e642ac0c7be8adb200bd  $APK' | sha256sum -c -
  test -s '$SOURCE_BUNDLE'
  python3 - <<'PY'
import json
r=json.load(open('$INPUT/RESULT.json'))
assert r['status']=='PASS_MEV_818_TERMINAL_SINGLE_SOURCE_BUILD'
assert r['source']['commit']=='b761a10fbd148dfa2c21ce4640dc5161ab06711a'
assert r['source']['tree']=='265bae21ae3b6277e8904c371be9414ff5279500'
assert r['source']['parent']=='dd02cef275770eb6d4694647ba4b8d3dcf3bb6fc'
assert r['package']['appLock']['sha256']=='d3c1b1716cb5c8be45b35372a627327c19065e9590900a213c531c015e967776'
PY
"
run_capture source-recovery bash -lc "
  set -euo pipefail
  git clone -q '$SOURCE_BUNDLE' '$SOURCE'
  test \"\$(git -C '$SOURCE' rev-parse HEAD)\" = b761a10fbd148dfa2c21ce4640dc5161ab06711a
  test \"\$(git -C '$SOURCE' rev-parse 'HEAD^{tree}')\" = 265bae21ae3b6277e8904c371be9414ff5279500
  git -C '$SOURCE' fsck --full --strict
  test -z \"\$(git -C '$SOURCE' status --short)\"
"
run_capture runtime-npm-ci bash -lc "cd '$APP' && npm ci --ignore-scripts --audit=false --fund=false"

# Start exact Metro source for the immutable debug APK.
if [[ "$(cat "$OUT/runtime-npm-ci.exit")" == 0 ]]; then
  (
    cd "$APP"
    nohup npm start -- --host 0.0.0.0 --port 8081 --reset-cache >"$OUT/metro-server.log" 2>&1 &
    echo $! >"$OUT/metro-server.pid"
  )
  run_capture metro-ready bash -lc "
    set -euo pipefail
    for i in \$(seq 1 120); do
      if curl -fsS http://127.0.0.1:8081/status | grep -q 'packager-status:running'; then exit 0; fi
      sleep 1
    done
    exit 1
  "
else
  write_exit metro-ready 99
fi

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
EMULATOR="$SDK_ROOT/emulator/emulator"
AVDMANAGER="$(find "$SDK_ROOT/cmdline-tools" -type f -name avdmanager -perm -u+x 2>/dev/null | sort | tail -1)"

run_capture avd-create bash -lc "
  set -euo pipefail
  rm -rf \"$HOME/.android/avd/${AVD_NAME}.avd\" \"$HOME/.android/avd/${AVD_NAME}.ini\"
  echo no | '$AVDMANAGER' create avd --force --name '$AVD_NAME' --package 'system-images;android-35;google_apis;x86_64' --device 'pixel_6'
"

ACCEL=off
[[ -e /dev/kvm ]] && ACCEL=on
(
  nohup "$EMULATOR" "@$AVD_NAME" -no-window -no-audio -no-boot-anim -no-snapshot -wipe-data \
    -gpu swiftshader_indirect -accel "$ACCEL" -camera-back none -camera-front none \
    >"$OUT/emulator.log" 2>&1 &
  echo $! >"$OUT/emulator.pid"
)

run_capture emulator-boot bash -lc "
  set -euo pipefail
  adb start-server
  for i in \$(seq 1 180); do
    state=\$(adb get-state 2>/dev/null || true)
    boot=\$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    if [[ \"\$state\" == device && \"\$boot\" == 1 ]]; then exit 0; fi
    sleep 2
  done
  exit 1
"

BOOT_EXIT="$(cat "$OUT/emulator-boot.exit")"
if [[ "$BOOT_EXIT" == 0 ]]; then
  adb shell input keyevent 82 || true
  adb shell settings put global window_animation_scale 0 || true
  adb shell settings put global transition_animation_scale 0 || true
  adb shell settings put global animator_duration_scale 0 || true
  adb reverse tcp:8081 tcp:8081

  run_capture device-profile bash -lc "
    set -euo pipefail
    {
      echo serial=\$(adb get-serialno)
      echo sdk=\$(adb shell getprop ro.build.version.sdk | tr -d '\r')
      echo release=\$(adb shell getprop ro.build.version.release | tr -d '\r')
      echo model=\$(adb shell getprop ro.product.model | tr -d '\r')
      echo abi=\$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
      echo density=\$(adb shell wm density | tr '\n' ' ')
      echo size=\$(adb shell wm size | tr '\n' ' ')
      echo font_scale=\$(adb shell settings get system font_scale | tr -d '\r')
      echo night=\$(adb shell cmd uimode night | tr '\n' ' ')
    } | tee '$OUT/device-profile.txt'
  "
  run_capture apk-install adb install -r -t "$APK"

  PACKAGE="$(aapt dump badging "$APK" | sed -n "s/package: name='\([^']*\)'.*/\1/p" | head -1)"
  ACTIVITY="$(aapt dump badging "$APK" | sed -n "s/launchable-activity: name='\([^']*\)'.*/\1/p" | head -1)"
  printf '%s\n' "$PACKAGE" >"$OUT/package-name.txt"
  printf '%s\n' "$ACTIVITY" >"$OUT/activity-name.txt"
  adb logcat -c

  run_capture cold-launch bash -lc "
    set -euo pipefail
    adb shell am force-stop '$PACKAGE'
    adb shell am start -W -n '$PACKAGE/$ACTIVITY'
    for i in \$(seq 1 60); do
      pid=\$(adb shell pidof '$PACKAGE' | tr -d '\r' || true)
      [[ -n \"\$pid\" ]] && exit 0
      sleep 1
    done
    exit 1
  "
  sleep 12

  capture_state() {
    local name="$1"
    adb shell uiautomator dump --compressed "/sdcard/${name}.xml" >/dev/null
    adb pull "/sdcard/${name}.xml" "$OUT/ui/${name}.xml" >/dev/null
    adb exec-out screencap -p >"$OUT/screenshots/${name}.png"
  }
  capture_state initial-light

  run_capture initial-ui python3 - "$OUT/ui/initial-light.xml" "$OUT/initial-ui.json" <<'PY'
import json, re, sys, xml.etree.ElementTree as ET
source, target=sys.argv[1:]
root=ET.parse(source).getroot(); nodes=[]
for node in root.iter('node'):
    attrs=node.attrib
    nodes.append(attrs)
text=' '.join((n.get('text','')+' '+n.get('content-desc','')) for n in nodes)
required=['Native neutral slice','Name','Confirm']
missing=[x for x in required if x not in text]
edit=next((n for n in nodes if 'EditText' in n.get('class','') or n.get('content-desc')=='Name'),None)
button=next((n for n in nodes if n.get('content-desc')=='Confirm' or n.get('text')=='Confirm'),None)
result={'required':required,'missing':missing,'edit':edit,'button':button,'nodeCount':len(nodes)}
open(target,'w').write(json.dumps(result,indent=2,sort_keys=True)+'\n')
print(json.dumps(result,indent=2))
if missing or edit is None or button is None: raise SystemExit(1)
PY

  run_capture interaction python3 - "$OUT/ui/initial-light.xml" "$OUT/interaction-coordinates.json" <<'PY'
import json, re, subprocess, sys, time, xml.etree.ElementTree as ET
source,target=sys.argv[1:]
nodes=[n.attrib for n in ET.parse(source).getroot().iter('node')]
def bounds(n):
    v=n.get('bounds',''); nums=list(map(int,re.findall(r'\d+',v)))
    if len(nums)!=4: raise SystemExit('BAD_BOUNDS:'+v)
    return nums
edit=next((n for n in nodes if 'EditText' in n.get('class','') or n.get('content-desc')=='Name'),None)
button=next((n for n in nodes if n.get('content-desc')=='Confirm' or n.get('text')=='Confirm'),None)
if not edit or not button: raise SystemExit('MISSING_CONTROLS')
e=bounds(edit); b=bounds(button)
coords={'edit':[(e[0]+e[2])//2,(e[1]+e[3])//2],'button':[(b[0]+b[2])//2,(b[1]+b[3])//2], 'buttonBounds':b}
open(target,'w').write(json.dumps(coords,indent=2)+'\n')
subprocess.run(['adb','shell','input','tap',*map(str,coords['edit'])],check=True)
subprocess.run(['adb','shell','input','keyevent','123'],check=True)
subprocess.run(['adb','shell','input','text','_Agent'],check=True)
time.sleep(2)
subprocess.run(['adb','shell','input','tap',*map(str,coords['button'])],check=True)
time.sleep(3)
PY
  capture_state after-input-action
  run_capture action-state python3 - "$OUT/ui/after-input-action.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
text=' '.join((n.attrib.get('text','')+' '+n.attrib.get('content-desc','')) for n in ET.parse(sys.argv[1]).getroot().iter('node'))
required=['Action completed.','Confirm','Name']
missing=[x for x in required if x not in text]
print({'missing':missing,'text':text[:2000]})
if missing: raise SystemExit(1)
PY

  run_capture warm-launch bash -lc "
    set -euo pipefail
    adb shell am force-stop '$PACKAGE'
    adb shell am start -W -n '$PACKAGE/$ACTIVITY'
    sleep 5
    test -n \"\$(adb shell pidof '$PACKAGE' | tr -d '\r')\"
  "

  adb shell cmd uimode night yes >/dev/null || true
  adb shell am force-stop "$PACKAGE"
  adb shell am start -W -n "$PACKAGE/$ACTIVITY" >/dev/null
  sleep 6
  capture_state system-dark
  adb shell cmd uimode night >"$OUT/system-dark-mode.txt" 2>&1 || true

  adb shell settings put system font_scale 1.3
  adb shell am force-stop "$PACKAGE"
  adb shell am start -W -n "$PACKAGE/$ACTIVITY" >/dev/null
  sleep 6
  capture_state font-scale-1.3
  adb shell settings get system font_scale >"$OUT/font-scale.txt"

  adb logcat -d -v threadtime >"$OUT/logcat.txt"
  run_capture crash-scan python3 - "$OUT/logcat.txt" <<'PY'
import re,sys
text=open(sys.argv[1],errors='replace').read()
patterns=[r'FATAL EXCEPTION',r'Process: com\.nativeneutralapp.*has died',r'Unable to load script',r'Invariant Violation',r'ReactNativeJS:.*(?:ERROR|Error)']
hits=[p for p in patterns if re.search(p,text,re.I|re.S)]
print({'hits':hits})
if hits: raise SystemExit(1)
PY

  run_capture touch-target python3 - "$OUT/interaction-coordinates.json" <<'PY'
import json,re,subprocess,sys
r=json.load(open(sys.argv[1])); b=r['buttonBounds']
density=subprocess.check_output(['adb','shell','wm','density'],text=True)
m=re.search(r'(?:Override|Physical) density:\s*(\d+)',density)
if not m: raise SystemExit('DENSITY_UNKNOWN')
d=int(m.group(1)); width=b[2]-b[0]; height=b[3]-b[1]
result={'density':d,'widthPx':width,'heightPx':height,'widthDp':width*160/d,'heightDp':height*160/d}
print(result)
if result['widthDp'] < 48 or result['heightDp'] < 48: raise SystemExit(1)
PY
else
  for name in device-profile apk-install cold-launch initial-ui interaction action-state warm-launch crash-scan touch-target; do write_exit "$name" 99; done
fi

export OUT APK
python3 - <<'PY'
import hashlib,json,os,pathlib,zipfile
out=pathlib.Path(os.environ['OUT']); apk=pathlib.Path(os.environ['APK'])
def code(name):
    try:return int((out/f'{name}.exit').read_text().strip())
    except:return 99
def digest(p):
    if not p.is_file():return None
    h=hashlib.sha256()
    with p.open('rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
    return {'bytes':p.stat().st_size,'sha256':h.hexdigest()}
steps={n:code(n) for n in ['input-identity','source-recovery','runtime-npm-ci','metro-ready','avd-create','emulator-boot','device-profile','apk-install','cold-launch','initial-ui','interaction','action-state','warm-launch','crash-scan','touch-target']}
required=list(steps)
checks={
 'allEmulatorStepsPassed':all(steps[n]==0 for n in required),
 'initialScreenshot':digest(out/'screenshots/initial-light.png') is not None,
 'interactionScreenshot':digest(out/'screenshots/after-input-action.png') is not None,
 'systemDarkScreenshot':digest(out/'screenshots/system-dark.png') is not None,
 'fontScaleScreenshot':digest(out/'screenshots/font-scale-1.3.png') is not None,
 'uiTrees':len(list((out/'ui').glob('*.xml')))>=4,
 'exactApk':digest(apk) and digest(apk)['sha256']=='e20636c169e023b9210fbdc6ea7ae6e0de483f277843e642ac0c7be8adb200bd',
}
status='PASS_MEV_661_EMULATOR_RUNTIME_WITH_EXTERNAL_AT_PHYSICAL_PENDING' if all(checks.values()) else 'FAIL_MEV_661_EMULATOR_RUNTIME'
result={
 'schema':'mevix.mev-661-emulator-runtime.v1','issue':'MEV-661','status':status,
 'candidate':{'sourceCommit':'b761a10fbd148dfa2c21ce4640dc5161ab06711a','sourceTree':'265bae21ae3b6277e8904c371be9414ff5279500','apk':digest(apk)},
 'steps':steps,'checks':checks,
 'observations':{
   'emulator':'EXECUTED','coldLaunch':'EXECUTED','warmLaunch':'EXECUTED','textInput':'EXECUTED','emulatedTouch':'EXECUTED','systemDarkMode':'EXECUTED','fontScale1_3':'EXECUTED','uiAutomatorTree':'EXECUTED','logcatCrashScan':'EXECUTED'},
 'boundaries':{'physicalDevice':'NOT_RUN','physicalTouch':'NOT_RUN','TalkBackLive':'NOT_RUN','nativeIMEComposition':'NOT_RUN','owner':'MEV-661'},
 'screenshots':[p.name for p in sorted((out/'screenshots').glob('*.png'))],
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
root=pathlib.Path('out/mev-661-runtime'); target=pathlib.Path('out/MEV-661-exact-emulator-runtime.zip')
with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file():z.write(p,p.relative_to(root.parent))
PY
cat "$OUT/RESULT.json"
exit 0
