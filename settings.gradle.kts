rootProject.name = "cmp-a11y-displaylink-repro"

pluginManagement {
    val kotlinVersion = settings.providers.gradleProperty("repro.kotlin").get()
    val cmpVersion = settings.providers.gradleProperty("repro.cmp").get()
    repositories {
        mavenCentral()
        gradlePluginPortal()
        google()
    }
    plugins {
        kotlin("multiplatform") version kotlinVersion
        kotlin("plugin.compose") version kotlinVersion
        id("org.jetbrains.compose") version cmpVersion
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

include(":composeApp")
