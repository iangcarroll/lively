import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

/** A UTC timestamp, like the iOS build numbers: 2026102301 for 01:00 on Oct 23 2026, minus the minutes. */
val buildNumber: Int = providers.gradleProperty("livelyBuildNumber").orNull?.toInt()
    ?: ZonedDateTime.now(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyMMddHH")).toInt()

android {
    namespace = "sh.ian.lively"
    compileSdk = 37

    defaultConfig {
        applicationId = "sh.ian.lively"
        // Android 10: on-device Simplified → Traditional conversion
        // (android.icu Transliterator) and language detection (TextClassifier).
        minSdk = 29
        targetSdk = 36
        versionCode = buildNumber
        versionName = "0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Lively's key broker (Server/key-broker), which hands out temporary
        // Soniox keys. Empty means Soniox needs a key entered in Settings.
        buildConfigField("String", "KEY_BROKER_URL", "\"${providers.gradleProperty("livelyKeyBrokerUrl").getOrElse("https://lively.ian.sh")}\"")
    }

    // Play upload signing, from ~/.gradle/gradle.properties or -P flags:
    // livelyKeystore, livelyKeystorePassword, livelyKeyAlias, livelyKeyPassword.
    // Without them, release builds use the debug key so they can be tried locally.
    val keystore = providers.gradleProperty("livelyKeystore").orNull
    signingConfigs {
        if (keystore != null) {
            create("upload") {
                storeFile = file(keystore)
                storePassword = providers.gradleProperty("livelyKeystorePassword").get()
                keyAlias = providers.gradleProperty("livelyKeyAlias").get()
                keyPassword = providers.gradleProperty("livelyKeyPassword").get()
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.window)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material3.windowsizeclass)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.billing)
    // Play Billing brings an old Fragment; ActivityResult needs 1.3 or later.
    implementation(libs.androidx.fragment)
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)

    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.espresso)
    androidTestImplementation(libs.androidx.test.uiautomator)
}
