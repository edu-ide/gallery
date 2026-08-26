/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 */

package com.ugot.chatkit.runtime

import com.google.ai.edge.gallery.ui.unifiedchat.session.UnifiedChatPersistedSession

/** Single persistence boundary for the shared transcript and runtime session metadata. */
interface UgotChatSessionRepository {
  suspend fun load(id: String): UnifiedChatPersistedSession?

  suspend fun list(): List<UnifiedChatPersistedSession>

  suspend fun save(session: UnifiedChatPersistedSession)

  suspend fun delete(id: String)

  suspend fun clear()
}
