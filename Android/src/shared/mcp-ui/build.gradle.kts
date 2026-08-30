import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
  alias(libs.plugins.android.library)
  alias(libs.plugins.kotlin.android)
  alias(libs.plugins.kotlin.compose)
}

android {
  namespace = "com.ugot.chatkit.mcp.ui"
  // Q Language resolves Activity 1.13/Core 1.18, whose AAR metadata requires API 36.
  compileSdk = 36
  defaultConfig { minSdk = 26 }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
  }
  kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_11) }
  }
  buildFeatures { compose = true }
  sourceSets.getByName("main").assets.srcDir("../../../../iosApp/Resources/MCPAppsHost")
}

dependencies {
  api(project(":shared:mcp-runtime"))
  implementation(project(":shared:core"))
  implementation(project(":shared:chat-ui"))
  implementation(platform(libs.androidx.compose.bom))
  implementation(libs.androidx.activity.compose)
  implementation("androidx.compose.ui:ui")
  implementation("androidx.compose.ui:ui-tooling-preview")
  implementation("androidx.compose.material3:material3")
  implementation("androidx.compose.material:material-icons-core")
  implementation("androidx.compose.material:material-icons-extended")
  testImplementation(libs.junit)
  debugImplementation("androidx.compose.ui:ui-tooling")
}
