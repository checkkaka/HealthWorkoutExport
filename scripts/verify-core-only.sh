#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${1:-$ROOT/rust/workout_core}
OUT=${2:-$(mktemp -d "${TMPDIR:-/tmp}/health-core-only.XXXXXX")}
export CARGO_NET_OFFLINE=true
python3 - "$SOURCE" "$OUT" <<'PY'
from pathlib import Path
import hashlib, json, shutil, sys
source, out = (Path(p).resolve() for p in sys.argv[1:])
if source == out or source in out.parents or out in source.parents:
    raise SystemExit('Output must be a separate temporary directory outside the source tree')
(out/'src').mkdir(parents=True, exist_ok=True)
manifest = {'source': 'rust/workout_core (source path provided to script)', 'exclusions': ['src/api/**', 'src/frb_generated.rs', 'lib.rs mod api declaration', 'lib.rs #[allow(unsafe_code)] mod frb_generated declaration'], 'source_sha256': {}}
for name in ['Cargo.toml', 'Cargo.lock']:
    shutil.copy2(source/name, out/name)
for file in sorted((source/'src').glob('*.rs')):
    if file.name == 'frb_generated.rs': continue
    data = file.read_bytes()
    manifest['source_sha256'][file.name] = hashlib.sha256(data).hexdigest()
    if file.name == 'lib.rs':
        data = data.replace(b'mod api;\n', b'').replace(b'#[allow(unsafe_code)]\nmod frb_generated;\n', b'')
    (out/'src'/file.name).write_bytes(data)
(out/'source-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
(out/'EXCLUSIONS.txt').write_text('CORE-ONLY verification. API wrappers, FFI bindings, and all api module tests are excluded.\nOnly module declarations are removed from copied lib.rs. Main repository is not modified.\nCargo.toml and Cargo.lock are unchanged. No code generation or network dependency access.\n')
PY
cargo test --offline --locked --manifest-path "$OUT/Cargo.toml" --lib 2>&1 | tee "$OUT/test.log"
cargo clippy --offline --locked --manifest-path "$OUT/Cargo.toml" --all-targets -- -D warnings 2>&1 | tee "$OUT/clippy.log"
