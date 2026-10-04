#!/usr/bin/env python3
"""Run production SecretStore's deterministic JVM tests without Android/Flutter.

Usage: python3 run_keep_vault_jvm_tests.py --jars /path/to/jars
The directory must contain Kotlin compiler/runtime 2.2.0 and its Maven runtime
 dependencies, JUnit 4.13.2, Hamcrest 1.3, and an Android API stub jar.
Only Android Keystore type signatures are substituted for compilation; tests use
real JVM AES-GCM and a synthetic SharedPreferences backend. This does not verify
Android embedding/Keystore/device behavior or replace native Gradle validation.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--jars", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = (root / "app/src/main/kotlin/com/checkkaka/health_workout_export/MainActivity.kt").read_text()
assert "interface SecretCipher" in source, "Keep transactional SecretStore is not implemented"
classes = source[source.index("internal interface SecretCipher"):]
imports = """package com.checkkaka.health_workout_export
import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.nio.charset.CodingErrorAction
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
"""
stubs = """package android.security.keystore
class KeyGenParameterSpec : java.security.spec.AlgorithmParameterSpec {
    class Builder(alias: String, purposes: Int) {
        fun setBlockModes(vararg modes: String): Builder = this
        fun setEncryptionPaddings(vararg paddings: String): Builder = this
        fun build(): KeyGenParameterSpec = KeyGenParameterSpec()
    }
}
object KeyProperties {
    const val KEY_ALGORITHM_AES = "AES"
    const val PURPOSE_ENCRYPT = 1
    const val PURPOSE_DECRYPT = 2
    const val BLOCK_MODE_GCM = "GCM"
    const val ENCRYPTION_PADDING_NONE = "NoPadding"
}
"""
jars = sorted(args.jars.glob("*.jar"))
assert jars, "No compiler/dependency jars found"
classpath = ":".join(str(jar) for jar in jars)
with tempfile.TemporaryDirectory(prefix="hwe-keep-jvm-") as folder:
    folder = Path(folder)
    store = folder / "SecretStore.kt"
    store.write_text(imports + classes)
    keystore = folder / "KeystoreSignatures.kt"
    keystore.write_text(stubs)
    tests = root / "app/src/test/java/com/checkkaka/health_workout_export/KeepVaultTest.kt"
    output = folder / "tests.jar"
    subprocess.run(["java", "-cp", classpath, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                    "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", classpath,
                    "-d", str(output), str(store), str(keystore), str(tests)], check=True)
    runtime = ":".join([str(output), classpath])
    subprocess.run(["java", "-cp", runtime, "org.junit.runner.JUnitCore",
                    "com.checkkaka.health_workout_export.KeepVaultTest"], check=True)
