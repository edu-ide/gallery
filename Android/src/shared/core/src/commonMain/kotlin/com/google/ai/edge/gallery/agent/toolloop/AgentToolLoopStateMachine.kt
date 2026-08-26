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

/**
 * Platform-neutral policy for a Codex-style tool loop.
 *
 * Mobile hosts own side effects: model calls, MCP transport, permission UI, widgets, and files.
 * Shared core owns the safety invariants:
 *
 * plan -> run tool -> observe -> maybe safely replan -> final.
 *
 * This deliberately avoids provider-specific assumptions. A host can drive this policy from
 * OpenAI-style typed tool calls, a local JSON router, or another planner, as long as every side
 * effect returns an [AgentToolLoopObservation].
 */
data class AgentToolLoopState(
  val stepIndex: Int,
  val maxSteps: Int,
  val observations: List<AgentToolLoopObservation>,
  val attemptedCallSignatures: List<String>,
  val attemptedToolNames: List<String>,
  val terminalReason: String? = null,
) {
  val isTerminal: Boolean
    get() = terminalReason != null

  val canPlan: Boolean
    get() = !isTerminal && stepIndex < maxSteps

  val nextStepIndex: Int
    get() = stepIndex + 1
}

data class AgentToolLoopObservation(
  val connectorId: String? = null,
  val connectorTitle: String,
  val toolName: String,
  val toolTitle: String,
  val argumentsPreview: String,
  val outputText: String,
  val hasWidget: Boolean,
  val didMutate: Boolean,
  val status: String,
)

data class AgentToolLoopToolDescriptor(
  val name: String,
  val title: String,
  val isReadOnly: Boolean,
  val isDestructive: Boolean,
  val hasWidget: Boolean,
)

data class AgentToolLoopCallPolicy(
  val allowed: Boolean,
  val reason: String,
)

enum class AgentToolLoopNextActionKind {
  CONTINUE_PLANNING,
  STOP_FOR_FINAL,
  STOP_FOR_APPROVAL,
  STOP_FOR_WIDGET,
}

data class AgentToolLoopNextAction(
  val kind: AgentToolLoopNextActionKind,
  val reason: String,
) {
  val shouldContinuePlanning: Boolean
    get() = kind == AgentToolLoopNextActionKind.CONTINUE_PLANNING

  val shouldStop: Boolean
    get() = !shouldContinuePlanning
}

fun createAgentToolLoopState(maxSteps: Int): AgentToolLoopState =
  AgentToolLoopState(
    stepIndex = 0,
    maxSteps = maxSteps.coerceAtLeast(1),
    observations = emptyList(),
    attemptedCallSignatures = emptyList(),
    attemptedToolNames = emptyList(),
  )

fun agentToolLoopCanRunCall(
  state: AgentToolLoopState,
  toolName: String,
  callSignature: String,
): AgentToolLoopCallPolicy {
  if (state.isTerminal) {
    return AgentToolLoopCallPolicy(false, state.terminalReason ?: "tool loop is terminal")
  }
  if (state.stepIndex >= state.maxSteps) {
    return AgentToolLoopCallPolicy(false, "tool loop reached max step count: ${state.maxSteps}")
  }
  if (state.attemptedCallSignatures.contains(callSignature)) {
    return AgentToolLoopCallPolicy(false, "duplicate tool call plan: $toolName")
  }
  return AgentToolLoopCallPolicy(true, "allowed")
}

fun agentToolLoopRecordCall(
  state: AgentToolLoopState,
  toolName: String,
  callSignature: String,
): AgentToolLoopState =
  state.copy(
    stepIndex = state.stepIndex + 1,
    attemptedCallSignatures = state.attemptedCallSignatures + callSignature,
    attemptedToolNames = state.attemptedToolNames + toolName,
  )

fun agentToolLoopRecordObservations(
  state: AgentToolLoopState,
  observations: List<AgentToolLoopObservation>,
): AgentToolLoopState =
  state.copy(observations = state.observations + observations)

fun agentToolLoopNextActionAfterToolResponse(
  state: AgentToolLoopState,
  latestObservation: AgentToolLoopObservation?,
  plannedTool: AgentToolLoopToolDescriptor?,
  hasApprovalRequest: Boolean,
  hasWidget: Boolean,
  newObservationCount: Int,
): AgentToolLoopNextAction {
  if (hasApprovalRequest) {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_APPROVAL, "tool requires user approval")
  }
  if (hasWidget) {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_WIDGET, "tool produced an interactive widget")
  }
  if (latestObservation == null) {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_FINAL, "tool response had no observation")
  }
  if (latestObservation.didMutate) {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_FINAL, "mutation result must not be retried automatically")
  }

  val status = latestObservation.status.normalizedStatus()
  if (status == "success" || status == "ok") {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_FINAL, "tool succeeded")
  }
  if (state.stepIndex >= state.maxSteps) {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_FINAL, "tool loop reached max step count")
  }
  if (newObservationCount <= 0) {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_FINAL, "no new observation to recover from")
  }
  if (plannedTool == null || !plannedTool.isReadOnly || plannedTool.isDestructive) {
    return AgentToolLoopNextAction(
      AgentToolLoopNextActionKind.STOP_FOR_FINAL,
      "only read-only non-destructive failures can be automatically replanned",
    )
  }
  if (status in recoverableReadOnlyStatuses) {
    return AgentToolLoopNextAction(
      AgentToolLoopNextActionKind.CONTINUE_PLANNING,
      "read-only failure can be safely replanned",
    )
  }
  if (status in terminalStatuses) {
    return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_FINAL, "tool status is terminal: $status")
  }
  return AgentToolLoopNextAction(AgentToolLoopNextActionKind.STOP_FOR_FINAL, "tool status is not recoverable: $status")
}

fun agentToolLoopShouldAvoidPreviouslyAttemptedTool(
  latestObservation: AgentToolLoopObservation?,
): Boolean {
  if (latestObservation == null || latestObservation.didMutate) return false
  return latestObservation.status.normalizedStatus() in recoverableReadOnlyStatuses
}

fun agentToolLoopTerminalState(
  state: AgentToolLoopState,
  reason: String,
): AgentToolLoopState = state.copy(terminalReason = reason)

private val terminalStatuses =
  setOf(
    "auth_required",
    "blocked",
    "duplicate_tool_plan",
    "no_matching_tool",
    "step_limit",
  )

private val recoverableReadOnlyStatuses =
  setOf(
    "error",
    "timeout",
    "network_error",
    "transport_error",
    "missing_arguments",
    "no_resolved_value",
  )

private fun String.normalizedStatus(): String =
  trim()
    .lowercase()
    .replace('-', '_')
