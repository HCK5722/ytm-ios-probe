plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
}

kotlin {
    explicitApi()
    iosArm64()
    iosSimulatorArm64()

    targets.withType<org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget>().configureEach {
        binaries.framework {
            baseName = "YTMProbe"
            isStatic = true
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
