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

object AgentVfsPaths {
  private val unsafeFileName = Regex("[^A-Za-z0-9._-]+")

  fun normalize(raw: String): String {
    val prepared = raw.trim().replace('\\', '/')
    val absolute = if (prepared.startsWith('/')) prepared else "/$prepared"
    val parts = mutableListOf<String>()
    absolute.split('/').forEach { part ->
      when {
        part.isEmpty() || part == "." -> Unit
        part == ".." -> throw AgentVfsException("Parent traversal is not allowed in VFS paths: $raw")
        part.any { it.code < 32 } -> throw AgentVfsException("Control characters are not allowed in VFS paths: $raw")
        else -> parts += part
      }
    }
    return if (parts.isEmpty()) "/" else parts.joinToString(prefix = "/", separator = "/")
  }

  fun isNormalized(value: String): Boolean {
    if (!value.startsWith('/')) return false
    if (value.length > 1 && value.endsWith('/')) return false
    if (value.contains("//")) return false
    return runCatching { normalize(value) == value }.getOrDefault(false)
  }

  fun segments(value: String): List<String> =
    if (value == "/") emptyList() else value.trim('/').split('/').filter { it.isNotEmpty() }

  fun parentOf(path: AgentVfsPath): AgentVfsPath? {
    if (path.value == "/") return null
    val index = path.value.lastIndexOf('/')
    return if (index <= 0) AgentVfsPath.ROOT else AgentVfsPath(path.value.substring(0, index))
  }

  fun child(parent: AgentVfsPath, rawName: String): AgentVfsPath {
    val name = sanitizeSegment(rawName)
    return AgentVfsPath.parse(if (parent.value == "/") "/$name" else "${parent.value}/$name")
  }

  fun scopeOf(path: AgentVfsPath): AgentVfsScope? {
    val first = path.segments.firstOrNull() ?: return null
    return when (first) {
      "session" -> AgentVfsScope.SESSION
      "user" -> AgentVfsScope.USER
      "sandbox" -> AgentVfsScope.SANDBOX
      else -> null
    }
  }

  /** Sanitize a user-visible file name. URI/path separators are treated as basename boundaries. */
  fun sanitizeSegment(raw: String, fallback: String = "file"): String {
    val candidate = raw.substringAfterLast('/').substringAfterLast(':').ifBlank { fallback }
    val sanitized = unsafeFileName.replace(candidate, "_").trim('.', '_', '-').ifBlank { fallback }
    return sanitized.take(120)
  }

  /** Sanitize an opaque virtual path segment such as connector ids without dropping slash prefixes. */
  fun sanitizeOpaqueSegment(raw: String, fallback: String = "item"): String {
    val candidate = raw.trim().ifBlank { fallback }
    val sanitized = unsafeFileName.replace(candidate, "_").trim('.', '_', '-').ifBlank { fallback }
    return sanitized.take(120)
  }

  fun pathForSession(sessionId: String, vararg parts: String): AgentVfsPath =
    scopedPath("session", sanitizeOpaqueSegment(sessionId, fallback = "session"), *parts)

  fun pathForUser(vararg parts: String): AgentVfsPath = scopedPath("user", *parts)

  fun pathForSandbox(vararg parts: String): AgentVfsPath = scopedPath("sandbox", *parts)

  private fun scopedPath(vararg parts: String): AgentVfsPath {
    val sanitized = parts.filter { it.isNotBlank() }.map { sanitizeOpaqueSegment(it) }
    return AgentVfsPath.parse(sanitized.joinToString(prefix = "/", separator = "/"))
  }
}
