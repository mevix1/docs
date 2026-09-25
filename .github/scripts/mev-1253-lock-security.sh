#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/out/mev-1253-security"
INPUT="$ROOT/input/mev-1253"
rm -rf "$OUT" "$INPUT"
mkdir -p "$OUT" "$INPUT"

INPUT_ID="1wLZEZCZD-e1Kf58dhm44DKrqPgb-xKSa"
INPUT_SHA="205470d4dbc02a19c893255777a23017d312600fdc26082986ac3127acc67e0c"
LOCK_SHA="058e79648f2a43f0d328d453a987fdde5044d943af11ad4898801b379760a943"
MANIFEST_SHA="e593e685b1ba961ce2977bf61bfab100bbe7a53e9aba31cab6ca14ebafeeb249"
UI_MANIFEST_SHA="6fa5ee7ddec1a1171c2bc315cf3e75399093590a8782a0e8755ab272b8002da6"
OSV_VERSION="2.6.0"
OSV_SHA="ca69b3d3cd08f889a49dc0a383122f71cc528b83803671df5fd874d97485b108"

capture() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT/${name}.stdout.log" 2>"$OUT/${name}.stderr.log"
  local code=$?
  set -e
  printf '%s\n' "$code" >"$OUT/${name}.exit"
  return 0
}

set -e
DOWNLOAD_URL="https://drive.usercontent.google.com/download?id=${INPUT_ID}&export=download&confirm=t"
capture input-download curl --fail --location --silent --show-error --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 "$DOWNLOAD_URL" --output "$OUT/input.zip"
DOWNLOAD_EXIT="$(cat "$OUT/input-download.exit")"
if [[ "$DOWNLOAD_EXIT" == "0" ]]; then
  printf '%s  %s\n' "$INPUT_SHA" "$OUT/input.zip" | sha256sum -c - >"$OUT/input-sha.log" 2>&1 || true
  if grep -q ': OK$' "$OUT/input-sha.log"; then
    unzip -q "$OUT/input.zip" -d "$INPUT"
  fi
fi

IDENTITY_OK=false
if [[ -f "$INPUT/package-lock.json" && -f "$INPUT/package.json" && -f "$INPUT/packages/ui-web/package.json" ]]; then
  {
    sha256sum "$INPUT/package-lock.json"
    sha256sum "$INPUT/package.json"
    sha256sum "$INPUT/packages/ui-web/package.json"
  } > "$OUT/input-files.sha256"
  if [[ "$(sha256sum "$INPUT/package-lock.json" | awk '{print $1}')" == "$LOCK_SHA" \
     && "$(sha256sum "$INPUT/package.json" | awk '{print $1}')" == "$MANIFEST_SHA" \
     && "$(sha256sum "$INPUT/packages/ui-web/package.json" | awk '{print $1}')" == "$UI_MANIFEST_SHA" ]]; then
    IDENTITY_OK=true
  fi
fi
printf '%s\n' "$IDENTITY_OK" > "$OUT/input-identity.ok"

printf 'node=%s\n' "$(node --version 2>/dev/null || true)" > "$OUT/toolchain.txt"
printf 'npm-before=%s\n' "$(npm --version 2>/dev/null || true)" >> "$OUT/toolchain.txt"
if [[ "$IDENTITY_OK" == true ]]; then
  capture npm-tool npm install --global --ignore-scripts --no-audit --no-fund "npm@10.9.2"
  printf 'npm-after=%s\n' "$(npm --version 2>/dev/null || true)" >> "$OUT/toolchain.txt"

  capture osv-download curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
    "https://github.com/google/osv-scanner/releases/download/v${OSV_VERSION}/osv-scanner_linux_amd64" \
    --output "$OUT/osv-scanner"
  if [[ "$(cat "$OUT/osv-download.exit")" == "0" ]]; then
    chmod +x "$OUT/osv-scanner"
    printf '%s  %s\n' "$OSV_SHA" "$OUT/osv-scanner" | sha256sum -c - >"$OUT/osv-binary-sha.log" 2>&1 || true
  fi
  if grep -q ': OK$' "$OUT/osv-binary-sha.log" 2>/dev/null; then
    capture osv-version "$OUT/osv-scanner" --version
    capture osv-scan "$OUT/osv-scanner" scan --format json -L "$INPUT/package-lock.json"
    cp "$OUT/osv-scan.stdout.log" "$OUT/osv.json"
  fi

  (
    cd "$INPUT"
    capture npm-audit-all npm audit --package-lock-only --json --audit-level=low
    capture npm-audit-prod npm audit --package-lock-only --omit=dev --json --audit-level=low
  )
  cp "$OUT/npm-audit-all.stdout.log" "$OUT/npm-audit-all.json" 2>/dev/null || true
  cp "$OUT/npm-audit-prod.stdout.log" "$OUT/npm-audit-prod.json" 2>/dev/null || true
fi

python3 - "$OUT" "$IDENTITY_OK" <<'PY'
import json, hashlib, pathlib, sys
out=pathlib.Path(sys.argv[1]); identity_ok=sys.argv[2]=='true'

def read_exit(name):
    p=out/f'{name}.exit'
    try:return int(p.read_text().strip())
    except:return None

def load_json(name):
    p=out/name
    try:return json.loads(p.read_text()), None
    except Exception as e:return {}, f'{type(e).__name__}: {e}'

def sha(path):
    p=out/path
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None

osv, osv_err=load_json('osv.json')
osv_rows=[]
for result in osv.get('results') or []:
    source=result.get('source') or {}
    for item in result.get('packages') or []:
        pkg=item.get('package') or {}
        for vuln in item.get('vulnerabilities') or []:
            osv_rows.append({
              'package':pkg.get('name'),'version':pkg.get('version'),'ecosystem':pkg.get('ecosystem'),
              'osvId':vuln.get('id'),'aliases':vuln.get('aliases') or [],'summary':vuln.get('summary'),
              'published':vuln.get('published'),'modified':vuln.get('modified'),'withdrawn':vuln.get('withdrawn'),
              'severity':vuln.get('severity') or [],'databaseSpecific':vuln.get('database_specific') or {},
              'source':source,'reachability':'NOT_EVALUATED','dependabotAlertId':None,
              'candidateDisposition':'REQUIRES_AUTHORITATIVE_DEPENDABOT_RECORD_AND_REACHABILITY_REVIEW'
            })

def npm_summary(name):
    data, err=load_json(name)
    meta=((data.get('metadata') or {}).get('vulnerabilities') or {}) if isinstance(data,dict) else {}
    vulns=data.get('vulnerabilities') or {} if isinstance(data,dict) else {}
    rows=[]
    for pkg,v in sorted(vulns.items()):
        via=v.get('via') or [] if isinstance(v,dict) else []
        advisories=[]
        for x in via:
            if isinstance(x,dict):
                advisories.append({k:x.get(k) for k in ('source','name','dependency','title','url','severity','range')})
        rows.append({
          'package':pkg,'severity':v.get('severity'),'isDirect':v.get('isDirect'),
          'range':v.get('range'),'nodes':v.get('nodes') or [],'effects':v.get('effects') or [],
          'fixAvailable':v.get('fixAvailable'),'advisories':advisories,
          'reachability':'NOT_EVALUATED','dependabotAlertId':None
        })
    return {'parseError':err,'metadata':meta,'rows':rows,'jsonSha256':sha(name)}

npm_all=npm_summary('npm-audit-all.json')
npm_prod=npm_summary('npm-audit-prod.json')
osv_exit=read_exit('osv-scan'); npm_all_exit=read_exit('npm-audit-all'); npm_prod_exit=read_exit('npm-audit-prod')
osv_ok=identity_ok and osv_exit in (0,1) and osv_err is None
npm_ok=identity_ok and npm_all_exit in (0,1) and npm_prod_exit in (0,1) and npm_all['parseError'] is None and npm_prod['parseError'] is None
status='PASS_LOCK_BOUND_AUXILIARY_SECURITY_READBACK' if osv_ok and npm_ok else 'BLOCKED_AUXILIARY_SECURITY_EXECUTION'
result={
 'schema':'mevix.mev-1253.lock-bound-security-readback.v1','date':'2026-09-25','status':status,
 'candidate':{'commit':'786f9ada1889afc92aa3f7d6fefcd0022eec4fa4','tree':'9c0276f17b64e0a3b021df16ca5985acf7695105','lockSha256':'058e79648f2a43f0d328d453a987fdde5044d943af11ad4898801b379760a943','identityVerified':identity_ok},
 'scanners':{
   'osv':{'version':(out/'osv-version.stdout.log').read_text(errors='replace').strip() if (out/'osv-version.stdout.log').exists() else None,'binarySha256':sha('osv-scanner'),'exit':osv_exit,'parseError':osv_err,'matchRows':len(osv_rows),'uniqueIds':len({r['osvId'] for r in osv_rows if r['osvId']}),'jsonSha256':sha('osv.json')},
   'npmAuditAll':{'exit':npm_all_exit,**npm_all},'npmAuditProd':{'exit':npm_prod_exit,**npm_prod},
 },
 'osvRegistry':osv_rows,
 'authority':{'dependabotRecordsAvailable':False,'dependabotAuthority':False,'githubReportedAggregateConfirmed':False,'releaseSecurityVerdict':'PENDING_AUTHORITATIVE_DEPENDABOT_RECORDS','canCloseMEV1253':False,'canApproveRelease':False},
 'boundaries':{'advisoryMatchingOnly':True,'reachabilityEvaluated':False,'sourceChanged':False,'lockChanged':False,'productInstallRun':False,'npmAuditFixRun':False,'blindUpgradeRun':False,'runnerToolInstallOnly':True}
}
(out/'RESULT.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
(out/'AUXILIARY-REGISTRY.json').write_text(json.dumps({'osv':osv_rows,'npmAuditAll':npm_all['rows'],'npmAuditProd':npm_prod['rows']},indent=2,sort_keys=True)+'\n')
md=f'''# MEV-1253 · exact-candidate auxiliary security readback

`{status}`

```text
commit  786f9ada1889afc92aa3f7d6fefcd0022eec4fa4
tree    9c0276f17b64e0a3b021df16ca5985acf7695105
lock    058e79648f2a43f0d328d453a987fdde5044d943af11ad4898801b379760a943
identity verified  {identity_ok}
OSV rows / IDs     {len(osv_rows)} / {len({r['osvId'] for r in osv_rows if r['osvId']})}
npm audit all      {npm_all.get('metadata')}
npm audit prod     {npm_prod.get('metadata')}
```

This is a read-only, lock-bound auxiliary advisory inventory. It is not GitHub Dependabot alert authority and does not establish reachability or final release disposition. MEV-1253 remains open until authorized Dependabot records provide alert IDs, timestamps, paths and dismissal state. No product source, lock or installed workspace was changed.
'''
(out/'REPORT.md').write_text(md)
PY

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
python3 - "$OUT/RESULT.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); print(json.dumps(r,indent=2,sort_keys=True))
raise SystemExit(0 if r['status']=='PASS_LOCK_BOUND_AUXILIARY_SECURITY_READBACK' else 1)
PY
