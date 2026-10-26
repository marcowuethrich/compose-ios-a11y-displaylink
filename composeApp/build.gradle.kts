plugins {
    kotlin("multiplatform")
    kotlin("plugin.compose")
    id("org.jetbrains.compose")
}

val cmpVersion = providers.gradleProperty("repro.cmp").get()
val material3Version = providers.gradleProperty("repro.material3").get()

kotlin {
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "ComposeApp"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.compose.runtime:runtime:$cmpVersion")
            implementation("org.jetbrains.compose.foundation:foundation:$cmpVersion")
            implementation("org.jetbrains.compose.ui:ui:$cmpVersion")
            implementation("org.jetbrains.compose.material3:material3:$material3Version")
        }
    }
}
