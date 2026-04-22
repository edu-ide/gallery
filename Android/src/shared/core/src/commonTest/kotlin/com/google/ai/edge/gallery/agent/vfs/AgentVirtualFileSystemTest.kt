/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.google.ai.edge.gallery.agent.vfs

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class AgentVirtualFileSystemTest {
  @Test
  fun vfs_bootstrapsScopesAndRejectsTraversal() {
    val vfs = newVfs()

    assertTrue(vfs.exists("/"))
    assertTrue(vfs.exists("/session"))
    assertTrue(vfs.exists("/user"))
    assertTrue(vfs.exists("/sandbox"))
    assertFailsWith<AgentVfsException> { AgentVfsPath.parse("/session/one/../two") }
  }

  @Test
  fun vfs_writesListsMovesCopiesDeletesAndPersistsManifest() {
    val fs = FakeFileSystem()
    var now = 1_000L
    val vfs = OkioAgentVirtualFileSystem(fs, "/ugot-agent-vfs".toPath()) { now++ }

    val node =
      vfs.writeText(
        "/session/chat-1/mcp/fortune/profile.json",
        "{\"name\":\"Ada\",\"fortune\":\"good\"}",
        AgentVfsWriteOptions(mimeType = "application/json"),
      )

    assertEquals(AgentVfsNodeKind.FILE, node.kind)
    assertEquals(AgentVfsScope.SESSION, node.scope)
    assertEquals("application/json", node.mimeType)
    assertTrue(vfs.readText("/session/chat-1/mcp/fortune/profile.json").contains("Ada"))
    assertEquals(listOf("profile.json"), vfs.list("/session/chat-1/mcp/fortune").map { it.name })
    assertTrue(vfs.searchText("fortune", within = "/session/chat-1").isNotEmpty())

    vfs.copy(
      "/session/chat-1/mcp/fortune/profile.json",
      "/session/chat-1/generated/profile-copy.json",
    )
    vfs.move(
      "/session/chat-1/generated/profile-copy.json",
      "/session/chat-1/generated/profile-final.json",
    )

    assertTrue(vfs.exists("/session/chat-1/generated/profile-final.json"))
    assertFalse(vfs.exists("/session/chat-1/generated/profile-copy.json"))

    val reloaded = OkioAgentVirtualFileSystem(fs, "/ugot-agent-vfs".toPath()) { now++ }
    assertTrue(reloaded.exists("/session/chat-1/mcp/fortune/profile.json"))
    assertTrue(reloaded.delete("/session/chat-1", recursive = true))
    assertFalse(reloaded.exists("/session/chat-1"))
  }

  @OptIn(ExperimentalEncodingApi::class)
  @Test
  fun mcpIngestor_promotesEmbeddedResourcesResourceLinksAndStructuredContentToVfsNodes() {
    val vfs = newVfs()
    val ingestor = AgentVfsMcpIngestor(vfs)
    val result =
      AgentVfsMcpToolResult(
        structuredContentJson = "{\"current\":\"widget-context\"}",
        content =
          listOf(
            AgentVfsMcpContentBlock(
              type = "resource",
              resource =
                AgentVfsMcpResourceContent(
                  uri = "fortune://profiles/saved-users",
                  mimeType = "application/json",
                  text = "[{\"name\":\"Yun\"}]",
                ),
            ),
            AgentVfsMcpContentBlock(
              type = "resource_link",
              uri = "fortune://profiles/current",
              name = "current-profile.json",
              mimeType = "application/json",
            ),
            AgentVfsMcpContentBlock(
              type = "resource",
              resource =
                AgentVfsMcpResourceContent(
                  uri = "fortune://assets/chart.png",
                  mimeType = "image/png",
                  blobBase64 = Base64.encode(byteArrayOf(1, 2, 3, 4)),
                ),
            ),
          ),
      )

    val ingest =
      ingestor.ingestDefault(
        sessionId = "chat-1",
        connectorId = "fortune.ugot.uk/mcp",
        toolName = "show_today_fortune",
        toolCallId = "call-1",
        result = result,
        persistTextBlocks = false,
      )

    assertEquals(4, ingest.nodes.size)
    assertEquals(3, ingest.files.size)
    assertEquals(1, ingest.resourceLinks.size)
    assertTrue(vfs.exists("/session/chat-1/mcp/fortune.ugot.uk_mcp/show_today_fortune/structured-content.json"))
    assertTrue(vfs.readText("/session/chat-1/mcp/fortune.ugot.uk_mcp/show_today_fortune/saved-users.json").contains("Yun"))
    assertEquals(byteArrayOf(1, 2, 3, 4).toList(), vfs.readBytes("/session/chat-1/mcp/fortune.ugot.uk_mcp/show_today_fortune/chart.png").toList())
    assertTrue(vfs.contextSummary("/session/chat-1").contains("saved-users.json"))
    assertTrue(vfs.contextSummary("/session/chat-1").contains("fortune://profiles/current"))
  }

  @OptIn(ExperimentalEncodingApi::class)
  @Test
  fun userAttachmentIngestor_promotesChatAttachmentsToSessionWorkspace() {
    val vfs = newVfs()
    val ingestor = AgentVfsUserAttachmentIngestor(vfs)

    val node =
      ingestor.ingestDefault(
        sessionId = "chat-attachments",
        fileName = "../picked photo.jpg",
        mimeType = "image/jpeg",
        text = null,
        blobBase64 = Base64.encode(byteArrayOf(9, 8, 7)),
        externalUri = "file:///private/tmp/picked-photo.jpg",
        overwrite = false,
      )

    assertEquals(AgentVfsSourceType.USER_ATTACHMENT, node.source.type)
    assertEquals("/session/chat-attachments/attachments/picked_photo.jpg", node.path.value)
    assertEquals(byteArrayOf(9, 8, 7).toList(), vfs.readBytes(node.path.value).toList())
    assertTrue(vfs.contextSummary("/session/chat-attachments").contains("picked_photo.jpg"))
  }

  @Test
  fun safeToolsExposeShellLikeReadOnlyViewsWithoutRealShell() {
    val vfs = newVfs()
    val tools = AgentVfsTools(vfs)

    tools.mkdir("/session/chat-2/generated")
    tools.writeText("/session/chat-2/generated/notes.md", "# Notes\n- hello agent", "text/markdown")

    assertTrue(tools.ls("/session/chat-2/generated").contains("notes.md"))
    assertTrue(tools.tree("/session/chat-2").contains("generated/"))
    assertTrue(tools.cat("/session/chat-2/generated/notes.md").contains("hello agent"))
    assertTrue(tools.search("hello", "/session/chat-2").contains("notes.md"))
    assertNotNull(vfs.stat("/session/chat-2/generated/notes.md")?.checksumSha256)
  }

  private fun newVfs(): OkioAgentVirtualFileSystem {
    var now = 1L
    return OkioAgentVirtualFileSystem(FakeFileSystem(), "/ugot-agent-vfs".toPath()) { now++ }
  }
}
