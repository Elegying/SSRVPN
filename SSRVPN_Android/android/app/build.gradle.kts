import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Official releases are signed in GitHub Actions. The release workflow writes a
// temporary android/key.properties from repository secrets before building.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties.isNotEmpty()
val isGitHubActions = providers.environmentVariable("GITHUB_ACTIONS").orNull == "true"
val isReleaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

android {
    namespace = "com.ssrvpn.android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        applicationId = "com.ssrvpn.android"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    // 核心 libgojni.so 只有 arm64 版本，其他架构装上也无法连接，
    // 强制剔除避免 Flutter 插件把多架构运行时打回包里
    packaging {
        jniLibs {
            excludes += listOf("**/armeabi-v7a/**", "**/x86_64/**", "**/x86/**")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (!hasReleaseKeystore && isGitHubActions && isReleaseBuildRequested) {
                error(
                    "Android release signing is missing. Configure the GitHub " +
                        "Actions secrets and let the release workflow generate key.properties."
                )
            }

            // Local machines may build an unsigned-official release for temporary
            // verification, but GitHub release builds must use the secrets-backed key.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 代码缩减：移除未使用的类、方法、字段
            isMinifyEnabled = true
            // 资源缩减：移除未引用的资源文件
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core:1.18.0")
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}
