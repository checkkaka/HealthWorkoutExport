#!/usr/bin/env bash
# Compile and test handwritten Rust APIs without generating or linking FFI bindings.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${1:-$ROOT/rust/workout_core}
OUT=${2:-$(mktemp -d "${TMPDIR:-/tmp}/health-rust-api.XXXXXX")}
export CARGO_NET_OFFLINE=true
python3 - "$SOURCE" "$OUT" <<'PY'
from pathlib import Path
import hashlib, json, shutil, sys
source, out = (Path(p).resolve() for p in sys.argv[1:])
if source == out or source in out.parents or out in source.parents:
    raise SystemExit('Output must be a separate temporary directory outside the source tree')
(out/'src').mkdir(parents=True, exist_ok=True)
for name in ['Cargo.toml', 'Cargo.lock']:
    shutil.copy2(source/name, out/name)
manifest = {'exclusions': ['src/frb_generated.rs', 'lib.rs generated module declaration'], 'source_sha256': {}}
for file in sorted((source/'src').rglob('*.rs')):
    if file.name == 'frb_generated.rs': continue
    data = file.read_bytes()
    relative = file.relative_to(source)
    manifest['source_sha256'][str(relative)] = hashlib.sha256(data).hexdigest()
    if file.name == 'lib.rs':
        data = data.replace(b'#[allow(unsafe_code)]\nmod frb_generated;\n', b'')
    destination = out/relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
(out/'source-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
(out/'EXCLUSIONS.txt').write_text('RUST-ONLY API verification. Handwritten src/api is retained; generated FFI and its module declaration are omitted only in this copy. Does NOT verify Dart, native ABI, serialization, or cross-language integration. No code generation. Main repository is unchanged.\n')
PY
cargo test --offline --locked --manifest-path "$OUT/Cargo.toml" 2>&1 | tee "$OUT/test.log"
