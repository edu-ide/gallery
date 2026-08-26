/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

package com.google.ai.edge.gallery.ui.unifiedchat

/** Builds a product-neutral fallback label when a connector does not provide display metadata. */
fun formatConnectorDisplayLabel(connectorId: String): String {
  val normalized =
    connectorId
      .substringAfterLast("://")
      .substringBefore('/')
      .substringBefore('.')
      .split('_', '-')
      .filter(String::isNotBlank)
      .joinToString(" ") { token ->
        token.lowercase().replaceFirstChar { firstChar -> firstChar.titlecase() }
      }
  return normalized.ifBlank { connectorId }
}
