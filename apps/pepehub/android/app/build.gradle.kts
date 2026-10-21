plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.pepehub.pepehub"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.pepehub.pepehub"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Keep the project-local signing key so updates from the distributed
            // Android builds remain installable on top of the previous release.
            signingConfig = signingConfigs.create("pepehubRelease") {
                storeFile = rootProject.file("../../../.tools/android-user/debug.keystore")
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}

// AGP 9 host tests package the merged debug assets, including Flutter's output.
// Flutter 3.47 does not declare this dependency for the new host-test task yet.
tasks.matching { it.name.startsWith("package") && it.name.endsWith("UnitTestForUnitTest") }.configureEach {
    val variant = name.removePrefix("package").removeSuffix("UnitTestForUnitTest")
    dependsOn("copyFlutterAssets$variant")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Flutter 3.47 registers dev-only plugins in the Android host registrant even
// for release builds, while its Gradle plugin correctly omits them from the
// release classpath. Remove the integration-test registration before javac.
tasks.withType<JavaCompile>().configureEach {
    if (name.contains("Release")) {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val source = registrant.readText()
                val integrationTestRegistration = Regex(
                    """    try \{\r?\n      flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\r?\n    \} catch \(Exception e\) \{\r?\n      Log\.e\(TAG, "Error registering plugin integration_test, dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin", e\);\r?\n    \}\r?\n""",
                )
                registrant.writeText(integrationTestRegistration.replace(source, ""))
            }
        }
    }
}
