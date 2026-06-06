pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "QuestCaptureAndroidPlugin"
include(":contract")
include(":capture_common")
include(":spatialmp4_muxer")
include(":questcapture")
include(":qrscanner")
include(":picocapture")
include(":live_feed_server")
