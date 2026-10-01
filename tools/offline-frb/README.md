# Audited offline FRB 2.12 generation adapter

This patch retains the official FRB 2.12 parser, API generation, wire codecs, and
content-hash algorithm. It replaces the process-launching adapter used by
`generate`. It is intentionally a constrained local build tool, not a general
replacement for all upstream FRB subcommands.

## Provenance

- Official crate: `flutter_rust_bridge_codegen` version `2.12.0`
- Source: <https://crates.io/crates/flutter_rust_bridge_codegen/2.12.0>
- Archive SHA256: `13823e8157bada9dc828d67cd23e4bcebcfffa9313175dacad0325fc3188940c`
- Embedded upstream Git revision: `62b9330ed2f900535e34d8443ff82dc54070579a`
- Upstream path: `frb_codegen`
- License: MIT, as recorded by the original crate manifest
- `source-manifest.json` identifies every changed source file and the patch hash
- `validation-manifest.json` identifies the compiled tool/test executables and
  evidence logs after verification

The patch adds the already project-pinned `sha2 = "=0.11.0"` dependency to verify
executable SHA256 fingerprints. Its locked dependency closure adds block-buffer
0.12.1, const-oid 0.10.2, cpufeatures 0.3.0, crypto-common 0.2.2, digest 0.11.3,
hybrid-array 0.4.14, and sha2 0.11.0. Two existing versions change because that
closure requires newer minimum versions: libc 0.2.153 to 0.2.189 and typenum
1.17.0 to 1.20.1. All other original locked package versions are preserved.
The constrained build declares Rust 1.88 as its minimum; this task uses 1.98.1.

## Restrictions

Before FRB resolves configuration or runs Cargo metadata, the adapter validates
configuration and all required tool fingerprints. It rejects:

- Dart, Flutter, FVM, shell, installer, and arbitrary Cargo commands
- `full_dep`/ffigen, build_runner, Dart fix/format, Rust format, automatic
  dependency upgrades, automatic `mod` insertion, additional C/dump outputs,
  watch mode, and `stop_on_error: false`
- Noncanonical/symlink executable paths, missing executables, invalid or
  mismatching SHA256 fingerprints, and inherited Rust compiler wrappers/flags
- Cargo configuration files in the working directory's ancestor chain or
  CARGO_HOME, preventing configuration-supplied wrappers and expansion options
- Freezed or JSON-serialization outputs that would require Dart generation,
  checked before the generated source files are written
- Failed metadata and nonzero cargo-expand exits, instead of generating an
  `UNKNOWN` library stem or consuming failed expansion output

The only direct child processes are:

1. The pinned Cargo executable: `metadata --format-version 1 --manifest-path
   <absolute manifest> --offline --locked`, preserving the full dependency graph
2. The pinned cargo-expand executable: `expand --lib --theme=none --ugly`, the
   original optional package/features arguments, plus `--offline --locked
   --color=never`

Child environments are cleared, then receive explicit Cargo/Rust paths,
CARGO_NET_OFFLINE=true, CARGO_HOME, a fixed toolchain/system PATH, and only normal
HOME/temp-directory values. Expansion additionally receives exactly
`RUSTFLAGS=--cfg frb_expand`. It never installs cargo-expand automatically.
Non-generate CLI commands are rejected. The public build-web wrapper also fails
immediately; the adapter is not intended as a general integration-library API.

The same native/web generation choice and FRB 2.12 runtime compatibility are
preserved. Formatting is intentionally skipped; resulting whitespace differences
are expected. The project must already contain its generated-output directory
and existing `mod frb_generated` declaration.

## Reproduce the tool build

Dependency preparation is a separate, explicitly approved step. Obtain the
exact official crate archive and locked dependencies first. Never let the
actual generation step fetch dependencies or install tools.

The following commands only extract, patch, compile, and run the inspected guard
tests. They do not generate application bindings. Set CARGO and RUSTC to direct
installed toolchain executables, not rustup proxy paths.

```sh
ARCHIVE=/path/to/flutter_rust_bridge_codegen-2.12.0.crate
SOURCE=/path/to/isolated/frb-offline-codegen-2.12.0
PATCH=/path/to/HealthWorkoutExport/tools/offline-frb/upstream.patch
export CARGO_HOME=/path/to/prepared/cargo-cache
export RUSTC=/path/to/pinned/toolchain/bin/rustc
CARGO=/path/to/pinned/toolchain/bin/cargo

printf '%s  %s\n' \
  13823e8157bada9dc828d67cd23e4bcebcfffa9313175dacad0325fc3188940c \
  "$ARCHIVE" | sha256sum --check --strict
mkdir -p "$SOURCE"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE"
(cd "$SOURCE" && patch --batch --fuzz=0 -p1 < "$PATCH")
CARGO_NET_OFFLINE=true "$CARGO" build --manifest-path "$SOURCE/Cargo.toml" \
  --offline --locked --bin flutter_rust_bridge_codegen
CARGO_NET_OFFLINE=true "$CARGO" test --manifest-path "$SOURCE/Cargo.toml" \
  --offline --locked --lib offline_guard_tests
```

Do not run the complete upstream test suite in this workflow: its integration
fixtures intentionally launch external SDK tools and generation operations.
The inspected `offline_guard_tests` are local policy/configuration/hash tests
and process-plan assertions; they never execute the generator or Cargo expansion.

## Approved generation interface

Generation must use a separate disposable copy/worktree of the exact reviewed
application source. Validate the tool source, compiled binary, input snapshot,
and configuration before executing the patched binary; review and validate its
output before adopting any generated files into the working tree.

The patched entry remains `generate --config-file <offline configuration>`.
It requires these environment variables, with independently reviewed literal
fingerprints, not fingerprints computed just-in-time from an untrusted binary:

- FRB_OFFLINE_CARGO and FRB_OFFLINE_CARGO_SHA256
- FRB_OFFLINE_CARGO_EXPAND and FRB_OFFLINE_CARGO_EXPAND_SHA256
- FRB_OFFLINE_RUSTC and FRB_OFFLINE_RUSTC_SHA256
- CARGO_HOME pointing to the prepared, configuration-free cache

Use the separately verified official cargo-expand 1.0.126 build. Every executable
path must be absolute and canonical. The preflight rehashes executable contents
before constructing each subprocess.

Offline configuration should state all disabled features explicitly and preserve
the project's original input, output, entrypoint class, and web setting. The
adapter also normalizes absent optional external-tool features to false and
requires stop_on_error=true.

## Verification boundaries

Cargo's offline option prevents Cargo's network dependency resolution. It is not
a sandbox for arbitrary build.rs scripts or procedural macros. The currently
pinned dependency and cargo-expand subprocess paths must remain reviewed, and
the existing execution sandbox remains in place. No firewall, network namespace,
or other security-control changes are part of this adapter.

cargo-expand 1.0.126 can itself return zero after Cargo produced nonempty partial
expanded output, even if compilation reported an error. Therefore successful
generation is not sufficient: require an offline/locked Cargo check of the
complete staged crate and the relevant Flutter contract tests before adoption.
Also verify expected API methods/types, Rust/Dart content hashes, version 2.12.0
markers, and every generated-file diff. Any unsupported capability or validation
failure stops adoption; do not silently substitute hand-edited wire bindings.

At initial delivery of this patch, generation has not been executed. The evidence
covers the adapter build and its inspected guard tests only.

## Verified project application

After source review and the 23 guard tests, the audited adapter generated exactly
five expected files in an isolated worktree of project commit `1cdaa8e`. All 56
public API functions had matching Dart wrappers; handwritten Rust/Dart inputs
were unchanged by generation. Standard Rust/Dart formatting was performed as a
separate verification step, with Dart analytics explicitly suppressed and no
package resolution. The staged application passed full Rust tests (174), strict
clippy, Flutter analysis, and the full Flutter suite (254), including seven new
actual FFI regression tests. Only those five verified generated outputs were
adopted; their final SHA256 values are in `generated-output-manifest.json`.

No original generator was rerun. The replacement stayed under normal execution
controls; this result does not promise that arbitrary future dependency build
scripts or proc macros are network-isolated. Validate new dependency changes
separately. The reviewed Android Health Connect scope is read/export/Strava only.
