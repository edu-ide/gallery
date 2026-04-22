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

package com.google.ai.edge.gallery.agent.turn

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class AgentTurnStateMachineTest {
  @Test
  fun agentTurnStateMachine_runsToolApprovalObserveFinalAnswerFlow() {
    val start =
      createAgentTurnState(
        userPrompt = "오늘의 운세 알려줘",
        attachmentCount = 0,
        activeSkillIds = listOf("mobile_actions"),
        activeConnectorIds = listOf("fortune.ugot.uk/mcp"),
        id = "turn-test",
        nowEpochMs = 1,
      )

    val routed =
      start
        .apply(agentTurnEventRoutePlanned(agentTurnRouteMcpConnector("fortune.ugot.uk/mcp", "UGOT Fortune")), 2)
        .apply(agentTurnEventSearchTools("UGOT Fortune"), 3)
        .apply(agentTurnEventRequestApproval("UGOT Fortune", "show_today_fortune"), 4)

    assertEquals(AgentTurnPhaseKind.AWAITING_APPROVAL, routed.phase.kind)
    assertEquals("승인 대기 중", routed.activity?.title)
    assertFalse(routed.isTerminal)

    val completed =
      routed
        .apply(agentTurnEventRunTool("UGOT Fortune", "show_today_fortune"), 5)
        .apply(agentTurnEventObserveTool("UGOT Fortune", "show_today_fortune", "ok"), 6)
        .apply(agentTurnEventGenerateFinalAnswer(agentTurnFinalAnswerSourceToolObservation("show_today_fortune")), 7)
        .apply(agentTurnEventComplete(agentTurnOutcomeAnswered()), 8)

    assertEquals(AgentTurnPhaseKind.COMPLETED, completed.phase.kind)
    assertEquals(AgentTurnOutcomeKind.ANSWERED, completed.phase.outcome?.kind)
    assertEquals(null, completed.activity)
    assertTrue(completed.isTerminal)
    assertEquals(8, completed.steps.last().timestampEpochMs)
  }

  @Test
  fun agentTurnStateMachine_skippedToolSearchFallsBackToModelRoute() {
    val state =
      createAgentTurnState(
        userPrompt = "그냥 설명해줘",
        attachmentCount = 1,
        activeSkillIds = emptyList(),
        activeConnectorIds = listOf("gmail"),
        id = "turn-skip",
        nowEpochMs = 10,
      )
        .apply(agentTurnEventSearchTools("Gmail"), 11)
        .apply(agentTurnEventSkipToolSearch("Gmail"), 12)

    assertEquals(AgentTurnPhaseKind.ROUTE_PLANNED, state.phase.kind)
    assertEquals(AgentTurnRouteKind.MODEL, state.phase.route?.kind)
    assertNotNull(state.activity)
    assertFalse(state.isTerminal)
  }
}
