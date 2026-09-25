#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$ROOT/.github/scripts/mev-1997-build.sh"
EFFECTIVE="$ROOT/.github/scripts/.mev-1997-build-r2-effective.sh"
cp "$BASE" "$EFFECTIVE"
python3 - "$EFFECTIVE" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); text=p.read_text()
replacements={
'a54e8d08f5cbb1d2d769053a2902cfab4f0df739':'f54cd82421aff5921f141b935daab55bcba67226',
'5d0eeafed328f779e7d40878be5e5aafc8ea4499':'7e0c2bbf6afdbadd0cefcb00b496fe6a21c14d10',
'7431a95aa7e3299ec99ceee6fc98c5edd4e5bbd8f77d4a78a84c65ecabd4ecb6':'ea7f1f3821508e1d0b932451e5702496789acf4dfc6d84fec6e76ac57d96ee83',
"NativeNeutralApp/App.tsx|NativeNeutralApp/MEV818Plan.ts|NativeNeutralApp/mev818-tests/contract.test.ts|":"NativeNeutralApp/App.tsx|NativeNeutralApp/MEV818Plan.ts|NativeNeutralApp/jest.config.js|NativeNeutralApp/mev818-tests/contract.test.ts|",
}
for old,new in replacements.items():
    if old not in text: raise SystemExit('R2_PATCH_MARKER_MISSING:'+old)
    text=text.replace(old,new)
p.write_text(text)
PY
chmod +x "$EFFECTIVE"
set +e
bash "$EFFECTIVE"
status=$?
set -e
OUT="$ROOT/out/mev-1997-build"
if [[ -d "$OUT" ]]; then
  cp "$EFFECTIVE" "$OUT/EFFECTIVE-RUNNER-R2.sh"
  cat >"$OUT/RUNNER-R2.json" <<'JSON'
{
  "schema": "mevix.mev-1997-runner-r2.v1",
  "reason": "Generic Jest did not transform installed TypeScript package and incorrectly discovered the standalone tsx contract.",
  "repair": [
    "allow @ui-foundation/ui-native through Jest transformIgnorePatterns",
    "exclude mev818-tests from Jest because it is executed independently through tsx"
  ],
  "productRuntimeFilesChanged": false,
  "lockChanged": false,
  "supersedesRun": 36178053975
}
JSON
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
PY
fi
exit "$status"
