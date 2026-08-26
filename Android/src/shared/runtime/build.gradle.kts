/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
  alias(libs.plugins.kotlin.multiplatform)
  alias(libs.plugins.android.library)
}

kotlin {
  androidTarget {
    compilerOptions {
      jvmTarget.set(JvmTarget.JVM_11)
    }
  }

  val runtimeXcframework = XCFramework("UgotChatRuntime")
  listOf(
    iosArm64(),
    iosX64(),
    iosSimulatorArm64(),
  ).forEach { iosTarget ->
    iosTarget.binaries.framework {
      baseName = "UgotChatRuntime"
      isStatic = true
      export(project(":shared:core"))
      runtimeXcframework.add(this)
    }
  }

  sourceSets {
    commonMain.dependencies {
      api(project(":shared:core"))
    }
    commonTest.dependencies {
      implementation(kotlin("test"))
    }
  }
}

android {
  namespace = "com.ugot.chatkit.runtime"
  compileSdk = 35

  defaultConfig {
    minSdk = 26
  }
}
