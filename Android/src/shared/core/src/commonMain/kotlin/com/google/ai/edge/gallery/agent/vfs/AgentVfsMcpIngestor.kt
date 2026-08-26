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
import kotlinx.serialization.Serializable

@Serializable
data class AgentVfsMcpResourceContent(
  val uri: String? = null,
  val mimeType: String? = null,
  val text: String? = null,
  /** MCP blob payload. Expected to be base64 encoded. */
  val blobBase64: String? = null,
)

@Serializable
data class AgentVfsMcpContentBlock(
  val type: String,
  val text: String? = null,
  val resource: AgentVfsMcpResourceContent? = null,
  val uri: String? = null,
  val name: String? = null,
  val mimeType: String? = null,
)

@Serializable
data class AgentVfsMcpToolResult(
  val content: List<AgentVfsMcpContentBlock> = emptyList(),
  val structuredContentJson: String? = null,
  val rawResultJson: String? = null,
)

data class AgentVfsMcpIngestRequest(
  val sessionId: String,
  val connectorId: String,
  val toolName: String,
  val toolCallId: String? = null,
  val result: AgentVfsMcpToolResult,
  val basePath: AgentVfsPath =
    AgentVfsPaths.pathForSession(
      sessionId,
      "mcp",
      connectorId,
      toolName,
    ),
  /** Persist plain text MCP content blocks too. Off by default to avoid transcript duplication. */
  val persistTextBlocks: Boolean = false,
)

data class AgentVfsMcpIngestResult(
  val nodes: List<AgentVfsNode>,
) {
  val files: List<AgentVfsNode>
    get() = nodes.filter { it.kind == AgentVfsNodeKind.FILE }

  val resourceLinks: List<AgentVfsNode>
    get() = nodes.filter { it.kind == AgentVfsNodeKind.RESOURCE_LINK }
}

class AgentVfsMcpIngestor(private val vfs: OkioAgentVirtualFileSystem) {
  /**
   * Swift-friendly convenience entry point.
   *
   * Kotlin default arguments on [AgentVfsMcpIngestRequest] are exposed to Swift as a full
   * initializer, which makes the iOS host responsible for building internal VFS paths. Keep that
   * ownership in shared core so mobile hosts only pass protocol facts and receive a projected VFS
   * artifact set.
   */
  fun ingestDefault(
    sessionId: String,
    connectorId: String,
    toolName: String,
    toolCallId: String?,
    result: AgentVfsMcpToolResult,
    persistTextBlocks: Boolean,
  ): AgentVfsMcpIngestResult =
    ingest(
      AgentVfsMcpIngestRequest(
        sessionId = sessionId,
        connectorId = connectorId,
        toolName = toolName,
        toolCallId = toolCallId,
        result = result,
        persistTextBlocks = persistTextBlocks,
      ),
    )

  fun ingest(request: AgentVfsMcpIngestRequest): AgentVfsMcpIngestResult {
    val created = mutableListOf<AgentVfsNode>()
    vfs.createDirectory(request.basePath.value, source = source(request, AgentVfsSourceType.MCP_WIDGET))

    request.result.structuredContentJson?.takeIf { it.isNotBlank() }?.let { json ->
      created +=
        vfs.writeText(
          path = uniquePath(request.basePath, "structured-content.json", created),
          text = json,
          options =
            AgentVfsWriteOptions(
              mimeType = "application/json",
              source = source(request, AgentVfsSourceType.MCP_STRUCTURED_CONTENT),
              previewText = json.take(PREVIEW_LIMIT),
            ),
        )
    }

    request.result.rawResultJson?.takeIf { it.isNotBlank() }?.let { json ->
      created +=
        vfs.writeText(
          path = uniquePath(request.basePath, "raw-result.json", created),
          text = json,
          options =
            AgentVfsWriteOptions(
              mimeType = "application/json",
              source = source(request, AgentVfsSourceType.MCP_STRUCTURED_CONTENT),
              previewText = json.take(PREVIEW_LIMIT),
            ),
        )
    }

    request.result.content.forEachIndexed { index, block ->
      when (block.type.lowercase()) {
        "resource" -> block.resource?.let { created += ingestResource(request, it, index, created) }
        "resource_link", "resourcelink" -> created += ingestResourceLink(request, block, index, created)
        "text" ->
          if (request.persistTextBlocks && !block.text.isNullOrBlank()) {
            created +=
              vfs.writeText(
                path = uniquePath(request.basePath, "text-$index.txt", created),
                text = block.text,
                options =
                  AgentVfsWriteOptions(
                    mimeType = "text/plain",
                    source = source(request, AgentVfsSourceType.MCP_STRUCTURED_CONTENT),
                    previewText = block.text.take(PREVIEW_LIMIT),
                  ),
              )
          }
      }
    }

    return AgentVfsMcpIngestResult(nodes = created)
  }

  @OptIn(ExperimentalEncodingApi::class)
  private fun ingestResource(
    request: AgentVfsMcpIngestRequest,
    resource: AgentVfsMcpResourceContent,
    index: Int,
    existing: List<AgentVfsNode>,
  ): AgentVfsNode {
    val mimeType = resource.mimeType
    val fileName = fileNameFor(resource.uri, mimeType, fallback = "resource-$index")
    val path = uniquePath(request.basePath, fileName, existing)
    val source = source(request, AgentVfsSourceType.MCP_EMBEDDED_RESOURCE, mcpUri = resource.uri)
    val text = resource.text
    if (text != null) {
      return vfs.writeText(
        path = path,
        text = text,
        options =
          AgentVfsWriteOptions(
            mimeType = mimeType ?: "text/plain",
            source = source,
            previewText = text.take(PREVIEW_LIMIT),
          ),
      )
    }

    val blob = resource.blobBase64
    if (!blob.isNullOrBlank()) {
      val bytes = Base64.decode(blob)
      return vfs.writeBytes(
        path = path,
        bytes = bytes,
        options =
          AgentVfsWriteOptions(
            mimeType = mimeType,
            source = source,
          ),
      )
    }

    return vfs.createResourceLink(
      path = path,
      uri = resource.uri ?: "mcp-resource://unknown/$index",
      mimeType = mimeType,
      source = source.copy(type = AgentVfsSourceType.MCP_RESOURCE_LINK),
    )
  }

  private fun ingestResourceLink(
    request: AgentVfsMcpIngestRequest,
    block: AgentVfsMcpContentBlock,
    index: Int,
    existing: List<AgentVfsNode>,
  ): AgentVfsNode {
    val uri = block.uri ?: block.resource?.uri ?: "mcp-resource://unknown/$index"
    val mimeType = block.mimeType ?: block.resource?.mimeType
    val name = block.name ?: fileNameFor(uri, mimeType, fallback = "resource-link-$index")
    return vfs.createResourceLink(
      path = uniquePath(request.basePath, name, existing),
      uri = uri,
      mimeType = mimeType,
      source = source(request, AgentVfsSourceType.MCP_RESOURCE_LINK, mcpUri = uri),
      previewText = uri,
    )
  }

  private fun source(
    request: AgentVfsMcpIngestRequest,
    type: AgentVfsSourceType,
    mcpUri: String? = null,
  ): AgentVfsSource =
    AgentVfsSource(
      type = type,
      connectorId = request.connectorId,
      toolName = request.toolName,
      toolCallId = request.toolCallId,
      mcpUri = mcpUri,
    )

  private fun uniquePath(base: AgentVfsPath, rawName: String, existing: List<AgentVfsNode>): String {
    val sanitized = AgentVfsPaths.sanitizeSegment(rawName)
    val dot = sanitized.lastIndexOf('.').takeIf { it > 0 }
    val stem = dot?.let { sanitized.substring(0, it) } ?: sanitized
    val ext = dot?.let { sanitized.substring(it) } ?: ""
    val occupied = existing.map { it.path.value }.toSet()
    var candidate = AgentVfsPaths.child(base, sanitized)
    var index = 2
    while (vfs.exists(candidate.value) || occupied.contains(candidate.value)) {
      candidate = AgentVfsPaths.child(base, "$stem-$index$ext")
      index++
    }
    return candidate.value
  }

  private fun fileNameFor(uri: String?, mimeType: String?, fallback: String): String {
    val fromUri =
      uri
        ?.substringBefore('?')
        ?.substringAfterLast('/')
        ?.substringAfterLast(':')
        ?.takeIf { it.isNotBlank() && it != uri.substringBefore('?') }
    val base = fromUri ?: fallback
    val sanitized = AgentVfsPaths.sanitizeSegment(base, fallback = fallback)
    return if (sanitized.contains('.')) sanitized else "$sanitized${extensionFor(mimeType)}"
  }

  private fun extensionFor(mimeType: String?): String =
    when (mimeType?.lowercase()) {
      "application/json", "text/json" -> ".json"
      "text/html", "text/html;profile=mcp-app" -> ".html"
      "text/markdown" -> ".md"
      "text/plain" -> ".txt"
      "image/png" -> ".png"
      "image/jpeg", "image/jpg" -> ".jpg"
      "audio/wav", "audio/x-wav" -> ".wav"
      "audio/mpeg" -> ".mp3"
      "application/pdf" -> ".pdf"
      else -> ".bin"
    }

  companion object {
    private const val PREVIEW_LIMIT = 1_000
  }
}
