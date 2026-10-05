// Standalone regression test: no pub resolution, generators, or compiler installs.
import '../lib/src/toolchain.dart';

void expectEqual(Object? actual, Object? expected, String name) {
  if (actual != expected) {
    throw StateError('$name: expected $expected, got $actual');
  }
}

void main() {
  expectEqual(selectRustToolchain('stable', {}), 'stable', 'default stable');
  expectEqual(
      selectRustToolchain('nightly', {}), 'nightly', 'configured fallback');
  expectEqual(
    selectRustToolchain('stable', {'CARGOKIT_RUST_TOOLCHAIN': '1.98.1'}),
    '1.98.1',
    'explicit pinned version',
  );
  expectEqual(
    selectRustToolchain('nightly', {'CARGOKIT_RUST_TOOLCHAIN': '1.98.1'}),
    '1.98.1',
    'override takes precedence',
  );
  expectEqual(
    selectRustToolchain('stable', {'CARGOKIT_RUST_TOOLCHAIN': '   '}),
    'stable',
    'empty override preserves fallback',
  );
  expectEqual(
    selectRustToolchain('stable', {'CARGOKIT_RUST_TOOLCHAIN': ' 1.98.1 '}),
    '1.98.1',
    'trim override',
  );
  for (final name in [
    'stable-x86_64-pc-windows-msvc (default)',
    'beta-aarch64-apple-darwin',
    'nightly-2026-09-01-x86_64-unknown-linux-gnu',
    '1.98.1-x86_64-unknown-linux-gnu (active)',
    '1.98.1-aarch64-apple-darwin',
    '1.98.1-x86_64-pc-windows-msvc',
    '1.98.1',
  ]) {
    expectEqual(isStandardRustToolchain(name), true, 'recognize $name');
  }
  for (final name in ['', 'custom-toolchain', 'stabler-custom', '1bad']) {
    expectEqual(isStandardRustToolchain(name), false, 'reject $name');
  }
  print('17 Cargokit toolchain checks passed');
}
