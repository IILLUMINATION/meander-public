import java.io.FileInputStream
import java.util.Properties
import org.gradle.api.JavaVersion

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasReleaseKeystore =
    keystorePropertiesFile.exists() &&
    !keystoreProperties.getProperty("keyAlias").isNullOrBlank() &&
    !keystoreProperties.getProperty("keyPassword").isNullOrBlank() &&
    !keystoreProperties.getProperty("storeFile").isNullOrBlank() &&
    !keystoreProperties.getProperty("storePassword").isNullOrBlank()
val isReleaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
if (isReleaseTaskRequested && !hasReleaseKeystore) {
    // key.properties — локальный материал подписи, его в репозитории нет.
    // Сборка без него законна: на выходе неподписанный APK, который F-Droid
    // и любой свой релиз подписывают внешним ключом.
    logger.warn(
        "key.properties нет: release-задачи дадут неподписанный APK. Для своего релиза создай android/key.properties.",
    )
}

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    // END: FlutterFire Configuration
    id("dev.flutter.flutter-gradle-plugin")
}

// Плагин нужен ровно на одно: считать android/google-services.json и положить
// его значения в ресурсы. Этого файла в репозитории нет (он в .gitignore), а
// Firebase инициализируется из кода явными параметрами, поэтому применяем
// плагин только когда конфиг действительно лежит рядом.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

configurations.all {
    exclude(group = "commons-io", module = "commons-io")
}

// Patch GeneratedPluginRegistrant to avoid hard reference to FilePickerPlugin
val registrantFile = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
val patchGeneratedPluginRegistrant = tasks.register("patchGeneratedPluginRegistrant") {
    doLast {
        if (!registrantFile.exists()) return@doLast
        val content = registrantFile.readText()
        if (!content.contains("com.mr.flutter.plugin.filepicker.FilePickerPlugin")) return@doLast

        val pattern = Regex(
            """(?s)\s*try\s*\{\s*flutterEngine\.getPlugins\(\)\.add\(new com\.mr\.flutter\.plugin\.filepicker\.FilePickerPlugin\(\)\);\s*\}\s*catch\s*\(Exception e\)\s*\{\s*Log\.e\(TAG,\s*\"Error registering plugin file_picker, com\.mr\.flutter\.plugin\.filepicker\.FilePickerPlugin\",\s*e\);\s*\}\s*"""
        )
        val replacement = """
    try {
      Class<?> clazz = Class.forName("com.mr.flutter.plugin.filepicker.FilePickerPlugin");
      flutterEngine.getPlugins().add((io.flutter.embedding.engine.plugins.FlutterPlugin) clazz.getDeclaredConstructor().newInstance());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin file_picker, com.mr.flutter.plugin.filepicker.FilePickerPlugin", e);
    }

""".trimIndent()

        val updated = pattern.replace(content, "\n$replacement\n")
        if (updated != content) {
            registrantFile.writeText(updated)
        }
    }
}

// AppMetrica в приложении не используется, но приходит транзитивно в
// com.yandex.android:mobileads. Держим её вырезанной из графа зависимостей.
configurations.configureEach {
    exclude(group = "io.appmetrica.analytics")
}

// jniLibs/libmnd_ffi.so больше не лежит в репозитории: их порождает эта сборка.
// Нужны cargo-ndk (`cargo install cargo-ndk`) и NDK указанной версии.
val androidNdkVersion = "28.2.13676358"
val buildMndFfiAndroid = tasks.register("buildMndFfiAndroid") {
    group = "mnd"
    description = "Собирает libmnd_ffi.so для всех Android ABI из crates/mnd-ffi."
    notCompatibleWithConfigurationCache("запускает cargo-ndk")
    doLast {
        val localProps = Properties()
        val sdkLocal = rootProject.file("local.properties")
        if (sdkLocal.exists()) sdkLocal.inputStream().use { localProps.load(it) }
        val sdkDir = localProps.getProperty("sdk.dir")
            ?: System.getenv("ANDROID_HOME")
            ?: error("Android SDK не найден: нет sdk.dir в android/local.properties и ANDROID_HOME пуст.")
        // Версию из env уважаем: в контейнерной сборке (CI, F-Droid) NDK лежит
        // где угодно и тот, что установлен в образе, а не по пути $sdkDir/ndk/<пиннинг>.
        val ndkFromEnv = System.getenv("ANDROID_NDK_HOME")
            ?.let { file(it) }
            ?.takeIf { it.isDirectory }
        val ndkDir = ndkFromEnv ?: file("$sdkDir/ndk/$androidNdkVersion")
        if (!ndkDir.isDirectory) {
            error(
                "NDK $androidNdkVersion не установлен в $sdkDir/ndk — доставь его через " +
                    "sdkmanager или укажи готовый в ANDROID_NDK_HOME.",
            )
        }
        // ProcessBuilder, а не project.exec: в Gradle 9 метод Project.exec
        // убран, а префикс `java.` здесь перекрыт accessor'ом плагина java.
        // directory — корень монорепы (app -> android -> main_app -> apps -> корень).
        fun cargo(args: List<String>, quiet: Boolean): Int {
            val builder = ProcessBuilder(listOf("cargo") + args)
                .directory(file("../../../../"))
            val redirect =
                if (quiet) ProcessBuilder.Redirect.DISCARD else ProcessBuilder.Redirect.INHERIT
            builder.redirectOutput(redirect)
            builder.redirectError(redirect)
            // cargo ndk сам подбирает тулчейн по этой переменной; без неё он
            // берёт NDK с PATH и молча кладёт в jniLibs stale-артефакт.
            builder.environment()["ANDROID_NDK_HOME"] = ndkDir.absolutePath
            return try {
                builder.start().waitFor()
            } catch (e: Exception) {
                -1
            }
        }
        if (cargo(listOf("ndk", "--version"), true) != 0) {
            error("Нужен cargo-ndk: cargo install cargo-ndk.")
        }
        val abiArgs = listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
            .flatMap { listOf("-t", it) }
        val code = cargo(
            listOf("ndk", "--platform", "24") + abiArgs +
                listOf(
                    "-o", file("src/main/jniLibs").absolutePath,
                    "build", "--release", "--locked", "-p", "mnd-ffi",
                ),
            false,
        )
        if (code != 0) {
            error("cargo ndk завершился с кодом $code — jniLibs останутся пустыми, APK соберётся без ядра.")
        }
    }
}

android {
    namespace = "com.IILLUMINAT.meadner"
    compileSdk = flutter.compileSdkVersion
    // ВАЖНО: Ставим стабильную версию NDK, чтобы файлы сжимались без ошибок на Windows
    ndkVersion = androidNdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // Отключаем Lint, чтобы не было ошибки "файл занят процессом"
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.IILLUMINAT.meadner"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // OAuth-клиенты задаются локально: -PИМЯ=... или в gradle.properties.
        manifestPlaceholders["YANDEX_CLIENT_ID"] =
            (project.findProperty("YANDEX_CLIENT_ID") as String?) ?: ""
        manifestPlaceholders["TELEGRAM_CLIENT_ID"] =
            (project.findProperty("TELEGRAM_CLIENT_ID") as String?) ?: ""
        manifestPlaceholders["YANDEX_OAUTH_HOST"] = "oauth.yandex.ru"
    }

    // --- Flavors ---
    // AGP 9: resValue удалён из flavor-DSL; app_name задаётся
    // через src/{prod,dev}/res/values/strings.xml
    flavorDimensions += "default"
    productFlavors {
        create("prod") {
            dimension = "default"
        }
        create("dev") {
            dimension = "default"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-beta"
        }
    }

    buildTypes {
        getByName("release") {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }

            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        
        getByName("debug") {
            signingConfig = if (hasReleaseKeystore) {
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
    implementation(project(":android_file_picker"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

tasks.withType<JavaCompile>().configureEach {
    dependsOn(patchGeneratedPluginRegistrant)
}

tasks.named("preBuild") {
    dependsOn(buildMndFfiAndroid)
}
