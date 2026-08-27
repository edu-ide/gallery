package com.google.ai.edge.gallery.ui.llmchat

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UgotChatExperienceArchitectureTest {
  @Test
  fun generalLlmChat_entersThroughThePublicSharedExperience() {
    val root = galleryAndroidRoot()
    val screen =
      File(
          root,
          "app/src/main/java/com/google/ai/edge/gallery/ui/llmchat/LlmChatScreen.kt",
        )
        .readText()
    val sharedUiSource = kotlinSourceUnder(File(root, "shared/chat-ui/src/main"))
    val generalChatBody =
      screen.substringAfter("fun LlmChatScreen(").substringBefore("fun LlmAskImageScreen(")

    assertTrue(
      "shared/chat-ui must expose the public UgotChatExperience entrypoint",
      Regex("(?m)^\\s*(?:public\\s+)?fun\\s+UgotChatExperience\\s*\\(")
        .containsMatchIn(sharedUiSource),
    )
    assertTrue(
      "Gallery general LLM chat must import the shared UgotChatExperience",
      screen.contains("import com.ugot.chatkit.ui.UgotChatExperience"),
    )
    assertTrue(
      "Gallery general LLM chat must call UgotChatExperience",
      Regex("\\bUgotChatExperience\\s*\\(").containsMatchIn(generalChatBody),
    )
    assertFalse(
      "Gallery general LLM chat must not enter the app-local ChatView path",
      Regex("\\b(?:ChatView|ChatViewWrapper|ChatPanel)\\s*\\(").containsMatchIn(generalChatBody),
    )
  }

  @Test
  fun specializedGalleryChat_reusesSharedChromeOwners() {
    val root = galleryAndroidRoot()
    val commonChat = File(root, "app/src/main/java/com/google/ai/edge/gallery/ui/common/chat")
    val appBar =
      File(root, "app/src/main/java/com/google/ai/edge/gallery/ui/common/ModelPageAppBar.kt")
        .readText()
    val modelPicker =
      File(root, "app/src/main/java/com/google/ai/edge/gallery/ui/common/ModelPickerChip.kt")
        .readText()
    val panel = File(commonChat, "ChatPanel.kt").readText()
    val composer = File(commonChat, "MessageInputText.kt").readText()

    assertTrue(
      "Gallery app bar must delegate its chrome to UgotChatTopBar",
      Regex("\\bUgotChatTopBar\\s*\\(").containsMatchIn(appBar),
    )
    assertFalse(
      "Gallery must not own a parallel Material top app bar",
      Regex("\\b(?:TopAppBar|CenterAlignedTopAppBar)\\s*\\(").containsMatchIn(appBar),
    )
    assertTrue(
      "Gallery model selection must reuse the shared model trigger",
      Regex("\\bUgotChatModelTrigger\\s*\\(").containsMatchIn(modelPicker),
    )
    assertTrue(
      "specialized Gallery chat must reuse the shared experience scaffold",
      Regex("\\bUgotChatExperienceScaffold\\s*\\(").containsMatchIn(panel),
    )
    assertTrue(
      "specialized Gallery messages must reuse the shared message frame",
      Regex("\\bUgotChatMessageFrame\\s*\\(").containsMatchIn(panel),
    )
    assertTrue(
      "specialized Gallery composer must reuse the complete shared composer frame",
      Regex("\\bUgotChatComposerFrame\\s*\\(").containsMatchIn(composer),
    )
    assertTrue(
      "specialized Gallery attachments must reuse the shared attachment strip",
      Regex("\\bUgotChatAttachmentStrip\\s*(?:\\(|\\{)").containsMatchIn(composer),
    )
    assertFalse(
      "Gallery must not render a parallel TextField or send/stop button",
      Regex("\\b(?:TextField|UgotChatDraftField|UgotChatSendOrStopButton)\\s*\\(")
        .containsMatchIn(composer),
    )
  }

  private fun kotlinSourceUnder(root: File): String =
    root.walkTopDown()
      .filter { it.isFile && it.extension == "kt" }
      .sortedBy { it.invariantSeparatorsPath }
      .joinToString(separator = "\n") { it.readText() }

  private fun galleryAndroidRoot(): File {
    var candidate = File(requireNotNull(System.getProperty("user.dir"))).canonicalFile
    while (true) {
      if (
        File(candidate, "settings.gradle.kts").isFile &&
          File(candidate, "app/src/main").isDirectory &&
          File(candidate, "shared/chat-ui/src/main").isDirectory
      ) {
        return candidate
      }
      candidate = candidate.parentFile ?: error("Unable to locate the Gallery Android root")
    }
  }
}
