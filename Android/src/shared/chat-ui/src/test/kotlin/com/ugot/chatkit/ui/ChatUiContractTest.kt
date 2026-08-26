/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatUiContractTest {
  @Test
  fun composerAllowsTextOrAttachmentButNotBlankInput() {
    assertFalse(ChatComposerUiState(draft = "   ").canSend())
    assertTrue(ChatComposerUiState(draft = "hello").canSend())
    assertTrue(
      ChatComposerUiState(
          attachments =
            listOf(
              ChatAttachmentUi(
                id = "image-1",
                type = ChatAttachmentType.IMAGE,
                displayName = "image.png",
                contentRef = "content://image/1",
              )
            )
        )
        .canSend()
    )
  }

  @Test
  fun composerCannotSendWhileRuntimeIsBusy() {
    assertFalse(ChatComposerUiState(draft = "hello", inProgress = true).canSend())
    assertFalse(ChatComposerUiState(draft = "hello", enabled = false).canSend())
  }
}
