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

data class AgentVfsUserAttachment(
  val fileName: String,
  val mimeType: String? = null,
  val text: String? = null,
  /** Base64 encoded attachment bytes. */
  val blobBase64: String? = null,
  val externalUri: String? = null,
)

data class AgentVfsUserAttachmentIngestRequest(
  val sessionId: String,
  val attachments: List<AgentVfsUserAttachment>,
  val basePath: AgentVfsPath = AgentVfsPaths.pathForSession(sessionId, "attachments"),
  val overwrite: Boolean = false,
)

data class AgentVfsUserAttachmentIngestResult(
  val nodes: List<AgentVfsNode>,
)

/**
 * Projects user-selected chat attachments into the same agent-visible workspace as MCP resources.
 *
 * Mobile hosts can still pass the original media to their native inference runtime. The VFS copy
 * gives the agent a stable artifact path for prompt context, future resource references, and
 * history compaction without exposing real device file paths.
 */
class AgentVfsUserAttachmentIngestor(private val vfs: OkioAgentVirtualFileSystem) {
  /**
   * Swift-friendly single-file entry point. Shared core owns the path layout so hosts do not need
   * to construct `/session/.../attachments/...` paths themselves.
   */
  fun ingestDefault(
    sessionId: String,
    fileName: String,
    mimeType: String?,
    text: String?,
    blobBase64: String?,
    externalUri: String?,
    overwrite: Boolean,
  ): AgentVfsNode =
    ingest(
      AgentVfsUserAttachmentIngestRequest(
        sessionId = sessionId,
        attachments =
          listOf(
            AgentVfsUserAttachment(
              fileName = fileName,
              mimeType = mimeType,
              text = text,
              blobBase64 = blobBase64,
              externalUri = externalUri,
            )
          ),
        overwrite = overwrite,
      )
    ).nodes.first()

  fun ingest(request: AgentVfsUserAttachmentIngestRequest): AgentVfsUserAttachmentIngestResult {
    vfs.createDirectory(
      path = request.basePath.value,
      source = AgentVfsSource(type = AgentVfsSourceType.USER_ATTACHMENT),
    )

    val created = mutableListOf<AgentVfsNode>()
    request.attachments.forEachIndexed { index, attachment ->
      created += ingestOne(request, attachment, index, created)
    }
    return AgentVfsUserAttachmentIngestResult(nodes = created)
  }

  @OptIn(ExperimentalEncodingApi::class)
  private fun ingestOne(
    request: AgentVfsUserAttachmentIngestRequest,
    attachment: AgentVfsUserAttachment,
    index: Int,
    existing: List<AgentVfsNode>,
  ): AgentVfsNode {
    val safeName = attachment.fileName.ifBlank { "attachment-$index${extensionFor(attachment.mimeType)}" }
    val path = uniquePath(request.basePath, safeName, existing, overwrite = request.overwrite)
    val source =
      AgentVfsSource(
        type = AgentVfsSourceType.USER_ATTACHMENT,
        externalUri = attachment.externalUri,
      )

    attachment.text?.let { text ->
      return vfs.writeText(
        path = path,
        text = text,
        options =
          AgentVfsWriteOptions(
            mimeType = attachment.mimeType ?: "text/plain",
            source = source,
            previewText = text.take(PREVIEW_LIMIT),
            overwrite = request.overwrite,
          ),
      )
    }

    attachment.blobBase64?.takeIf { it.isNotBlank() }?.let { blob ->
      return vfs.writeBytes(
        path = path,
        bytes = Base64.decode(blob),
        options =
          AgentVfsWriteOptions(
            mimeType = attachment.mimeType,
            source = source,
            overwrite = request.overwrite,
          ),
      )
    }

    attachment.externalUri?.takeIf { it.isNotBlank() }?.let { uri ->
      return vfs.createResourceLink(
        path = path,
        uri = uri,
        mimeType = attachment.mimeType,
        source = source.copy(type = AgentVfsSourceType.USER_ATTACHMENT, externalUri = uri),
        previewText = uri,
        overwrite = request.overwrite,
      )
    }

    throw AgentVfsException("Attachment has no text, blob, or external URI: ${attachment.fileName}")
  }

  private fun uniquePath(
    base: AgentVfsPath,
    rawName: String,
    existing: List<AgentVfsNode>,
    overwrite: Boolean,
  ): String {
    val sanitized = AgentVfsPaths.sanitizeSegment(rawName, fallback = "attachment")
    if (overwrite) {
      return AgentVfsPaths.child(base, sanitized).value
    }

    val dot = sanitized.lastIndexOf('.').takeIf { it > 0 }
    val stem = dot?.let { sanitized.substring(0, it) } ?: sanitized
    val ext = dot?.let { sanitized.substring(it) } ?: ""
    val occupied = existing.map { it.path.value }.toSet()
    var candidate = AgentVfsPaths.child(base, sanitized)
    var suffix = 2
    while (vfs.exists(candidate.value) || occupied.contains(candidate.value)) {
      candidate = AgentVfsPaths.child(base, "$stem-$suffix$ext")
      suffix++
    }
    return candidate.value
  }

  private fun extensionFor(mimeType: String?): String =
    when (mimeType?.lowercase()) {
      "application/json", "text/json" -> ".json"
      "text/markdown" -> ".md"
      "text/plain" -> ".txt"
      "image/png" -> ".png"
      "image/jpeg", "image/jpg" -> ".jpg"
      "image/webp" -> ".webp"
      "audio/wav", "audio/x-wav" -> ".wav"
      "audio/mpeg" -> ".mp3"
      "audio/mp4", "audio/aac" -> ".m4a"
      "application/pdf" -> ".pdf"
      else -> ".bin"
    }

  companion object {
    private const val PREVIEW_LIMIT = 1_000
  }
}
