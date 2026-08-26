/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.runtime.litert

import com.ugot.chatkit.runtime.ChatRuntimeAvailability
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Test

class LiteRtLocalModelConfigTest {
  @Test
  fun descriptorRequiresReadableModelFile() {
    val missing =
      LiteRtLocalModelConfig(
        id = "q-local",
        displayName = "Q local model",
        modelPath = "/missing/model.litertlm",
      )
    assertEquals(LiteRtLocalBackend.GPU, missing.backend)
    assertEquals(ChatRuntimeAvailability.REQUIRES_DOWNLOAD, missing.toDescriptor().availability)

    val file = Files.createTempFile("q-local", ".litertlm").toFile()
    try {
      val ready = missing.copy(modelPath = file.absolutePath)
      assertEquals(ChatRuntimeAvailability.READY, ready.toDescriptor().availability)
    } finally {
      file.delete()
    }
  }
}
