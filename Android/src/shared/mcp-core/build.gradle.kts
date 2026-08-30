import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
  alias(libs.plugins.kotlin.multiplatform)
  alias(libs.plugins.android.library)
  alias(libs.plugins.kotlin.serialization)
}

kotlin {
  androidTarget {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_11) }
  }

  val framework = XCFramework("UgotMcpCore")
  listOf(iosArm64(), iosX64(), iosSimulatorArm64()).forEach { iosTarget ->
    iosTarget.binaries.framework {
      baseName = "UgotMcpCore"
      isStatic = true
      framework.add(this)
    }
  }

  sourceSets {
    commonMain.dependencies {
      implementation(libs.kotlinx.serialization.json)
    }
    commonTest.dependencies {
      implementation(kotlin("test"))
    }
  }
}

android {
  namespace = "com.ugot.chatkit.mcp.core"
  compileSdk = 35
  defaultConfig { minSdk = 26 }
}
