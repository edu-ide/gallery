import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
  alias(libs.plugins.android.library)
  alias(libs.plugins.kotlin.android)
}

android {
  namespace = "com.ugot.chatkit.controller"
  compileSdk = 35

  defaultConfig { minSdk = 26 }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
  }
  kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_11) } }
}

dependencies {
  api(project(":shared:runtime"))
  api(project(":shared:chat-ui"))
  implementation(libs.kotlinx.coroutines.core)
  testImplementation("junit:junit:4.13.2")
  testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}
