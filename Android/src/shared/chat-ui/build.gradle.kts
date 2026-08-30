import org.jetbrains.kotlin.gradle.dsl.JvmTarget

/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

plugins {
  alias(libs.plugins.android.library)
  alias(libs.plugins.kotlin.android)
  alias(libs.plugins.kotlin.compose)
}

android {
  namespace = "com.ugot.chatkit.ui"
  compileSdk = 35

  defaultConfig {
    minSdk = 26
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
  }
  kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_11) }
  }
  buildFeatures {
    compose = true
  }
}

dependencies {
  implementation(platform("androidx.compose:compose-bom:2026.02.00"))
  implementation("androidx.compose.ui:ui")
  implementation("androidx.compose.foundation:foundation")
  implementation("androidx.compose.material:material-icons-extended")
  implementation("androidx.compose.material3:material3")
  implementation("androidx.compose.ui:ui-tooling-preview")
  implementation("com.halilibo.compose-richtext:richtext-commonmark:1.0.0-alpha02")
  implementation("com.halilibo.compose-richtext:richtext-ui-material3:1.0.0-alpha02")
  implementation("com.squareup.okio:okio:3.17.0")
  testImplementation("junit:junit:4.13.2")
  debugImplementation("androidx.compose.ui:ui-tooling")
}
