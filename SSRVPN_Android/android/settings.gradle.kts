import org.gradle.api.initialization.resolve.RepositoriesMode

pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // Flutter 3.44.1's Gradle plugin unconditionally adds its engine Maven
    // repository to every project. PREFER_SETTINGS ignores that project
    // repository while keeping dependency resolution on this allowlist.
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        exclusiveContent {
            forRepository {
                maven {
                    name = "Flutter"
                    url = uri("https://storage.googleapis.com/download.flutter.io")
                }
            }
            filter {
                includeGroup("io.flutter")
            }
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("com.android.built-in-kotlin") version "9.0.1" apply false
    // Kept only for third-party Flutter plugins that have not migrated yet.
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
