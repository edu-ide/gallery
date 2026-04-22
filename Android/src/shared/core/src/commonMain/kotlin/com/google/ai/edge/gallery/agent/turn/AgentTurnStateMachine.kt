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

/**
 * Platform-neutral agent turn state machine.
 *
 * Mobile hosts own platform side effects (LLM runtime, MCP transport, approval UI, speech, files).
 * Shared core owns the canonical turn projection:
 *
 * plan -> search tools -> request approval -> run tool -> observe -> final answer.
 *
 * The model intentionally uses enum + nullable field payloads instead of sealed classes so it is
 * easy to consume from Swift through the KMP Objective-C/Swift bridge.
 */
data class AgentTurnState(
  val id: String,
  val userPrompt: String,
  val createdAtEpochMs: Long,
  val attachmentCount: Int,
  val activeSkillIds: List<String>,
  val activeConnectorIds: List<String>,
  val phase: AgentTurnPhase,
  val steps: List<AgentTurnStep>,
) {
  val isTerminal: Boolean
    get() =
      when (phase.kind) {
        AgentTurnPhaseKind.COMPLETED,
        AgentTurnPhaseKind.FAILED,
        AgentTurnPhaseKind.CANCELLED -> true
        else -> false
      }

  val activity: AgentTurnActivity?
    get() = phase.activity

  fun apply(event: AgentTurnEvent, nowEpochMs: Long): AgentTurnState {
    if (isTerminal) {
      return this
    }

    val nextPhase = event.nextPhase()
    return copy(
      phase = nextPhase,
      steps =
        steps +
          AgentTurnStep(
            kind = event.stepKind,
            title = nextPhase.title,
            detail = nextPhase.detail,
            timestampEpochMs = nowEpochMs,
          ),
    )
  }
}

enum class AgentTurnPhaseKind {
  PLANNING,
  INGESTING_ATTACHMENTS,
  ROUTE_PLANNED,
  READING_VISIBLE_CONTEXT,
  SEARCHING_TOOLS,
  AWAITING_APPROVAL,
  RUNNING_TOOL,
  OBSERVING_TOOL,
  COMPACTING_CONTEXT,
  GENERATING_FINAL_ANSWER,
  COMPLETED,
  FAILED,
  CANCELLED,
}

data class AgentTurnPhase(
  val kind: AgentTurnPhaseKind,
  val route: AgentTurnRoute? = null,
  val connectorTitle: String? = null,
  val toolTitle: String? = null,
  val count: Int = 0,
  val status: String? = null,
  val finalAnswerSource: AgentTurnFinalAnswerSource? = null,
  val outcome: AgentTurnOutcome? = null,
  val reason: String? = null,
) {
  val title: String
    get() =
      when (kind) {
        AgentTurnPhaseKind.PLANNING -> "턴 준비 중"
        AgentTurnPhaseKind.INGESTING_ATTACHMENTS -> "파일 읽는 중"
        AgentTurnPhaseKind.ROUTE_PLANNED -> "실행 경로 결정"
        AgentTurnPhaseKind.READING_VISIBLE_CONTEXT -> "화면 내용 참고"
        AgentTurnPhaseKind.SEARCHING_TOOLS -> "도구 검색 중"
        AgentTurnPhaseKind.AWAITING_APPROVAL -> "승인 대기 중"
        AgentTurnPhaseKind.RUNNING_TOOL -> "도구 실행 중"
        AgentTurnPhaseKind.OBSERVING_TOOL -> "도구 결과 확인"
        AgentTurnPhaseKind.COMPACTING_CONTEXT -> "컨텍스트 압축 중"
        AgentTurnPhaseKind.GENERATING_FINAL_ANSWER -> "답변 생성 중"
        AgentTurnPhaseKind.COMPLETED -> "턴 완료"
        AgentTurnPhaseKind.FAILED -> "턴 실패"
        AgentTurnPhaseKind.CANCELLED -> "턴 취소"
      }

  val detail: String
    get() =
      when (kind) {
        AgentTurnPhaseKind.PLANNING -> "요청, 첨부, 활성 기능을 기준으로 다음 실행 단계를 고르고 있어요."
        AgentTurnPhaseKind.INGESTING_ATTACHMENTS ->
          if (count == 0) {
            "첨부 파일 없이 진행해요."
          } else {
            "첨부 파일 ${count}개를 agent workspace에 저장하고 있어요."
          }
        AgentTurnPhaseKind.ROUTE_PLANNED -> route?.detail ?: "이번 턴 실행 경로를 결정했어요."
        AgentTurnPhaseKind.READING_VISIBLE_CONTEXT -> "열려 있는 위젯/카드 context를 우선 읽고 이어서 답할게요."
        AgentTurnPhaseKind.SEARCHING_TOOLS -> "${connectorTitle ?: "Connector"}에서 실행 가능한 도구를 찾고 있어요."
        AgentTurnPhaseKind.AWAITING_APPROVAL ->
          "${connectorTitle ?: "Connector"}의 ${toolTitle ?: "도구"} 실행은 사용자 승인이 필요해요."
        AgentTurnPhaseKind.RUNNING_TOOL -> "${connectorTitle ?: "Connector"}의 ${toolTitle ?: "도구"}을 실행하고 있어요."
        AgentTurnPhaseKind.OBSERVING_TOOL -> "${toolTitle ?: "도구"} 실행 결과를 확인했어요. 상태: ${status ?: "unknown"}."
        AgentTurnPhaseKind.COMPACTING_CONTEXT -> "긴 이전 대화를 요약 메모리로 바꿔 다음 답변 성능을 유지하고 있어요."
        AgentTurnPhaseKind.GENERATING_FINAL_ANSWER ->
          finalAnswerSource?.detail ?: "최종 답변을 생성하고 있어요."
        AgentTurnPhaseKind.COMPLETED -> outcome?.detail ?: "턴을 완료했어요."
        AgentTurnPhaseKind.FAILED -> reason ?: "턴 실행에 실패했어요."
        AgentTurnPhaseKind.CANCELLED -> reason ?: "턴 실행을 취소했어요."
      }

  val activity: AgentTurnActivity?
    get() =
      when (kind) {
        AgentTurnPhaseKind.COMPLETED,
        AgentTurnPhaseKind.CANCELLED -> null
        AgentTurnPhaseKind.FAILED ->
          AgentTurnActivity(
            symbol = "exclamationmark.triangle",
            title = title,
            detail = detail,
            showsProgress = false,
          )
        AgentTurnPhaseKind.PLANNING ->
          AgentTurnActivity(symbol = "sparkles", title = title, detail = detail, showsProgress = true)
        AgentTurnPhaseKind.INGESTING_ATTACHMENTS ->
          AgentTurnActivity(symbol = "folder.badge.plus", title = title, detail = detail, showsProgress = true)
        AgentTurnPhaseKind.ROUTE_PLANNED ->
          AgentTurnActivity(
            symbol = "point.topleft.down.curvedto.point.bottomright.up",
            title = title,
            detail = detail,
            showsProgress = true,
          )
        AgentTurnPhaseKind.READING_VISIBLE_CONTEXT ->
          AgentTurnActivity(symbol = "rectangle.on.rectangle", title = title, detail = detail, showsProgress = true)
        AgentTurnPhaseKind.SEARCHING_TOOLS ->
          AgentTurnActivity(symbol = "sparkle.magnifyingglass", title = title, detail = detail, showsProgress = true)
        AgentTurnPhaseKind.AWAITING_APPROVAL ->
          AgentTurnActivity(symbol = "hand.raised.fill", title = title, detail = detail, showsProgress = false)
        AgentTurnPhaseKind.RUNNING_TOOL ->
          AgentTurnActivity(symbol = "checkmark.shield", title = title, detail = detail, showsProgress = true)
        AgentTurnPhaseKind.OBSERVING_TOOL ->
          AgentTurnActivity(symbol = "wrench.and.screwdriver", title = title, detail = detail, showsProgress = true)
        AgentTurnPhaseKind.COMPACTING_CONTEXT ->
          AgentTurnActivity(symbol = "arrow.triangle.2.circlepath", title = title, detail = detail, showsProgress = true)
        AgentTurnPhaseKind.GENERATING_FINAL_ANSWER ->
          AgentTurnActivity(symbol = "sparkles.rectangle.stack", title = title, detail = detail, showsProgress = true)
      }
}

enum class AgentTurnRouteKind {
  MODEL,
  NATIVE_SKILL,
  MCP_CONNECTOR,
  MCP_CONNECTORS,
  VISIBLE_CONTEXT,
}

data class AgentTurnRoute(
  val kind: AgentTurnRouteKind,
  val id: String? = null,
  val title: String? = null,
  val count: Int = 0,
) {
  val detail: String
    get() =
      when (kind) {
        AgentTurnRouteKind.MODEL -> "이번 턴은 모델 답변으로 처리해요."
        AgentTurnRouteKind.NATIVE_SKILL -> "${title ?: "Native skill"} 경로로 처리해요."
        AgentTurnRouteKind.MCP_CONNECTOR -> "${title ?: "MCP connector"} 도구 경로로 처리해요."
        AgentTurnRouteKind.MCP_CONNECTORS -> "활성 MCP connector ${count}개에서 도구를 검색해요."
        AgentTurnRouteKind.VISIBLE_CONTEXT -> "현재 화면의 위젯 context를 읽고 답해요."
      }
}

enum class AgentTurnFinalAnswerSourceKind {
  MODEL,
  TOOL_OBSERVATION,
  WIDGET,
  GUARDRAIL,
}

data class AgentTurnFinalAnswerSource(
  val kind: AgentTurnFinalAnswerSourceKind,
  val toolTitle: String? = null,
) {
  val detail: String
    get() =
      when (kind) {
        AgentTurnFinalAnswerSourceKind.MODEL -> "모델이 대화 context를 바탕으로 최종 답변을 생성하고 있어요."
        AgentTurnFinalAnswerSourceKind.TOOL_OBSERVATION ->
          "${toolTitle ?: "도구"} 실행 결과를 바탕으로 최종 답변을 생성하고 있어요."
        AgentTurnFinalAnswerSourceKind.WIDGET -> "${toolTitle ?: "도구"} 결과 위젯을 표시하고 있어요."
        AgentTurnFinalAnswerSourceKind.GUARDRAIL -> "도구 실행 없이 완료했다고 말하지 않도록 안전 답변을 만들고 있어요."
      }
}

enum class AgentTurnOutcomeKind {
  ANSWERED,
  SHOWED_WIDGET,
  REQUESTED_APPROVAL,
  SKIPPED_TOOL_SEARCH,
  GUARDRAIL_STOPPED,
}

data class AgentTurnOutcome(
  val kind: AgentTurnOutcomeKind,
  val toolTitle: String? = null,
) {
  val detail: String
    get() =
      when (kind) {
        AgentTurnOutcomeKind.ANSWERED -> "최종 답변을 대화에 추가했어요."
        AgentTurnOutcomeKind.SHOWED_WIDGET -> "${toolTitle ?: "도구"} 결과 위젯을 대화에 추가했어요."
        AgentTurnOutcomeKind.REQUESTED_APPROVAL -> "${toolTitle ?: "도구"} 실행 승인을 요청했어요."
        AgentTurnOutcomeKind.SKIPPED_TOOL_SEARCH -> "이번 요청에 맞는 실행 도구가 없어 모델 답변으로 이어갔어요."
        AgentTurnOutcomeKind.GUARDRAIL_STOPPED -> "실제 도구 실행 없이 변경 완료라고 말하지 않도록 중단했어요."
      }
}

enum class AgentTurnEventKind {
  INGEST_ATTACHMENTS,
  ROUTE_PLANNED,
  READ_VISIBLE_CONTEXT,
  SEARCH_TOOLS,
  SKIP_TOOL_SEARCH,
  REQUEST_APPROVAL,
  APPROVE_TOOL,
  RUN_TOOL,
  OBSERVE_TOOL,
  COMPACT_CONTEXT,
  FINISH_COMPACTION,
  GENERATE_FINAL_ANSWER,
  COMPLETE,
  FAIL,
  CANCEL,
}

data class AgentTurnEvent(
  val kind: AgentTurnEventKind,
  val count: Int = 0,
  val route: AgentTurnRoute? = null,
  val connectorTitle: String? = null,
  val toolTitle: String? = null,
  val status: String? = null,
  val finalAnswerSource: AgentTurnFinalAnswerSource? = null,
  val outcome: AgentTurnOutcome? = null,
  val reason: String? = null,
) {
  val stepKind: AgentTurnStepKind
    get() =
      when (kind) {
        AgentTurnEventKind.INGEST_ATTACHMENTS,
        AgentTurnEventKind.ROUTE_PLANNED,
        AgentTurnEventKind.READ_VISIBLE_CONTEXT,
        AgentTurnEventKind.COMPACT_CONTEXT,
        AgentTurnEventKind.FINISH_COMPACTION -> AgentTurnStepKind.PLAN
        AgentTurnEventKind.SEARCH_TOOLS,
        AgentTurnEventKind.SKIP_TOOL_SEARCH -> AgentTurnStepKind.SEARCH_TOOLS
        AgentTurnEventKind.REQUEST_APPROVAL,
        AgentTurnEventKind.APPROVE_TOOL -> AgentTurnStepKind.REQUEST_APPROVAL
        AgentTurnEventKind.RUN_TOOL -> AgentTurnStepKind.RUN_TOOL
        AgentTurnEventKind.OBSERVE_TOOL -> AgentTurnStepKind.OBSERVE
        AgentTurnEventKind.GENERATE_FINAL_ANSWER -> AgentTurnStepKind.FINAL_ANSWER
        AgentTurnEventKind.COMPLETE -> AgentTurnStepKind.COMPLETE
        AgentTurnEventKind.FAIL -> AgentTurnStepKind.FAILED
        AgentTurnEventKind.CANCEL -> AgentTurnStepKind.CANCELLED
      }

  fun nextPhase(): AgentTurnPhase =
    when (kind) {
      AgentTurnEventKind.INGEST_ATTACHMENTS ->
        AgentTurnPhase(kind = AgentTurnPhaseKind.INGESTING_ATTACHMENTS, count = count)
      AgentTurnEventKind.ROUTE_PLANNED ->
        AgentTurnPhase(kind = AgentTurnPhaseKind.ROUTE_PLANNED, route = route)
      AgentTurnEventKind.READ_VISIBLE_CONTEXT ->
        AgentTurnPhase(kind = AgentTurnPhaseKind.READING_VISIBLE_CONTEXT)
      AgentTurnEventKind.SEARCH_TOOLS ->
        AgentTurnPhase(kind = AgentTurnPhaseKind.SEARCHING_TOOLS, connectorTitle = connectorTitle)
      AgentTurnEventKind.SKIP_TOOL_SEARCH ->
        AgentTurnPhase(kind = AgentTurnPhaseKind.ROUTE_PLANNED, route = agentTurnRouteModel())
      AgentTurnEventKind.REQUEST_APPROVAL ->
        AgentTurnPhase(
          kind = AgentTurnPhaseKind.AWAITING_APPROVAL,
          connectorTitle = connectorTitle,
          toolTitle = toolTitle,
        )
      AgentTurnEventKind.APPROVE_TOOL,
      AgentTurnEventKind.RUN_TOOL ->
        AgentTurnPhase(
          kind = AgentTurnPhaseKind.RUNNING_TOOL,
          connectorTitle = connectorTitle,
          toolTitle = toolTitle,
        )
      AgentTurnEventKind.OBSERVE_TOOL ->
        AgentTurnPhase(
          kind = AgentTurnPhaseKind.OBSERVING_TOOL,
          connectorTitle = connectorTitle,
          toolTitle = toolTitle,
          status = status,
        )
      AgentTurnEventKind.COMPACT_CONTEXT -> AgentTurnPhase(kind = AgentTurnPhaseKind.COMPACTING_CONTEXT)
      AgentTurnEventKind.FINISH_COMPACTION -> AgentTurnPhase(kind = AgentTurnPhaseKind.PLANNING)
      AgentTurnEventKind.GENERATE_FINAL_ANSWER ->
        AgentTurnPhase(
          kind = AgentTurnPhaseKind.GENERATING_FINAL_ANSWER,
          finalAnswerSource = finalAnswerSource,
        )
      AgentTurnEventKind.COMPLETE -> AgentTurnPhase(kind = AgentTurnPhaseKind.COMPLETED, outcome = outcome)
      AgentTurnEventKind.FAIL -> AgentTurnPhase(kind = AgentTurnPhaseKind.FAILED, reason = reason)
      AgentTurnEventKind.CANCEL -> AgentTurnPhase(kind = AgentTurnPhaseKind.CANCELLED, reason = reason)
    }
}

data class AgentTurnStep(
  val kind: AgentTurnStepKind,
  val title: String,
  val detail: String,
  val timestampEpochMs: Long,
)

enum class AgentTurnStepKind {
  PLAN,
  SEARCH_TOOLS,
  REQUEST_APPROVAL,
  RUN_TOOL,
  OBSERVE,
  FINAL_ANSWER,
  COMPLETE,
  FAILED,
  CANCELLED,
}

data class AgentTurnActivity(
  val symbol: String,
  val title: String,
  val detail: String,
  val showsProgress: Boolean,
)

fun createAgentTurnState(
  userPrompt: String,
  attachmentCount: Int,
  activeSkillIds: List<String>,
  activeConnectorIds: List<String>,
  id: String,
  nowEpochMs: Long,
): AgentTurnState {
  val initialPhase = AgentTurnPhase(kind = AgentTurnPhaseKind.PLANNING)
  val initialDetail =
    if (attachmentCount == 0) {
      "사용자 요청을 agent turn으로 등록했어요."
    } else {
      "사용자 요청과 첨부 파일 ${attachmentCount}개를 agent turn으로 등록했어요."
    }
  return AgentTurnState(
    id = id,
    userPrompt = userPrompt,
    createdAtEpochMs = nowEpochMs,
    attachmentCount = attachmentCount,
    activeSkillIds = activeSkillIds,
    activeConnectorIds = activeConnectorIds,
    phase = initialPhase,
    steps =
      listOf(
        AgentTurnStep(
          kind = AgentTurnStepKind.PLAN,
          title = "턴 준비",
          detail = initialDetail,
          timestampEpochMs = nowEpochMs,
        )
      ),
  )
}

fun agentTurnRouteModel(): AgentTurnRoute = AgentTurnRoute(kind = AgentTurnRouteKind.MODEL)

fun agentTurnRouteNativeSkill(id: String, title: String?): AgentTurnRoute =
  AgentTurnRoute(kind = AgentTurnRouteKind.NATIVE_SKILL, id = id, title = title)

fun agentTurnRouteMcpConnector(id: String, title: String?): AgentTurnRoute =
  AgentTurnRoute(kind = AgentTurnRouteKind.MCP_CONNECTOR, id = id, title = title)

fun agentTurnRouteMcpConnectors(count: Int): AgentTurnRoute =
  AgentTurnRoute(kind = AgentTurnRouteKind.MCP_CONNECTORS, count = count)

fun agentTurnRouteVisibleContext(): AgentTurnRoute = AgentTurnRoute(kind = AgentTurnRouteKind.VISIBLE_CONTEXT)

fun agentTurnFinalAnswerSourceModel(): AgentTurnFinalAnswerSource =
  AgentTurnFinalAnswerSource(kind = AgentTurnFinalAnswerSourceKind.MODEL)

fun agentTurnFinalAnswerSourceToolObservation(toolTitle: String): AgentTurnFinalAnswerSource =
  AgentTurnFinalAnswerSource(kind = AgentTurnFinalAnswerSourceKind.TOOL_OBSERVATION, toolTitle = toolTitle)

fun agentTurnFinalAnswerSourceWidget(toolTitle: String): AgentTurnFinalAnswerSource =
  AgentTurnFinalAnswerSource(kind = AgentTurnFinalAnswerSourceKind.WIDGET, toolTitle = toolTitle)

fun agentTurnFinalAnswerSourceGuardrail(): AgentTurnFinalAnswerSource =
  AgentTurnFinalAnswerSource(kind = AgentTurnFinalAnswerSourceKind.GUARDRAIL)

fun agentTurnOutcomeAnswered(): AgentTurnOutcome = AgentTurnOutcome(kind = AgentTurnOutcomeKind.ANSWERED)

fun agentTurnOutcomeShowedWidget(toolTitle: String): AgentTurnOutcome =
  AgentTurnOutcome(kind = AgentTurnOutcomeKind.SHOWED_WIDGET, toolTitle = toolTitle)

fun agentTurnOutcomeRequestedApproval(toolTitle: String): AgentTurnOutcome =
  AgentTurnOutcome(kind = AgentTurnOutcomeKind.REQUESTED_APPROVAL, toolTitle = toolTitle)

fun agentTurnOutcomeSkippedToolSearch(): AgentTurnOutcome =
  AgentTurnOutcome(kind = AgentTurnOutcomeKind.SKIPPED_TOOL_SEARCH)

fun agentTurnOutcomeGuardrailStopped(): AgentTurnOutcome =
  AgentTurnOutcome(kind = AgentTurnOutcomeKind.GUARDRAIL_STOPPED)

fun agentTurnEventIngestAttachments(count: Int): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.INGEST_ATTACHMENTS, count = count)

fun agentTurnEventRoutePlanned(route: AgentTurnRoute): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.ROUTE_PLANNED, route = route)

fun agentTurnEventReadVisibleContext(): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.READ_VISIBLE_CONTEXT)

fun agentTurnEventSearchTools(connectorTitle: String): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.SEARCH_TOOLS, connectorTitle = connectorTitle)

fun agentTurnEventSkipToolSearch(connectorTitle: String): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.SKIP_TOOL_SEARCH, connectorTitle = connectorTitle)

fun agentTurnEventRequestApproval(connectorTitle: String, toolTitle: String): AgentTurnEvent =
  AgentTurnEvent(
    kind = AgentTurnEventKind.REQUEST_APPROVAL,
    connectorTitle = connectorTitle,
    toolTitle = toolTitle,
  )

fun agentTurnEventApproveTool(connectorTitle: String, toolTitle: String): AgentTurnEvent =
  AgentTurnEvent(
    kind = AgentTurnEventKind.APPROVE_TOOL,
    connectorTitle = connectorTitle,
    toolTitle = toolTitle,
  )

fun agentTurnEventRunTool(connectorTitle: String, toolTitle: String): AgentTurnEvent =
  AgentTurnEvent(
    kind = AgentTurnEventKind.RUN_TOOL,
    connectorTitle = connectorTitle,
    toolTitle = toolTitle,
  )

fun agentTurnEventObserveTool(
  connectorTitle: String,
  toolTitle: String,
  status: String,
): AgentTurnEvent =
  AgentTurnEvent(
    kind = AgentTurnEventKind.OBSERVE_TOOL,
    connectorTitle = connectorTitle,
    toolTitle = toolTitle,
    status = status,
  )

fun agentTurnEventCompactContext(): AgentTurnEvent = AgentTurnEvent(kind = AgentTurnEventKind.COMPACT_CONTEXT)

fun agentTurnEventFinishCompaction(): AgentTurnEvent = AgentTurnEvent(kind = AgentTurnEventKind.FINISH_COMPACTION)

fun agentTurnEventGenerateFinalAnswer(source: AgentTurnFinalAnswerSource): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.GENERATE_FINAL_ANSWER, finalAnswerSource = source)

fun agentTurnEventComplete(outcome: AgentTurnOutcome): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.COMPLETE, outcome = outcome)

fun agentTurnEventFail(reason: String): AgentTurnEvent = AgentTurnEvent(kind = AgentTurnEventKind.FAIL, reason = reason)

fun agentTurnEventCancel(reason: String): AgentTurnEvent =
  AgentTurnEvent(kind = AgentTurnEventKind.CANCEL, reason = reason)
