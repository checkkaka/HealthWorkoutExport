pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        exclusiveContent {
            forRepository { maven { url = uri("https://storage.googleapis.com/download.flutter.io") } }
            filter { includeGroup("io.flutter") }
        }
    }
}
rootProject.name = "health-workout-native-validation"
