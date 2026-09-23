plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
}

kotlin {
    explicitApi()
    iosArm64()
    iosSimulatorArm64()
    jvm("desktop")

    targets.withType<org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget>().configureEach {
        binaries.framework {
            baseName = "YTMProbe"
            isStatic = true
            freeCompilerArgs += "-Xoverride-konan-properties=minVersion.ios=16.0"
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation("io.ktor:ktor-client-core:3.5.2")
            implementation("io.ktor:ktor-client-content-negotiation:3.5.2")
            implementation("io.ktor:ktor-serialization-kotlinx-json:3.5.2")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
        }
        val desktopMain by getting {
            dependencies {
                implementation("io.ktor:ktor-client-okhttp:3.5.2")
                implementation("com.github.MetrolistGroup.innertubex:innertubex-desktop:0.7.0")
            }
        }
        iosArm64Main.dependencies {
            implementation("com.github.MetrolistGroup.innertubex:innertubex-iosarm64:0.7.0")
        }
        iosSimulatorArm64Main.dependencies {
            implementation("com.github.MetrolistGroup.innertubex:innertubex-iossimulatorarm64:0.7.0")
        }
        iosMain.dependencies {
            implementation("io.ktor:ktor-client-darwin:3.5.2")
        }
    }
}

tasks.register<JavaExec>("desktopProbeRun") {
    dependsOn("desktopMainClasses")
    mainClass.set("io.github.hck5722.ytmprobe.DesktopMainKt")
    classpath(
        files(
            layout.buildDirectory.dir("classes/kotlin/desktop/main"),
            layout.buildDirectory.dir("resources/desktop/main"),
        ),
        configurations.getByName("desktopRuntimeClasspath"),
    )
    val desktopArgs = providers.gradleProperty("desktopArgs").orNull
    if (!desktopArgs.isNullOrBlank()) args(desktopArgs.split(" "))
}
