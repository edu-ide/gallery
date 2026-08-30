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

package com.ugot.chatkit.mcp.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Platform-neutral MCP tool descriptor consumed by the model-facing router prompt. */
data class AgentToolPlanningDescriptor(
  val name: String,
  val title: String,
  val description: String,
  val isReadOnly: Boolean? = null,
  val isDestructive: Boolean? = null,
  val hasWidget: Boolean = false,
  val requiredParameters: List<String> = emptyList(),
  val parametersSummary: String = "",
)

/** Request to build a model-facing, bounded, provider-agnostic MCP tool-router prompt. */
data class AgentToolPlanningRequest(
  val userPrompt: String,
  val connectorId: String,
  val connectorTitle: String,
  val tools: List<AgentToolPlanningDescriptor>,
  val previousObservations: List<AgentToolLoopObservation> = emptyList(),
  val stepIndex: Int,
  val maxSteps: Int,
)

/** Parsed result returned by the local planner model. */
data class AgentToolPlanningDecision(
  val toolName: String?,
  val argumentsJson: String = "{}",
  val entityReference: String? = null,
  val intentEffect: String? = null,
  val confidence: Double = 0.0,
  val requiresTool: Boolean = toolName != null,
) {
  val shouldUseTool: Boolean
    get() = !toolName.isNullOrBlank() && confidence >= 0.55
}

private val planningJson = Json {
  ignoreUnknownKeys = true
  isLenient = true
}

private const val MAX_PLANNING_PROMPT_CHARS = 2_600
private const val MAX_TOOL_SUMMARY_CHARS = 1_250

/**
 * Builds the single canonical MCP tool-planning prompt used by mobile hosts.
 *
 * Hosts still own model invocation and tool side effects. Shared core owns the protocol-neutral
 * contract: bounded steps, JSON-only response, no hidden tools, no destructive read handling, and
 * visible-name-to-entity-reference behavior.
 */
fun buildAgentToolPlanningPrompt(request: AgentToolPlanningRequest): String {
  val tools = request.tools.toPromptSummary(request.userPrompt)
  val previousObservations = request.previousObservations.toPromptSummary()

  return """
    You route one user request to at most one MCP tool for "${request.connectorTitle}".
    Current step: ${request.stepIndex} of ${request.maxSteps.coerceAtLeast(1)}.
    Return ONLY one JSON object: {"tool_name":"exact listed name or null","arguments":{},"entity_reference":"visible target or null","intent_effect":"read|write|destructive|none","confidence":0.0,"requires_tool":false}

    Rules:
    - Use only an exact listed tool; otherwise return tool_name null. Never invent hidden tools.
    - Match semantic intent in any language. Prefer the most specific read-only display tool.
    - A read request must never choose write/destructive/delete/clear/reset. Mutation requires an explicit user request.
    - Fill arguments only from the message or safe defaults. Do not fabricate IDs, birth data, gender, dates, or times.
    - Do not invent opaque IDs; put a visible person/profile/place name in entity_reference instead.
    - For generic today/current reads, prefer a no-required-argument tool that supports a saved/default target.
    - After missing arguments, do not repeat the same call; choose a safe compatible alternative or stop.
    - Set confidence >= 0.6 only for a clear match; otherwise use 0 and tool_name null.

    Available MCP tools (retrieved and ranked from the connector catalog):
    $tools

    User message: ${request.userPrompt.oneLineForPrompt(limit = 420)}
    Previous tool observations: $previousObservations
  """.trimIndent().trimForPrompt(MAX_PLANNING_PROMPT_CHARS)
}

/**
 * Resolves a model-formatting failure without granting any new side effect authority.
 *
 * This deterministic route is deliberately narrower than the model planner: it can only choose a
 * non-destructive, read-only tool with no required arguments, and only when one catalog entry has
 * a strong lexical lead over the other safe entries. Hosts may run it before model planning to
 * avoid a slow and unreliable router inference for an explicit, side-effect-free catalog match.
 */
fun selectSafeReadToolFallback(
  userPrompt: String,
  tools: List<AgentToolPlanningDescriptor>,
): AgentToolPlanningDescriptor? =
  tools.selectStrongNoArgumentMatch(userPrompt) {
    it.isReadOnly == true && it.isDestructive != true
  }

/**
 * Finds an unannotated no-argument candidate that a host may present for explicit approval.
 *
 * Returning a descriptor does not authorize execution. Hosts must route a non-read-only result
 * through their normal approval gate. Explicitly destructive tools remain ineligible.
 */
fun List<AgentToolPlanningDescriptor>.selectApprovalGatedToolFallbackCandidate(
  userPrompt: String,
): AgentToolPlanningDescriptor? =
  selectStrongNoArgumentMatch(userPrompt) {
    it.isDestructive != true
  }

private fun List<AgentToolPlanningDescriptor>.selectStrongNoArgumentMatch(
  userPrompt: String,
  isEligible: (AgentToolPlanningDescriptor) -> Boolean,
): AgentToolPlanningDescriptor? {
  val userTerms = userPrompt.promptTerms() - FALLBACK_STOP_TERMS
  if (userTerms.isEmpty()) return null

  val ranked =
    asSequence()
      .filter { isEligible(it) && it.requiredParameters.isEmpty() }
      .map { tool -> tool to tool.lexicalRelevanceScore(userTerms) }
      .sortedByDescending { (_, score) -> score }
      .toList()
  val best = ranked.firstOrNull() ?: return null
  if (best.second < MIN_SAFE_FALLBACK_SCORE) return null
  val runnerUpScore = ranked.getOrNull(1)?.second ?: Int.MIN_VALUE
  if (best.second == runnerUpScore) return null
  return best.first
}

/** Parse the model's router output without binding the app to a provider-specific response shape. */
fun parseAgentToolPlanningDecision(rawText: String): AgentToolPlanningDecision? {
  val candidates = listOfNotNull(
    rawText.trim(),
    fencedJsonBody(rawText),
    firstJsonObjectSubstring(rawText),
  ).filter { it.isNotBlank() }.distinct()

  for (candidate in candidates) {
    val parsed = runCatching { planningJson.parseToJsonElement(candidate).jsonObject }.getOrNull() ?: continue
    return parsed.toPlanningDecision()
  }
  return null
}

private val NULL_WORDS = setOf("", "none", "null", "no_tool", "no tool", "model")

private fun JsonObject.toPlanningDecision(): AgentToolPlanningDecision {
  val rawTool = firstString("tool_name", "toolName", "tool", "name")?.trim()
  val toolName = rawTool?.takeIf { it.lowercase() !in NULL_WORDS }
  val arguments = this["arguments"] ?: this["args"] ?: JsonObject(emptyMap())
  val argumentsJson = when (arguments) {
    is JsonObject -> arguments.toString()
    else -> JsonObject(emptyMap()).toString()
  }
  val confidence = firstDouble("confidence", "score") ?: if (toolName == null) 0.0 else 0.7
  val requiresTool = firstBoolean("requires_tool", "requiresTool", "needs_tool", "needsTool") ?: (toolName != null)
  val entityReference = firstString(
    "entity_reference",
    "entityReference",
    "target_reference",
    "targetReference",
    "profile_name",
    "profileName",
    "name_reference",
    "nameReference",
  )?.trim()?.takeIf { it.isNotEmpty() && it.lowercase() !in NULL_WORDS }
  val intentEffect = firstString(
    "intent_effect",
    "intentEffect",
    "effect",
    "tool_effect",
    "toolEffect",
  )?.trim()?.takeIf { it.isNotEmpty() && it.lowercase() != "null" }

  return AgentToolPlanningDecision(
    toolName = toolName,
    argumentsJson = argumentsJson,
    entityReference = entityReference,
    intentEffect = intentEffect,
    confidence = confidence,
    requiresTool = requiresTool,
  )
}

private fun JsonObject.firstString(vararg keys: String): String? =
  keys.firstNotNullOfOrNull { key ->
    when (val element = this[key]) {
      is JsonPrimitive -> element.contentOrNull
      else -> null
    }
  }

private fun JsonObject.firstDouble(vararg keys: String): Double? =
  keys.firstNotNullOfOrNull { key ->
    val primitive = this[key]?.jsonPrimitive ?: return@firstNotNullOfOrNull null
    primitive.doubleOrNull ?: primitive.contentOrNull?.trim()?.toDoubleOrNull()
  }

private fun JsonObject.firstBoolean(vararg keys: String): Boolean? =
  keys.firstNotNullOfOrNull { key ->
    val primitive = this[key]?.jsonPrimitive ?: return@firstNotNullOfOrNull null
    primitive.booleanOrNull ?: when (primitive.contentOrNull?.trim()?.lowercase()) {
      "true", "yes", "1" -> true
      "false", "no", "0" -> false
      else -> null
    }
  }

private fun List<AgentToolPlanningDescriptor>.toPromptSummary(userPrompt: String): String {
  if (isEmpty()) return "none"
  val ranked = rankForPrompt(userPrompt)
  val candidates = buildList {
    addAll(ranked.take(3))
    ranked.firstOrNull { it.isReadOnly == true && it.requiredParameters.isEmpty() }?.let(::add)
    ranked.firstOrNull { it.isReadOnly != true && it.isDestructive != true }?.let(::add)
    ranked.firstOrNull { it.hasWidget }?.let(::add)
    addAll(ranked)
  }.distinctBy(AgentToolPlanningDescriptor::name)

  val selected = mutableListOf<String>()
  var usedChars = 0
  for (tool in candidates) {
    val line = tool.toPromptLine()
    if (selected.isNotEmpty() && usedChars + line.length + 1 > MAX_TOOL_SUMMARY_CHARS) continue
    selected += line
    usedChars += line.length + 1
  }
  return selected.joinToString("\n")
}

private fun List<AgentToolPlanningDescriptor>.rankForPrompt(
  userPrompt: String
): List<AgentToolPlanningDescriptor> {
  val userTerms = userPrompt.promptTerms()
  return withIndex()
    .sortedWith(
      compareByDescending<IndexedValue<AgentToolPlanningDescriptor>> { indexed ->
        indexed.value.relevanceScore(userTerms)
      }.thenBy { it.index }
    )
    .map(IndexedValue<AgentToolPlanningDescriptor>::value)
}

private fun AgentToolPlanningDescriptor.relevanceScore(userTerms: Set<String>): Int {
  val lexicalScore = lexicalRelevanceScore(userTerms)
  val utilityScore =
    (if (isReadOnly == true) 3 else 0) +
      (if (requiredParameters.isEmpty()) 3 else 0) +
      (if (hasWidget) 1 else 0) +
      (if (description.promptTerms().any { it in DEFAULT_TARGET_TERMS }) 2 else 0) -
      (if (isDestructive == true) 8 else 0)
  return lexicalScore + utilityScore
}

private fun AgentToolPlanningDescriptor.lexicalRelevanceScore(userTerms: Set<String>): Int {
  val identityTerms = "$name $title".promptTerms()
  val descriptionTerms = description.promptTerms()
  return userTerms.sumOf { term ->
    when {
      term in identityTerms -> 18
      term in descriptionTerms -> 8
      term.length >= 4 && identityTerms.any { it.contains(term) || term.contains(it) } -> 10
      term.length >= 4 && descriptionTerms.any { it.contains(term) || term.contains(it) } -> 4
      else -> 0
    }
  }
}

private fun AgentToolPlanningDescriptor.toPromptLine(): String {
  val effect = when {
    isDestructive == true -> "destructive"
    isReadOnly == true -> "read"
    else -> "write-or-unknown"
  }
  val required = requiredParameters.joinToString(", ").ifBlank { "none" }.trimForPrompt(96)
  return "- $name | ${title.oneLineForPrompt(64)} | $effect | required=$required | " +
    description.oneLineForPrompt(120)
}

private fun List<AgentToolLoopObservation>.toPromptSummary(): String {
  if (isEmpty()) return "none"
  return takeLast(3).joinToString("; ") { observation ->
    "tool=${observation.toolName}, status=${observation.status}, args=" +
      "${observation.argumentsPreview.oneLineForPrompt(80)}, output=" +
      observation.outputText.oneLineForPrompt(180)
  }.trimForPrompt(520)
}

private val DEFAULT_TARGET_TERMS =
  setOf("today", "current", "daily", "default", "saved", "profile", "without", "optional")

private const val MIN_SAFE_FALLBACK_SCORE = 16
private val FALLBACK_STOP_TERMS =
  setOf(
    "about",
    "could",
    "for",
    "give",
    "get",
    "me",
    "please",
    "show",
    "tell",
    "that",
    "the",
    "this",
    "want",
    "would",
  )

private fun String.promptTerms(): Set<String> {
  val result = mutableSetOf<String>()
  val current = StringBuilder()
  fun flush() {
    if (current.length >= 2) result += current.toString().lowercase()
    current.clear()
  }
  forEach { char ->
    if (char.isLetterOrDigit()) {
      if (current.isNotEmpty() && char.isUpperCase() && current.last().isLowerCase()) flush()
      current.append(char)
    } else {
      flush()
    }
  }
  flush()
  return result
}

private fun fencedJsonBody(text: String): String? {
  val start = text.indexOf("```")
  if (start < 0) return null
  val bodyStart = start + 3
  val end = text.indexOf("```", startIndex = bodyStart)
  if (end < 0) return null
  var body = text.substring(bodyStart, end).trim()
  if (body.lowercase().startsWith("json")) {
    body = body.drop(4).trim()
  }
  return body
}

private fun firstJsonObjectSubstring(text: String): String? {
  val start = text.indexOf('{')
  if (start < 0) return null
  var depth = 0
  var inString = false
  var escaped = false
  for (index in start until text.length) {
    val char = text[index]
    if (inString) {
      when {
        escaped -> escaped = false
        char == '\\' -> escaped = true
        char == '"' -> inString = false
      }
    } else {
      when (char) {
        '"' -> inString = true
        '{' -> depth += 1
        '}' -> {
          depth -= 1
          if (depth == 0) return text.substring(start, index + 1)
        }
      }
    }
  }
  return null
}

private fun String.trimForPrompt(limit: Int): String {
  val normalized = trim()
  if (normalized.length <= limit) return normalized
  return normalized.take(limit.coerceAtLeast(1)) + "…"
}

private fun String.oneLineForPrompt(limit: Int): String =
  replace(Regex("\\s+"), " ").trimForPrompt(limit)
