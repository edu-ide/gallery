import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
  alias(libs.plugins.android.library)
  alias(libs.plugins.kotlin.android)
  alias(libs.plugins.kotlin.serialization)
}

android {
  namespace = "com.ugot.chatkit.mcp.runtime"
  compileSdk = 35
  defaultConfig { minSdk = 26 }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
  }
  kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_11) }
  }
}

dependencies {
  api(project(":shared:mcp-core"))
  implementation(project(":shared:core"))
  implementation(project(":shared:runtime"))
  implementation(platform(libs.ktor.bom))
  implementation(libs.com.google.code.gson)
  implementation(libs.mcp.kotlin.sdk.client)
  implementation(libs.ktor.client.okhttp)
  implementation(libs.kotlinx.serialization.json)
  implementation(libs.kotlinx.coroutines.core)
  testImplementation(libs.junit)
}
