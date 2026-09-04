plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.checkkaka.health_workout_export"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.checkkaka.health_workout_export"
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val uploadKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
    if (!uploadKeystorePath.isNullOrBlank()) {
        signingConfigs.create("release") {
            storeFile = file(uploadKeystorePath)
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                ?: error("ANDROID_KEYSTORE_PASSWORD is required when ANDROID_KEYSTORE_PATH is set")
            keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                ?: error("ANDROID_KEY_ALIAS is required when ANDROID_KEYSTORE_PATH is set")
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                ?: error("ANDROID_KEY_PASSWORD is required when ANDROID_KEYSTORE_PATH is set")
        }
    }

    buildTypes {
        release {
            // CI 注入 keystore；本地未配置时仍用 debug 签名，方便 flutter run --release。
            signingConfig =
                if (!uploadKeystorePath.isNullOrBlank()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.browser:browser:1.8.0")
    testImplementation("junit:junit:4.13.2")
}
