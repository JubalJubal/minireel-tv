group = "io.flutter.plugins.videoplayer"
version = "1.0-SNAPSHOT"

// 作为 Flutter 应用的 path 依赖构建时，AGP / Kotlin 版本统一来自宿主
// settings.gradle.kts 的 pluginManagement（本地走阿里云镜像），这里不再
// 用 buildscript classpath 自带一套版本，否则会绕过镜像直连 mavenCentral。
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "io.flutter.plugins.videoplayer"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    dependencies {
        val exoplayerVersion = "1.9.2"
        implementation("androidx.media3:media3-exoplayer:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-hls:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-dash:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-rtsp:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-smoothstreaming:${exoplayerVersion}")
    }
}
