/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.google.ai.edge.gallery.runtime.chat

import com.google.ai.edge.gallery.ui.unifiedchat.session.UnifiedChatSessionFileStore
import com.google.ai.edge.gallery.ui.unifiedchat.session.UnifiedChatPersistedSession
import com.ugot.chatkit.runtime.UgotChatSessionRepository

/** Preserves the existing Gallery file format behind the shared ChatKit persistence port. */
class GalleryChatSessionRepository(
  private val fileStore: UnifiedChatSessionFileStore,
) : UgotChatSessionRepository {
  override suspend fun load(id: String): UnifiedChatPersistedSession? = fileStore.load(id)

  override suspend fun list(): List<UnifiedChatPersistedSession> = fileStore.list()

  override suspend fun save(session: UnifiedChatPersistedSession) = fileStore.save(session)

  override suspend fun delete(id: String) = fileStore.delete(id)

  override suspend fun clear() = fileStore.clear()
}
