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

import kotlinx.serialization.Serializable

/** Storage scope for agent-visible files. */
@Serializable
enum class AgentVfsScope {
  /** Conversation-scoped files that should be removed with the chat session. */
  SESSION,

  /** User-owned files that can survive across sessions. */
  USER,

  /** Shared app sandbox files, templates, and connector caches. */
  SANDBOX,
}

@Serializable
enum class AgentVfsNodeKind {
  DIRECTORY,
  FILE,
  RESOURCE_LINK,
}

@Serializable
enum class AgentVfsSourceType {
  USER_ATTACHMENT,
  MCP_EMBEDDED_RESOURCE,
  MCP_RESOURCE_LINK,
  MCP_STRUCTURED_CONTENT,
  MCP_WIDGET,
  GENERATED,
  SYSTEM,
  UNKNOWN,
}

@Serializable
data class AgentVfsPath(val value: String) {
  init {
    require(AgentVfsPaths.isNormalized(value)) { "AgentVfsPath must be normalized: $value" }
  }

  val name: String
    get() = if (value == "/") "/" else value.substringAfterLast('/')

  val parent: AgentVfsPath?
    get() = AgentVfsPaths.parentOf(this)

  val segments: List<String>
    get() = AgentVfsPaths.segments(value)

  override fun toString(): String = value

  companion object {
    val ROOT = AgentVfsPath("/")

    fun parse(raw: String): AgentVfsPath = AgentVfsPath(AgentVfsPaths.normalize(raw))
  }
}

@Serializable
data class AgentVfsSource(
  val type: AgentVfsSourceType = AgentVfsSourceType.UNKNOWN,
  val connectorId: String? = null,
  val toolName: String? = null,
  val toolCallId: String? = null,
  val mcpUri: String? = null,
  val externalUri: String? = null,
)

@Serializable
data class AgentVfsNode(
  val id: String,
  val path: AgentVfsPath,
  val parentPath: AgentVfsPath?,
  val name: String,
  val kind: AgentVfsNodeKind,
  val scope: AgentVfsScope?,
  val mimeType: String? = null,
  val sizeBytes: Long? = null,
  val checksumSha256: String? = null,
  val previewText: String? = null,
  val source: AgentVfsSource = AgentVfsSource(),
  val createdAtEpochMs: Long,
  val updatedAtEpochMs: Long,
) {
  val isDirectory: Boolean
    get() = kind == AgentVfsNodeKind.DIRECTORY

  val isFile: Boolean
    get() = kind == AgentVfsNodeKind.FILE
}

@Serializable
data class AgentVfsManifest(
  val schemaVersion: Int = 1,
  val nodes: List<AgentVfsNode> = emptyList(),
)

@Serializable
data class AgentVfsTreeEntry(
  val node: AgentVfsNode,
  val depth: Int,
)

data class AgentVfsWriteOptions(
  val mimeType: String? = null,
  val source: AgentVfsSource = AgentVfsSource(),
  val previewText: String? = null,
  val overwrite: Boolean = true,
)

class AgentVfsException(message: String) : IllegalArgumentException(message)
