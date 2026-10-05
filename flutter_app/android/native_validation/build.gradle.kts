plugins {
    id("com.android.library") version "9.0.1"
}

// Compile the production adapters without invoking Flutter, Dart, FRB, or native-asset hooks.
val flutterSdk = providers.gradleProperty("flutterSdk")
    .orElse(providers.environmentVariable("FLUTTER_ROOT"))
    .orNull ?: error("Pass -PflutterSdk=<Flutter SDK directory> or set FLUTTER_ROOT")
val engineRevision = file("$flutterSdk/bin/internal/engine.version").readText().trim()
require(engineRevision.matches(Regex("[0-9a-f]{40}"))) { "Invalid Flutter engine revision" }

android {
    namespace = "com.checkkaka.health_workout_export"
    compileSdk = 36
    defaultConfig {
        minSdk = 26
        manifestPlaceholders["applicationName"] = "android.app.Application"
    }
    sourceSets {
        getByName("main") {
            manifest.srcFile("../app/src/main/AndroidManifest.xml")
            java.setSrcDirs(listOf("../app/src/main/java"))
            kotlin.directories += "../app/src/main/kotlin"
            res.setSrcDirs(listOf("../app/src/main/res"))
        }
        getByName("test") {
            java.setSrcDirs(listOf("../app/src/test/java"))
            kotlin.directories += "../app/src/test/java"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 }
}

dependencies {
    implementation("io.flutter:flutter_embedding_debug:1.0.0-$engineRevision")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.health.connect:connect-client:1.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
}
