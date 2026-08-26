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

/** Safe virtual workspace tools exposed to the agent instead of a real mobile shell. */
class AgentVfsTools(private val vfs: OkioAgentVirtualFileSystem) {
  fun ls(path: String = "/"): String =
    vfs.list(path).joinToString(separator = "\n") { node ->
      val marker = if (node.kind == AgentVfsNodeKind.DIRECTORY) "/" else ""
      "${node.name}$marker${node.mimeType?.let { "\t$it" } ?: ""}${node.sizeBytes?.let { "\t$it bytes" } ?: ""}"
    }

  fun tree(path: String = "/", maxDepth: Int = 8): String =
    vfs.tree(path, maxDepth = maxDepth).joinToString(separator = "\n") { entry ->
      val indent = "  ".repeat(entry.depth)
      val suffix = if (entry.node.kind == AgentVfsNodeKind.DIRECTORY) "/" else ""
      "$indent${entry.node.name}$suffix"
    }

  fun cat(path: String, maxChars: Int = 16_000): String = vfs.readText(path).take(maxChars.coerceAtLeast(1))

  fun head(path: String, maxChars: Int = 2_000): String = cat(path, maxChars = maxChars)

  fun stat(path: String): String {
    val node = vfs.stat(path) ?: return "not found: $path"
    return buildString {
      appendLine(node.path.value)
      appendLine("kind: ${node.kind}")
      node.mimeType?.let { appendLine("mimeType: $it") }
      node.sizeBytes?.let { appendLine("sizeBytes: $it") }
      node.checksumSha256?.let { appendLine("sha256: $it") }
      node.source.connectorId?.let { appendLine("connectorId: $it") }
      node.source.toolName?.let { appendLine("toolName: $it") }
      node.source.mcpUri?.let { appendLine("mcpUri: $it") }
    }.trimEnd()
  }

  fun search(query: String, within: String = "/", limit: Int = 20): String =
    vfs.searchText(query = query, within = within, limit = limit).joinToString(separator = "\n") { node ->
      "${node.path.value}${node.mimeType?.let { "\t$it" } ?: ""}"
    }

  fun mkdir(path: String): AgentVfsNode = vfs.createDirectory(path)

  fun writeText(path: String, text: String, mimeType: String = "text/plain"): AgentVfsNode =
    vfs.writeText(path, text, AgentVfsWriteOptions(mimeType = mimeType, source = AgentVfsSource(type = AgentVfsSourceType.GENERATED)))

  fun rm(path: String, recursive: Boolean = false): Boolean = vfs.delete(path, recursive = recursive)

  fun mv(from: String, to: String, overwrite: Boolean = false): AgentVfsNode = vfs.move(from, to, overwrite = overwrite)

  fun cp(from: String, to: String, overwrite: Boolean = false): AgentVfsNode = vfs.copy(from, to, overwrite = overwrite)
}
