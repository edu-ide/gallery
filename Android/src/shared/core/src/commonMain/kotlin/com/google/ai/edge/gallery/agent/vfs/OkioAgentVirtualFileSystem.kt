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

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okio.ByteString.Companion.toByteString
import okio.FileSystem
import okio.Path
import okio.Path.Companion.toPath
import okio.buffer

/**
 * KMP-friendly virtual filesystem for agent artifacts.
 *
 * The visible namespace is virtual and Unix-like (`/session/<id>/...`, `/user/...`, `/sandbox/...`).
 * File bytes are stored below [root]/nodes while metadata is persisted as a JSON manifest. A Room or
 * SQLDelight metadata backend can replace the manifest later without changing the public API.
 */
class OkioAgentVirtualFileSystem(
  private val fileSystem: FileSystem,
  private val root: Path,
  private val clockEpochMs: () -> Long = { 0L },
) {
  private val json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    prettyPrint = false
  }

  private val nodesRoot = root / "nodes"
  private val manifestPath = root / "manifest.json"
  private val nodes = linkedMapOf<String, AgentVfsNode>()

  init {
    bootstrap()
  }

  fun snapshot(): AgentVfsManifest = AgentVfsManifest(nodes = nodes.values.sortedBy { it.path.value })

  fun exists(path: String): Boolean = nodes.containsKey(AgentVfsPath.parse(path).value)

  fun stat(path: String): AgentVfsNode? = nodes[AgentVfsPath.parse(path).value]

  fun createDirectory(path: String, source: AgentVfsSource = AgentVfsSource(type = AgentVfsSourceType.SYSTEM)): AgentVfsNode {
    val parsed = AgentVfsPath.parse(path)
    val node = ensureDirectory(parsed, source = source, persistAfter = true)
    return node
  }

  fun writeBytes(path: String, bytes: ByteArray, options: AgentVfsWriteOptions = AgentVfsWriteOptions()): AgentVfsNode {
    val parsed = AgentVfsPath.parse(path)
    if (parsed == AgentVfsPath.ROOT) throw AgentVfsException("Cannot write file at VFS root")
    val existing = nodes[parsed.value]
    if (existing?.kind == AgentVfsNodeKind.DIRECTORY) {
      throw AgentVfsException("Cannot overwrite directory with file: ${parsed.value}")
    }
    if (existing != null && !options.overwrite) {
      throw AgentVfsException("VFS file already exists: ${parsed.value}")
    }

    val parent = parsed.parent ?: AgentVfsPath.ROOT
    ensureDirectory(parent, source = options.source, persistAfter = false)

    val storage = storagePath(parsed)
    storage.parent?.let { fileSystem.createDirectories(it) }
    fileSystem.write(storage) {
      write(bytes)
    }

    val now = clockEpochMs()
    val preview = options.previewText ?: previewFor(bytes, options.mimeType)
    val node =
      AgentVfsNode(
        id = existing?.id ?: stableId(parsed),
        path = parsed,
        parentPath = parent,
        name = parsed.name,
        kind = AgentVfsNodeKind.FILE,
        scope = AgentVfsPaths.scopeOf(parsed),
        mimeType = options.mimeType,
        sizeBytes = bytes.size.toLong(),
        checksumSha256 = bytes.toByteString().sha256().hex(),
        previewText = preview,
        source = options.source,
        createdAtEpochMs = existing?.createdAtEpochMs ?: now,
        updatedAtEpochMs = now,
      )
    nodes[parsed.value] = node
    persistManifest()
    return node
  }

  fun writeText(path: String, text: String, options: AgentVfsWriteOptions = AgentVfsWriteOptions(mimeType = "text/plain")): AgentVfsNode =
    writeBytes(
      path = path,
      bytes = text.encodeToByteArray(),
      options =
        if (options.previewText == null) {
          options.copy(previewText = text.take(PREVIEW_LIMIT))
        } else {
          options
        },
    )

  fun createResourceLink(
    path: String,
    uri: String,
    mimeType: String? = null,
    source: AgentVfsSource = AgentVfsSource(type = AgentVfsSourceType.MCP_RESOURCE_LINK, mcpUri = uri),
    previewText: String? = null,
    overwrite: Boolean = true,
  ): AgentVfsNode {
    val parsed = AgentVfsPath.parse(path)
    if (parsed == AgentVfsPath.ROOT) throw AgentVfsException("Cannot create resource link at VFS root")
    val existing = nodes[parsed.value]
    if (existing != null && !overwrite) throw AgentVfsException("VFS node already exists: ${parsed.value}")
    if (existing?.kind == AgentVfsNodeKind.DIRECTORY) throw AgentVfsException("Cannot overwrite directory with resource link: ${parsed.value}")

    val parent = parsed.parent ?: AgentVfsPath.ROOT
    ensureDirectory(parent, source = source, persistAfter = false)
    val now = clockEpochMs()
    val node =
      AgentVfsNode(
        id = existing?.id ?: stableId(parsed),
        path = parsed,
        parentPath = parent,
        name = parsed.name,
        kind = AgentVfsNodeKind.RESOURCE_LINK,
        scope = AgentVfsPaths.scopeOf(parsed),
        mimeType = mimeType,
        previewText = previewText ?: uri,
        source = source.copy(mcpUri = source.mcpUri ?: uri, externalUri = source.externalUri ?: uri),
        createdAtEpochMs = existing?.createdAtEpochMs ?: now,
        updatedAtEpochMs = now,
      )
    nodes[parsed.value] = node
    persistManifest()
    return node
  }

  fun readBytes(path: String): ByteArray {
    val parsed = AgentVfsPath.parse(path)
    val node = requireNode(parsed)
    if (node.kind != AgentVfsNodeKind.FILE) throw AgentVfsException("VFS node is not a file: ${parsed.value}")
    return fileSystem.read(storagePath(parsed)) { readByteArray() }
  }

  fun readText(path: String): String = readBytes(path).decodeToString()

  fun list(path: String): List<AgentVfsNode> {
    val parsed = AgentVfsPath.parse(path)
    val node = requireNode(parsed)
    if (node.kind != AgentVfsNodeKind.DIRECTORY) throw AgentVfsException("VFS node is not a directory: ${parsed.value}")
    return nodes.values
      .filter { it.parentPath == parsed }
      .sortedWith(compareBy<AgentVfsNode> { it.kind != AgentVfsNodeKind.DIRECTORY }.thenBy { it.name })
  }

  fun tree(path: String = "/", maxDepth: Int = 8): List<AgentVfsTreeEntry> {
    val rootNode = requireNode(AgentVfsPath.parse(path))
    val out = mutableListOf<AgentVfsTreeEntry>()
    fun visit(node: AgentVfsNode, depth: Int) {
      out += AgentVfsTreeEntry(node = node, depth = depth)
      if (depth >= maxDepth || node.kind != AgentVfsNodeKind.DIRECTORY) return
      list(node.path.value).forEach { visit(it, depth + 1) }
    }
    visit(rootNode, 0)
    return out
  }

  fun searchText(query: String, within: String = "/", limit: Int = 20): List<AgentVfsNode> {
    val normalizedQuery = query.trim().lowercase()
    if (normalizedQuery.isEmpty()) return emptyList()
    val rootPath = AgentVfsPath.parse(within)
    val prefix = if (rootPath.value == "/") "/" else "${rootPath.value}/"
    return nodes.values
      .asSequence()
      .filter { it.kind == AgentVfsNodeKind.FILE || it.kind == AgentVfsNodeKind.RESOURCE_LINK }
      .filter { it.path == rootPath || it.path.value.startsWith(prefix) }
      .filter { node ->
        node.name.lowercase().contains(normalizedQuery) ||
          node.previewText?.lowercase()?.contains(normalizedQuery) == true ||
          node.source.mcpUri?.lowercase()?.contains(normalizedQuery) == true
      }
      .take(limit.coerceAtLeast(1))
      .toList()
  }

  fun move(from: String, to: String, overwrite: Boolean = false): AgentVfsNode {
    val source = AgentVfsPath.parse(from)
    val target = AgentVfsPath.parse(to)
    val sourceNode = requireNode(source)
    if (source == AgentVfsPath.ROOT) throw AgentVfsException("Cannot move VFS root")
    val existingTarget = nodes[target.value]
    if (existingTarget != null && !overwrite) throw AgentVfsException("Target already exists: ${target.value}")
    if (existingTarget?.kind == AgentVfsNodeKind.DIRECTORY && sourceNode.kind != AgentVfsNodeKind.DIRECTORY) {
      throw AgentVfsException("Cannot overwrite directory with non-directory: ${target.value}")
    }

    ensureDirectory(target.parent ?: AgentVfsPath.ROOT, source = sourceNode.source, persistAfter = false)

    val affected = nodes.values.filter { it.path == source || it.path.value.startsWith("${source.value}/") }
    if (existingTarget != null) delete(target.value, recursive = true)

    val sourceStorage = storagePath(source)
    val targetStorage = storagePath(target)
    targetStorage.parent?.let { fileSystem.createDirectories(it) }
    if (fileSystem.exists(sourceStorage)) {
      fileSystem.atomicMove(sourceStorage, targetStorage)
    }

    affected.forEach { nodes.remove(it.path.value) }
    val now = clockEpochMs()
    val remapped = affected.map { node ->
      val newPath = replacePrefix(node.path, source, target)
      node.copy(
        path = newPath,
        parentPath = newPath.parent,
        name = newPath.name,
        scope = AgentVfsPaths.scopeOf(newPath),
        updatedAtEpochMs = now,
      )
    }
    remapped.forEach { nodes[it.path.value] = it }
    persistManifest()
    return requireNode(target)
  }

  fun copy(from: String, to: String, overwrite: Boolean = false): AgentVfsNode {
    val source = AgentVfsPath.parse(from)
    val target = AgentVfsPath.parse(to)
    val sourceNode = requireNode(source)
    if (sourceNode.kind == AgentVfsNodeKind.FILE) {
      return writeBytes(
        path = target.value,
        bytes = readBytes(source.value),
        options =
          AgentVfsWriteOptions(
            mimeType = sourceNode.mimeType,
            source = sourceNode.source,
            previewText = sourceNode.previewText,
            overwrite = overwrite,
          ),
      )
    }
    if (sourceNode.kind == AgentVfsNodeKind.RESOURCE_LINK) {
      return createResourceLink(
        path = target.value,
        uri = sourceNode.source.mcpUri ?: sourceNode.source.externalUri ?: sourceNode.previewText ?: sourceNode.name,
        mimeType = sourceNode.mimeType,
        source = sourceNode.source,
        previewText = sourceNode.previewText,
        overwrite = overwrite,
      )
    }

    createDirectory(target.value, source = sourceNode.source)
    list(source.value).forEach { child ->
      copy(child.path.value, AgentVfsPaths.child(target, child.name).value, overwrite = overwrite)
    }
    return requireNode(target)
  }

  fun delete(path: String, recursive: Boolean = false): Boolean {
    val parsed = AgentVfsPath.parse(path)
    if (parsed == AgentVfsPath.ROOT) throw AgentVfsException("Cannot delete VFS root")
    val existing = nodes[parsed.value] ?: return false
    val children = nodes.values.filter { it.parentPath == parsed }
    if (children.isNotEmpty() && !recursive) throw AgentVfsException("Directory is not empty: ${parsed.value}")

    val affected = nodes.values.filter { it.path == parsed || it.path.value.startsWith("${parsed.value}/") }
    affected.forEach { nodes.remove(it.path.value) }
    val storage = storagePath(parsed)
    if (fileSystem.exists(storage)) {
      fileSystem.deleteRecursively(storage, mustExist = false)
    }
    persistManifest()
    return existing.path.value.isNotEmpty()
  }

  fun contextSummary(within: String = "/", limit: Int = 20): String =
    AgentVfsContextProjector.summary(tree(within).map { it.node }, limit = limit)

  private fun bootstrap() {
    fileSystem.createDirectories(root)
    fileSystem.createDirectories(nodesRoot)
    val manifest = readManifestOrNull()
    if (manifest != null) {
      manifest.nodes.forEach { nodes[it.path.value] = it }
    }
    ensureSystemRoots()
    persistManifest()
  }

  private fun readManifestOrNull(): AgentVfsManifest? {
    if (!fileSystem.exists(manifestPath)) return null
    return runCatching {
      val text = fileSystem.read(manifestPath) { readUtf8() }
      json.decodeFromString(AgentVfsManifest.serializer(), text)
    }.getOrNull()
  }

  private fun ensureSystemRoots() {
    ensureDirectory(AgentVfsPath.ROOT, source = AgentVfsSource(type = AgentVfsSourceType.SYSTEM), persistAfter = false)
    ensureDirectory(AgentVfsPath.parse("/session"), source = AgentVfsSource(type = AgentVfsSourceType.SYSTEM), persistAfter = false)
    ensureDirectory(AgentVfsPath.parse("/user"), source = AgentVfsSource(type = AgentVfsSourceType.SYSTEM), persistAfter = false)
    ensureDirectory(AgentVfsPath.parse("/sandbox"), source = AgentVfsSource(type = AgentVfsSourceType.SYSTEM), persistAfter = false)
  }

  private fun ensureDirectory(path: AgentVfsPath, source: AgentVfsSource, persistAfter: Boolean): AgentVfsNode {
    val existing = nodes[path.value]
    if (existing != null) {
      if (existing.kind != AgentVfsNodeKind.DIRECTORY) throw AgentVfsException("VFS node is not a directory: ${path.value}")
      return existing
    }
    path.parent?.let { ensureDirectory(it, source = source, persistAfter = false) }
    val now = clockEpochMs()
    val node =
      AgentVfsNode(
        id = stableId(path),
        path = path,
        parentPath = path.parent,
        name = path.name,
        kind = AgentVfsNodeKind.DIRECTORY,
        scope = AgentVfsPaths.scopeOf(path),
        source = source,
        createdAtEpochMs = now,
        updatedAtEpochMs = now,
      )
    nodes[path.value] = node
    fileSystem.createDirectories(storagePath(path))
    if (persistAfter) persistManifest()
    return node
  }

  private fun requireNode(path: AgentVfsPath): AgentVfsNode =
    nodes[path.value] ?: throw AgentVfsException("VFS path not found: ${path.value}")

  private fun persistManifest() {
    fileSystem.createDirectories(root)
    fileSystem.write(manifestPath) {
      writeUtf8(json.encodeToString(snapshot()))
    }
  }

  private fun storagePath(path: AgentVfsPath): Path {
    val relative = if (path.value == "/") "" else path.value.trimStart('/')
    return if (relative.isEmpty()) nodesRoot else nodesRoot / relative
  }

  private fun stableId(path: AgentVfsPath): String = "vfs_${path.value.encodeToByteArray().toByteString().sha256().hex().take(24)}"

  private fun replacePrefix(path: AgentVfsPath, from: AgentVfsPath, to: AgentVfsPath): AgentVfsPath {
    if (path == from) return to
    val suffix = path.value.removePrefix(from.value).trimStart('/')
    return AgentVfsPath.parse(if (to.value == "/") "/$suffix" else "${to.value}/$suffix")
  }

  private fun previewFor(bytes: ByteArray, mimeType: String?): String? {
    val type = mimeType?.lowercase() ?: return null
    if (!type.startsWith("text/") && !type.contains("json") && !type.contains("xml") && !type.contains("markdown")) return null
    return runCatching { bytes.decodeToString().take(PREVIEW_LIMIT) }.getOrNull()
  }

  companion object {
    private const val PREVIEW_LIMIT = 1_000

    fun atPath(fileSystem: FileSystem, rootPath: String, clockEpochMs: () -> Long = { 0L }): OkioAgentVirtualFileSystem =
      OkioAgentVirtualFileSystem(fileSystem = fileSystem, root = rootPath.toPath(), clockEpochMs = clockEpochMs)
  }
}

object AgentVfsContextProjector {
  fun summary(nodes: List<AgentVfsNode>, limit: Int = 20): String {
    val visible = nodes.filter { it.kind != AgentVfsNodeKind.DIRECTORY }.take(limit)
    if (visible.isEmpty()) return "Available agent files: none"
    return buildString {
      appendLine("Available agent files:")
      visible.forEach { node ->
        append("- ").append(node.path.value)
        node.mimeType?.let { append(" (").append(it).append(")") }
        node.sizeBytes?.let { append(", ").append(it).append(" bytes") }
        node.source.mcpUri?.let { append(", uri: ").append(it) }
        appendLine()
        node.previewText?.takeIf { it.isNotBlank() }?.let { preview ->
          append("  Preview: ").append(preview.replace('\n', ' ').take(240)).appendLine()
        }
      }
    }.trimEnd()
  }
}
