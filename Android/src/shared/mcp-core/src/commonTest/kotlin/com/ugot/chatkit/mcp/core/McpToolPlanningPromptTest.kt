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

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AgentToolPlanningPromptTest {
  @Test
  fun promptContainsCanonicalContractToolsAndObservations() {
    val prompt =
      buildAgentToolPlanningPrompt(
        AgentToolPlanningRequest(
          userPrompt = "기본 사용자를 Yw로 바꿔봐",
          connectorId = "fortune.ugot.uk/mcp",
          connectorTitle = "UGOT Fortune",
          tools =
            listOf(
              AgentToolPlanningDescriptor(
                name = "_set_default_user",
                title = "Set default user",
                description = "Set the default saved user.",
                isReadOnly = false,
                isDestructive = false,
                requiredParameters = listOf("saved_user_id"),
                parametersSummary = "saved_user_id:string - stable saved-user id",
              ),
            ),
          previousObservations =
            listOf(
              AgentToolLoopObservation(
                connectorId = "fortune.ugot.uk/mcp",
                connectorTitle = "UGOT Fortune",
                toolName = "_find_saved_user",
                toolTitle = "Find saved user",
                argumentsPreview = "{search=Yw}",
                outputText = "found profile Yw with id user-1",
                hasWidget = false,
                didMutate = false,
                status = "success",
              ),
            ),
          stepIndex = 2,
          maxSteps = 4,
        )
      )

    assertTrue(prompt.contains("Current step: 2 of 4"))
    assertTrue(prompt.contains("_set_default_user"))
    assertTrue(prompt.contains("Do not invent opaque IDs"))
    assertTrue(prompt.contains("_find_saved_user"))
    assertTrue(prompt.contains("found profile Yw"))
  }

  @Test
  fun promptExplainsDefaultTargetAndMissingArgumentsRecovery() {
    val prompt =
      buildAgentToolPlanningPrompt(
        AgentToolPlanningRequest(
          userPrompt = "오늘의 운세 알려줘",
          connectorId = "fortune.ugot.uk/mcp",
          connectorTitle = "UGOT Fortune",
          tools =
            listOf(
              AgentToolPlanningDescriptor(
                name = "show_today_fortune",
                title = "Today's Fortune",
                description = "Use this for generic requests like today's fortune. It resolves the user's default saved profile first.",
                isReadOnly = true,
                requiredParameters = emptyList(),
              ),
              AgentToolPlanningDescriptor(
                name = "show_saju_daily",
                title = "Daily Fortune",
                description = "Use this when birth data or a concrete saved person target is already known.",
                isReadOnly = true,
                requiredParameters = listOf("birth_date", "birth_time", "gender"),
              ),
            ),
          previousObservations =
            listOf(
              AgentToolLoopObservation(
                connectorId = "fortune.ugot.uk/mcp",
                connectorTitle = "UGOT Fortune",
                toolName = "show_saju_daily",
                toolTitle = "Daily Fortune",
                argumentsPreview = "{}",
                outputText = "birth_date, birth_time, gender values are required",
                hasWidget = false,
                didMutate = false,
                status = "missing_arguments",
              ),
            ),
          stepIndex = 2,
          maxSteps = 4,
        )
      )

    assertTrue(prompt.contains("missing arguments"))
    assertTrue(prompt.contains("saved/default target"))
    assertTrue(prompt.contains("birth_date, birth_time, gender"))
  }

  @Test
  fun promptRanksRelevantToolAndStaysInsideLocalModelBudget() {
    val tools =
      (1..24).map { index ->
        AgentToolPlanningDescriptor(
          name = "unrelated_tool_$index",
          title = "Unrelated tool $index",
          description = "A long unrelated connector operation with schema details ".repeat(20),
          isReadOnly = true,
          requiredParameters = listOf("opaque_id_$index"),
          parametersSummary = "{\"properties\":{\"opaque_id_$index\":{\"type\":\"string\"}}}",
        )
      } +
        AgentToolPlanningDescriptor(
          name = "show_today_fortune",
          title = "Today's Fortune",
          description = "Show today's fortune using the saved default profile.",
          isReadOnly = true,
          hasWidget = true,
        )

    val prompt =
      buildAgentToolPlanningPrompt(
        AgentToolPlanningRequest(
          userPrompt = "Show me today's fortune",
          connectorId = "fortune.ugot.uk/mcp",
          connectorTitle = "UGOT Fortune",
          tools = tools,
          stepIndex = 1,
          maxSteps = 1,
        )
      )

    assertTrue(prompt.length <= 2_600)
    assertTrue(prompt.contains("show_today_fortune"))
    assertTrue(prompt.contains("saved default profile"))
  }

  @Test
  fun safeFallbackSelectsOnlyStrongNoArgumentReadMatch() {
    val tools =
      listOf(
        AgentToolPlanningDescriptor(
          name = "show_today_fortune",
          title = "Today's Fortune",
          description = "Show today's fortune using the saved default profile.",
          isReadOnly = true,
          hasWidget = true,
        ),
        AgentToolPlanningDescriptor(
          name = "show_saju_daily",
          title = "Daily Fortune",
          description = "Calculate a daily fortune from explicit birth data.",
          isReadOnly = true,
          requiredParameters = listOf("birth_date", "birth_time", "gender"),
        ),
        AgentToolPlanningDescriptor(
          name = "delete_saved_user",
          title = "Delete saved user",
          description = "Delete a saved profile.",
          isReadOnly = false,
          isDestructive = true,
        ),
      )

    val selected = selectSafeReadToolFallback("Show me the fortune for today", tools)

    assertEquals("show_today_fortune", selected?.name)
    assertNull(selectSafeReadToolFallback("Hello there", tools))
  }

  @Test
  fun safeFallbackAbstainsWhenReadCandidatesTie() {
    val tools =
      listOf("primary", "secondary").map { suffix ->
        AgentToolPlanningDescriptor(
          name = "show_fortune_$suffix",
          title = "Fortune $suffix",
          description = "Show a fortune.",
          isReadOnly = true,
        )
      }

    assertNull(selectSafeReadToolFallback("Show fortune", tools))
  }

  @Test
  fun approvalGatedFallbackCanSurfaceUnannotatedCandidateButNeverDestructiveTool() {
    val unannotated =
      AgentToolPlanningDescriptor(
        name = "show_today_fortune",
        title = "Today's Fortune",
        description = "Show today's fortune using the default profile.",
        isReadOnly = false,
      )
    val destructive =
      AgentToolPlanningDescriptor(
        name = "delete_today_fortune",
        title = "Delete today's fortune",
        description = "Delete today's fortune record.",
        isReadOnly = false,
        isDestructive = true,
      )

    val selected =
      listOf(unannotated, destructive)
        .selectApprovalGatedToolFallbackCandidate("Show today's fortune")

    assertEquals("show_today_fortune", selected?.name)
    assertNull(
      listOf(destructive)
        .selectApprovalGatedToolFallbackCandidate("Delete today's fortune")
    )
  }

  @Test
  fun parseFencedPlanningDecisionWithArgumentsAndEntityReference() {
    val decision =
      parseAgentToolPlanningDecision(
        """
        ```json
        {
          "tool_name": "_set_default_user",
          "arguments": {},
          "entity_reference": "Yw",
          "intent_effect": "write",
          "confidence": 0.91,
          "requires_tool": true
        }
        ```
        """.trimIndent()
      )

    assertNotNull(decision)
    assertEquals("_set_default_user", decision.toolName)
    assertEquals("{}", decision.argumentsJson)
    assertEquals("Yw", decision.entityReference)
    assertEquals("write", decision.intentEffect)
    assertTrue(decision.requiresTool)
    assertTrue(decision.shouldUseTool)
  }

  @Test
  fun parseNullToolDecisionAsNoTool() {
    val decision =
      parseAgentToolPlanningDecision(
        "router says {\"toolName\": \"none\", \"arguments\": {}, \"confidence\": 0, \"requiresTool\": false}"
      )

    assertNotNull(decision)
    assertNull(decision.toolName)
    assertFalse(decision.requiresTool)
    assertFalse(decision.shouldUseTool)
  }

  @Test
  fun parseObjectSubstringPreservesArgumentsJson() {
    val decision =
      parseAgentToolPlanningDecision(
        "Use this: {\"tool\":\"search_emails\",\"args\":{\"query\":\"recent\"},\"score\":\"0.8\"}."
      )

    assertNotNull(decision)
    assertEquals("search_emails", decision.toolName)
    assertEquals("{\"query\":\"recent\"}", decision.argumentsJson)
    assertEquals(0.8, decision.confidence)
  }
}
