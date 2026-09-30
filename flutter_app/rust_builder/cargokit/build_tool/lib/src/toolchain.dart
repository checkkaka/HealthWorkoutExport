/// Honor a build-scoped toolchain pin without changing normal Cargokit defaults.
String selectRustToolchain(String fallback, Map<String, String> environment) {
  final override = environment['CARGOKIT_RUST_TOOLCHAIN']?.trim();
  return override == null || override.isEmpty ? fallback : override;
}

/// Include official versioned rustup installations as well as release channels.
/// Custom toolchains retain the vendored behavior of not being enumerated here.
bool isStandardRustToolchain(String name) => RegExp(
      r'^(stable|beta|nightly)(?:[-\s]|$)|^\d+\.\d+(?:\.\d+)?(?:[-\s]|$)',
    ).hasMatch(name);
