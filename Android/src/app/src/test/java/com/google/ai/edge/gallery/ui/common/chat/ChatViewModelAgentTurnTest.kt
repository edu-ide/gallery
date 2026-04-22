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

package com.google.ai.edge.gallery.ui.common.chat

import com.google.ai.edge.gallery.agent.turn.AgentTurnPhaseKind
import com.google.ai.edge.gallery.agent.turn.AgentTurnRouteKind
import com.google.ai.edge.gallery.agent.turn.agentTurnEventGenerateFinalAnswer
import com.google.ai.edge.gallery.agent.turn.agentTurnEventRoutePlanned
import com.google.ai.edge.gallery.agent.turn.agentTurnFinalAnswerSourceModel
import com.google.ai.edge.gallery.agent.turn.agentTurnOutcomeAnswered
import com.google.ai.edge.gallery.agent.turn.agentTurnRouteMcpConnector
import com.google.ai.edge.gallery.data.Model
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test

class ChatViewModelAgentTurnTest {
  private class TestChatViewModel : ChatViewModel()

  @Test
  fun beginApplyCompleteAgentTurn_projectsSharedKmpStateByModel() {
    val viewModel = TestChatViewModel()
    val model = Model(name = "Gemma 4")

    val turn =
      viewModel.beginAgentTurn(
        model = model,
        userPrompt = "오늘의 운세 알려줘",
        attachmentCount = 0,
        activeConnectorIds = listOf("fortune.ugot.uk/mcp"),
        id = "turn-test",
        nowEpochMs = 1,
      )

    assertEquals("turn-test", turn.id)
    assertEquals(
      AgentTurnPhaseKind.PLANNING,
      viewModel.uiState.value.agentTurnsByModel[model.name]?.phase?.kind,
    )

    val routed =
      viewModel.applyAgentTurnEvent(
        model = model,
        event =
          agentTurnEventRoutePlanned(
            agentTurnRouteMcpConnector(id = "fortune.ugot.uk/mcp", title = "UGOT Fortune")
          ),
        nowEpochMs = 2,
      )
    assertEquals(AgentTurnPhaseKind.ROUTE_PLANNED, routed?.phase?.kind)
    assertEquals(AgentTurnRouteKind.MCP_CONNECTOR, routed?.phase?.route?.kind)

    viewModel.applyAgentTurnEvent(
      model = model,
      event = agentTurnEventGenerateFinalAnswer(agentTurnFinalAnswerSourceModel()),
      nowEpochMs = 3,
    )

    val projected = viewModel.uiState.value.agentTurnsByModel[model.name]
    assertNotNull(projected)
    assertEquals(AgentTurnPhaseKind.GENERATING_FINAL_ANSWER, projected?.phase?.kind)

    viewModel.completeAgentTurn(
      model = model,
      outcome = agentTurnOutcomeAnswered(),
      nowEpochMs = 4,
    )

    assertFalse(viewModel.uiState.value.agentTurnsByModel.containsKey(model.name))
  }
}
