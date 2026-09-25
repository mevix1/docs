#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/out/mev-1253-security"
PAIRS="$ROOT/security/mev-1253-lock-pairs.tsv"
rm -rf "$OUT"
mkdir -p "$OUT"

PAIRS_SHA="9f2109fd0ee70bffcda3276a427813d130279664a590fae7e2e4f469d56185d2"
LOCK_SHA="058e79648f2a43f0d328d453a987fdde5044d943af11ad4898801b379760a943"
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
IDENTITY_OK=false
if [[ -f "$PAIRS" && "$(sha256sum "$PAIRS" | awk '{print $1}')" == "$PAIRS_SHA" ]]; then
  if grep -qx "# lock_sha256=${LOCK_SHA}" "$PAIRS"; then IDENTITY_OK=true; fi
fi
printf '%s\n' "$IDENTITY_OK" > "$OUT/input-identity.ok"
sha256sum "$PAIRS" > "$OUT/input-files.sha256" 2>/dev/null || true

python3 - "$PAIRS" "$OUT/osv-scanner-deps.json" "$OUT/PAIR-SCOPE.json" <<'PY'
import csv,json,pathlib,sys
src=pathlib.Path(sys.argv[1]); osv_out=pathlib.Path(sys.argv[2]); scope_out=pathlib.Path(sys.argv[3])
lines=[line for line in src.open() if not line.startswith('#')]
rows=list(csv.DictReader(lines,delimiter='\t'))
assert len(rows)==398, len(rows)
pairs=[]; scope={}
for r in rows:
    key=f"{r['name']}@{r['version']}"
    pairs.append({'package':{'name':r['name'],'version':r['version'],'ecosystem':'npm'}})
    scope[key]={'scope':r['scope'],'directKind':None if r['direct']=='-' else r['direct']}
osv_out.write_text(json.dumps({'results':[{'source':{'path':'package-lock.json','type':'lockfile'},'packages':pairs}]},separators=(',',':'))+'\n')
scope_out.write_text(json.dumps(scope,indent=2,sort_keys=True)+'\n')
PY

printf 'node=%s\n' "$(node --version 2>/dev/null || true)" > "$OUT/toolchain.txt"
printf 'python=%s\n' "$(python3 --version 2>/dev/null || true)" >> "$OUT/toolchain.txt"

if [[ "$IDENTITY_OK" == true ]]; then
  capture osv-download curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
    "https://github.com/google/osv-scanner/releases/download/v${OSV_VERSION}/osv-scanner_linux_amd64" \
    --output "$OUT/osv-scanner"
  if [[ "$(cat "$OUT/osv-download.exit")" == "0" ]]; then
    chmod +x "$OUT/osv-scanner"
    printf '%s  %s\n' "$OSV_SHA" "$OUT/osv-scanner" | sha256sum -c - >"$OUT/osv-binary-sha.log" 2>&1 || true
  fi
  if grep -q ': OK$' "$OUT/osv-binary-sha.log" 2>/dev/null; then
    capture osv-version "$OUT/osv-scanner" --version
    capture osv-scan "$OUT/osv-scanner" scan --format json --lockfile="osv-scanner:$OUT/osv-scanner-deps.json"
    cp "$OUT/osv-scan.stdout.log" "$OUT/osv.json"
  fi
fi

python3 - "$OUT" "$IDENTITY_OK" <<'PY'
import json,hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1]); identity_ok=sys.argv[2]=='true'

def read_exit(name):
    try:return int((out/f'{name}.exit').read_text().strip())
    except:return None

def load(name):
    try:return json.loads((out/name).read_text()),None
    except Exception as e:return {},f'{type(e).__name__}: {e}'

def sha(name):
    p=out/name
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None

scope,_=load('PAIR-SCOPE.json')
osv,err=load('osv.json')
rows=[]
for result in osv.get('results') or []:
    source=result.get('source') or {}
    for item in result.get('packages') or []:
        pkg=item.get('package') or {}
        key=f"{pkg.get('name')}@{pkg.get('version')}"
        sc=scope.get(key,{})
        for vuln in item.get('vulnerabilities') or []:
            rows.append({
              'package':pkg.get('name'),'version':pkg.get('version'),'ecosystem':pkg.get('ecosystem'),
              'scope':sc.get('scope'),'directKind':sc.get('directKind'),
              'osvId':vuln.get('id'),'aliases':sorted(set(vuln.get('aliases') or [])),
              'summary':vuln.get('summary'),'published':vuln.get('published'),'modified':vuln.get('modified'),
              'withdrawn':vuln.get('withdrawn'),'severity':vuln.get('severity') or [],
              'databaseSpecific':vuln.get('database_specific') or {},'source':source,
              'reachability':'NOT_EVALUATED','dependabotAlertId':None,
              'candidateDisposition':'REQUIRES_AUTHORITATIVE_DEPENDABOT_RECORD_AND_REACHABILITY_REVIEW'
            })
rows.sort(key=lambda r:(r.get('scope')!='prod',r.get('package') or '',r.get('version') or '',r.get('osvId') or ''))
exit_code=read_exit('osv-scan')
ok=identity_ok and exit_code in (0,1) and err is None
status='PASS_LOCK_BOUND_AUXILIARY_OSV_READBACK' if ok else 'BLOCKED_AUXILIARY_OSV_EXECUTION'
unique=sorted({r['osvId'] for r in rows if r.get('osvId')})
result={
 'schema':'mevix.mev-1253.lock-bound-osv-readback.v2','date':'2026-09-25','status':status,
 'candidate':{'commit':'786f9ada1889afc92aa3f7d6fefcd0022eec4fa4','tree':'9c0276f17b64e0a3b021df16ca5985acf7695105','lockSha256':'058e79648f2a43f0d328d453a987fdde5044d943af11ad4898801b379760a943','inventoryIdentityVerified':identity_ok,'exactOfficialPairs':398},
 'scanner':{'name':'OSV-Scanner','version':(out/'osv-version.stdout.log').read_text(errors='replace').strip() if (out/'osv-version.stdout.log').exists() else None,'binarySha256':sha('osv-scanner'),'exit':exit_code,'parseError':err,'jsonSha256':sha('osv.json')},
 'findings':{'matchRows':len(rows),'uniqueOsvIds':len(unique),'uniqueOsvIdList':unique,'prodScopeRows':sum(r.get('scope')=='prod' for r in rows),'devScopeRows':sum(r.get('scope')=='dev' for r in rows),'directRows':sum(bool(r.get('directKind')) for r in rows),'registry':rows},
 'authority':{'dependabotRecordsAvailable':False,'dependabotAuthority':False,'githubReportedAggregateConfirmed':False,'releaseSecurityVerdict':'PENDING_AUTHORITATIVE_DEPENDABOT_RECORDS','canCloseMEV1253':False,'canApproveRelease':False},
 'boundaries':{'advisoryMatchingOnly':True,'reachabilityEvaluated':False,'sourceChanged':False,'lockChanged':False,'productInstallRun':False,'npmAuditRun':False,'npmAuditFixRun':False,'blindUpgradeRun':False}
}
(out/'RESULT.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
(out/'AUXILIARY-REGISTRY.json').write_text(json.dumps(rows,indent=2,sort_keys=True)+'\n')
md=f'''# MEV-1253 · exact-candidate auxiliary OSV readback

`{status}`

```text
commit              786f9ada1889afc92aa3f7d6fefcd0022eec4fa4
tree                9c0276f17b64e0a3b021df16ca5985acf7695105
lock                058e79648f2a43f0d328d453a987fdde5044d943af11ad4898801b379760a943
exact package pairs  398
inventory verified  {identity_ok}
OSV rows / IDs       {len(rows)} / {len(unique)}
prod / dev rows      {sum(r.get('scope')=='prod' for r in rows)} / {sum(r.get('scope')=='dev' for r in rows)}
```

This is a read-only advisory match against the exact accepted lock inventory. It is not GitHub Dependabot alert authority and does not establish package reachability or final release disposition. MEV-1253 remains open until authorized Dependabot records provide alert IDs, timestamps, paths and dismissal state. No product source, lock, installation or remediation was changed or run.
'''
(out/'REPORT.md').write_text(md)
PY

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS ! -name osv-scanner -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
python3 - "$OUT/RESULT.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); print(json.dumps(r,indent=2,sort_keys=True))
raise SystemExit(0 if r['status']=='PASS_LOCK_BOUND_AUXILIARY_OSV_READBACK' else 1)
PY
