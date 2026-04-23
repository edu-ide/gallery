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

package com.google.ai.edge.gallery.agent.toolloop

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

/**
 * Builds the single canonical MCP tool-planning prompt used by mobile hosts.
 *
 * Hosts still own model invocation and tool side effects. Shared core owns the protocol-neutral
 * contract: bounded steps, JSON-only response, no hidden tools, no destructive read handling, and
 * visible-name-to-entity-reference behavior.
 */
fun buildAgentToolPlanningPrompt(request: AgentToolPlanningRequest): String {
  val tools = request.tools
    .joinToString(separator = "\n") { it.toPromptBlock() }
    .trimForPrompt(limit = 10_000)
  val previousObservations = request.previousObservations.toPromptSummary()

  return """
    You are a model-agnostic MCP tool router for the mobile chat host.

    Decide the next step in a bounded agent tool loop for connector "${request.connectorTitle}".
    Use semantic intent, not keyword matching. The user may write in any language.
    Current step: ${request.stepIndex} of ${request.maxSteps.coerceAtLeast(1)}.

    Return ONLY one JSON object with this schema:
    {
      "tool_name": "exact listed tool name or null",
      "arguments": { "schema_parameter": "value" },
      "entity_reference": "visible user/profile/place/name to resolve later, or null",
      "intent_effect": "read | write | destructive | none",
      "confidence": 0.0,
      "requires_tool": false
    }

    Rules:
    - Use only tools listed below.
    - The listed tools are a retrieval result, not the full connector catalog. Do not switch to a neighboring tool just because it is available.
    - If none of the listed tools exactly matches the user's current intent, return tool_name null. Do not choose a generic/default/current tool as a substitute for a chart, prompt, attachment, account, profile, or follow-up intent.
    - App-only/internal widget tools are intentionally omitted. Never invent or request hidden app-only tools.
    - If no listed tool is clearly needed, or previous observations already answer/complete the user request, return {"tool_name": null, "arguments": {}, "entity_reference": null, "confidence": 0, "requires_tool": false}.
    - If the user requests an action that would require a tool but none of the listed tools can do it, return tool_name null and requires_tool true.
    - If the latest previous observation failed and a safe alternative read-only tool can recover, choose that alternative. Otherwise stop with tool_name null and requires_tool true.
    - If the latest previous observation failed because of missing arguments, do not repeat the same tool. Choose a listed alternative whose schema can satisfy the user's request without fabricating data, or stop with tool_name null and requires_tool true.
    - Do not repeat a previous tool call with the same semantic purpose and arguments.
    - Always set intent_effect from the user's request, not from the tool you wish existed.
    - Use intent_effect "read" for list/show/view/search/summarize/explain questions.
    - Use intent_effect "write" only for explicit set/change/save/create/register/send/update actions.
    - Use intent_effect "destructive" only for explicit delete/remove/clear/reset actions.
    - A read intent must never choose a write, destructive, clear, reset, delete, or remove tool.
    - For read-only display requests, prefer the most specific read-only display tool.
    - Prefer a tool whose required parameters are already present or whose description explicitly says it can use a saved/default target when the user omits a person.
    - If the user makes a generic "today/current daily" read request and a listed tool explicitly supports saved/default targets with no required birth fields, choose that tool over a birth-data-specific daily/detail tool.
    - For mutation/settings tools, choose them only when the user explicitly asks to set, change, save, delete, clear, or select something.
    - If the user asks to set/change the default user/profile/target and a listed non-read-only setter exists, choose that setter. If the user gives a visible name instead of an opaque ID, leave the ID argument out and put the visible name in entity_reference.
    - Never choose a destructive or clearing tool for an informational question.
    - Do not invent opaque IDs. If a required argument looks like an ID but the user gave a visible name, leave that ID out of arguments and put the visible name in entity_reference.
    - Fill arguments only from the user's message or safe schema defaults. Do not fabricate birth data, gender, date, or time.
    - Never choose a tool that requires birth_date, birth_time, gender, or another concrete target field unless the user supplied those values, a previous observation resolved them, or the tool itself says omitted target fields are resolved from a saved/default profile.

    Available MCP tools:
    $tools

    User message:
    ${request.userPrompt.trimForPrompt(limit = 2_000)}

    Previous tool observations:
    $previousObservations
  """.trimIndent()
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

private fun JsonObject.toPlanningDecision(): AgentToolPlanningDecision {
  val rawTool = firstString("tool_name", "toolName", "tool", "name")?.trim()
  val nullToolNames = setOf("", "none", "null", "no_tool", "no tool", "model")
  val toolName = rawTool?.takeIf { it.lowercase() !in nullToolNames }
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
  )?.trim()?.takeIf { it.isNotEmpty() }
  val intentEffect = firstString(
    "intent_effect",
    "intentEffect",
    "effect",
    "tool_effect",
    "toolEffect",
  )?.trim()?.takeIf { it.isNotEmpty() }

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

private fun AgentToolPlanningDescriptor.toPromptBlock(): String {
  val readOnly = isReadOnly?.toString() ?: "unknown"
  val destructive = isDestructive?.toString() ?: "unknown"
  val required = requiredParameters.joinToString(separator = ", ")
  val widget = if (hasWidget) "true" else "false"
  return """
    - name: $name
      title: $title
      readOnly: $readOnly
      destructive: $destructive
      widget: $widget
      required: [$required]
      parameters: ${parametersSummary.trimForPrompt(limit = 1_000)}
      description: ${description.oneLineForPrompt(limit = 520)}
  """.trimIndent()
}

private fun List<AgentToolLoopObservation>.toPromptSummary(): String {
  if (isEmpty()) return "none"
  return takeLast(6)
    .mapIndexed { index, observation ->
      """
        ${index + 1}. tool=${observation.toolName}, status=${observation.status}, mutated=${if (observation.didMutate) "yes" else "no"}, widget=${if (observation.hasWidget) "yes" else "no"}
           arguments=${observation.argumentsPreview.oneLineForPrompt(limit = 220)}
           observation=${observation.outputText.oneLineForPrompt(limit = 520)}
      """.trimIndent()
    }
    .joinToString(separator = "\n")
    .trimForPrompt(limit = 4_000)
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
