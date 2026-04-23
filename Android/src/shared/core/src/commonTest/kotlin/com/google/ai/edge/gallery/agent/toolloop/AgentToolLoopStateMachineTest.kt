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

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AgentToolLoopStateMachineTest {
  @Test
  fun readOnlyErrorCanSafelyReplanThenStopAfterSuccess() {
    var state = createAgentToolLoopState(maxSteps = 4)
    val readOnly = tool("summarize_recent_mail", isReadOnly = true)

    val policy = agentToolLoopCanRunCall(state, readOnly.name, "summarize_recent_mail::{}")
    assertTrue(policy.allowed)

    state = agentToolLoopRecordCall(state, readOnly.name, "summarize_recent_mail::{}")
    val failed = observation(readOnly.name, status = "error", didMutate = false)
    state = agentToolLoopRecordObservations(state, listOf(failed))

    val next =
      agentToolLoopNextActionAfterToolResponse(
        state = state,
        latestObservation = failed,
        plannedTool = readOnly,
        hasApprovalRequest = false,
        hasWidget = false,
        newObservationCount = 1,
      )

    assertEquals(AgentToolLoopNextActionKind.CONTINUE_PLANNING, next.kind)
    assertTrue(next.shouldContinuePlanning)

    val alternative = tool("search_emails", isReadOnly = true)
    state = agentToolLoopRecordCall(state, alternative.name, "search_emails::{query=recent}")
    val success = observation(alternative.name, status = "success", didMutate = false)
    state = agentToolLoopRecordObservations(state, listOf(success))

    val final =
      agentToolLoopNextActionAfterToolResponse(
        state = state,
        latestObservation = success,
        plannedTool = alternative,
        hasApprovalRequest = false,
        hasWidget = false,
        newObservationCount = 1,
      )

    assertEquals(AgentToolLoopNextActionKind.STOP_FOR_FINAL, final.kind)
    assertTrue(final.shouldStop)
    assertEquals(2, state.stepIndex)
    assertEquals(listOf("summarize_recent_mail", "search_emails"), state.attemptedToolNames)
  }

  @Test
  fun mutationErrorDoesNotAutoReplan() {
    val mutating = tool("set_default_user", isReadOnly = false)
    var state = createAgentToolLoopState(maxSteps = 4)
    state = agentToolLoopRecordCall(state, mutating.name, "set_default_user::{id=1}")
    val failed = observation(mutating.name, status = "error", didMutate = false)
    state = agentToolLoopRecordObservations(state, listOf(failed))

    val next =
      agentToolLoopNextActionAfterToolResponse(
        state = state,
        latestObservation = failed,
        plannedTool = mutating,
        hasApprovalRequest = false,
        hasWidget = false,
        newObservationCount = 1,
      )

    assertEquals(AgentToolLoopNextActionKind.STOP_FOR_FINAL, next.kind)
    assertFalse(next.shouldContinuePlanning)
  }

  @Test
  fun readOnlyMissingArgumentsCanReplanButMutationMissingArgumentsStops() {
    val readOnlyDaily = tool("show_saju_daily", isReadOnly = true)
    var readState = createAgentToolLoopState(maxSteps = 4)
    readState = agentToolLoopRecordCall(readState, readOnlyDaily.name, "show_saju_daily::{}")
    val missingTarget = observation(readOnlyDaily.name, status = "missing_arguments", didMutate = false)
    readState = agentToolLoopRecordObservations(readState, listOf(missingTarget))

    val readNext =
      agentToolLoopNextActionAfterToolResponse(
        state = readState,
        latestObservation = missingTarget,
        plannedTool = readOnlyDaily,
        hasApprovalRequest = false,
        hasWidget = false,
        newObservationCount = 1,
      )

    assertEquals(AgentToolLoopNextActionKind.CONTINUE_PLANNING, readNext.kind)
    assertTrue(agentToolLoopShouldAvoidPreviouslyAttemptedTool(missingTarget))

    val setter = tool("set_default_user", isReadOnly = false)
    var writeState = createAgentToolLoopState(maxSteps = 4)
    writeState = agentToolLoopRecordCall(writeState, setter.name, "set_default_user::{}")
    val missingId = observation(setter.name, status = "missing_arguments", didMutate = false)
    writeState = agentToolLoopRecordObservations(writeState, listOf(missingId))

    val writeNext =
      agentToolLoopNextActionAfterToolResponse(
        state = writeState,
        latestObservation = missingId,
        plannedTool = setter,
        hasApprovalRequest = false,
        hasWidget = false,
        newObservationCount = 1,
    )

    assertEquals(AgentToolLoopNextActionKind.STOP_FOR_FINAL, writeNext.kind)
    assertTrue(agentToolLoopShouldAvoidPreviouslyAttemptedTool(missingId))
  }

  @Test
  fun duplicateCallIsRejectedBeforeExecution() {
    var state = createAgentToolLoopState(maxSteps = 4)
    state = agentToolLoopRecordCall(state, "find_saved_user", "find_saved_user::{search=Yw}")

    val policy = agentToolLoopCanRunCall(state, "find_saved_user", "find_saved_user::{search=Yw}")

    assertFalse(policy.allowed)
    assertTrue(policy.reason.contains("duplicate"))
  }

  @Test
  fun approvalAndWidgetStopTheLoop() {
    val state = createAgentToolLoopState(maxSteps = 4)
    val readOnly = tool("show_today_fortune", isReadOnly = true)

    val approval =
      agentToolLoopNextActionAfterToolResponse(
        state = state,
        latestObservation = null,
        plannedTool = readOnly,
        hasApprovalRequest = true,
        hasWidget = false,
        newObservationCount = 0,
      )
    val widget =
      agentToolLoopNextActionAfterToolResponse(
        state = state,
        latestObservation = observation(readOnly.name, status = "success"),
        plannedTool = readOnly,
        hasApprovalRequest = false,
        hasWidget = true,
        newObservationCount = 1,
      )

    assertEquals(AgentToolLoopNextActionKind.STOP_FOR_APPROVAL, approval.kind)
    assertEquals(AgentToolLoopNextActionKind.STOP_FOR_WIDGET, widget.kind)
  }

  @Test
  fun maxStepLimitRejectsNewCalls() {
    var state = createAgentToolLoopState(maxSteps = 1)
    state = agentToolLoopRecordCall(state, "search_emails", "search_emails::{}")

    val policy = agentToolLoopCanRunCall(state, "list_emails", "list_emails::{}")

    assertFalse(policy.allowed)
    assertTrue(policy.reason.contains("max step"))
  }

  private fun tool(
    name: String,
    isReadOnly: Boolean,
    isDestructive: Boolean = false,
  ): AgentToolLoopToolDescriptor =
    AgentToolLoopToolDescriptor(
      name = name,
      title = name,
      isReadOnly = isReadOnly,
      isDestructive = isDestructive,
      hasWidget = false,
    )

  private fun observation(
    toolName: String,
    status: String,
    didMutate: Boolean = false,
  ): AgentToolLoopObservation =
    AgentToolLoopObservation(
      connectorId = "test",
      connectorTitle = "Test",
      toolName = toolName,
      toolTitle = toolName,
      argumentsPreview = "`{}`",
      outputText = "status=$status",
      hasWidget = false,
      didMutate = didMutate,
      status = status,
    )
}
