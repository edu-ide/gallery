import Foundation

/// Pure, UI-free agent turn state model.
///
/// This is intentionally small and Codable/Sendable so the same contract can be
/// moved into the KMP shared core later. The SwiftUI screen should only project
/// this state into notices, modals, and transcript rows.
struct UgotAgentTurnState: Equatable, Sendable {
  let id: String
  let userPrompt: String
  let createdAt: String
  let attachmentCount: Int
  let activeSkillIds: [String]
  let activeConnectorIds: [String]
  private(set) var phase: UgotAgentTurnPhase
  private(set) var steps: [UgotAgentTurnStep]

  static func start(
    userPrompt: String,
    attachmentCount: Int,
    activeSkillIds: [String],
    activeConnectorIds: [String]
  ) -> UgotAgentTurnState {
    let now = ISO8601DateFormatter().string(from: Date())
    let initial = UgotAgentTurnStep(
      kind: .plan,
      title: "턴 준비",
      detail: attachmentCount == 0 ? "사용자 요청을 agent turn으로 등록했어요." : "사용자 요청과 첨부 파일 \(attachmentCount)개를 agent turn으로 등록했어요.",
      timestamp: now
    )
    return UgotAgentTurnState(
      id: "turn_\(UUID().uuidString)",
      userPrompt: userPrompt,
      createdAt: now,
      attachmentCount: attachmentCount,
      activeSkillIds: activeSkillIds,
      activeConnectorIds: activeConnectorIds,
      phase: .planning,
      steps: [initial]
    )
  }

  var isTerminal: Bool {
    switch phase {
    case .completed, .failed, .cancelled:
      return true
    default:
      return false
    }
  }

  var activity: UgotAgentTurnActivity? {
    phase.activity
  }

  mutating func apply(_ event: UgotAgentTurnEvent) {
    guard !isTerminal else { return }
    let nextPhase = event.nextPhase
    phase = nextPhase
    steps.append(UgotAgentTurnStep(
      kind: event.kind,
      title: nextPhase.title,
      detail: nextPhase.detail,
      timestamp: ISO8601DateFormatter().string(from: Date())
    ))
  }
}

enum UgotAgentTurnPhase: Equatable, Sendable {
  case planning
  case ingestingAttachments(count: Int)
  case routePlanned(UgotAgentTurnRoute)
  case readingVisibleContext
  case searchingTools(connectorTitle: String)
  case awaitingApproval(connectorTitle: String, toolTitle: String)
  case runningTool(connectorTitle: String, toolTitle: String)
  case observingTool(connectorTitle: String, toolTitle: String, status: String)
  case compactingContext
  case generatingFinalAnswer(source: UgotAgentFinalAnswerSource)
  case completed(UgotAgentTurnOutcome)
  case failed(String)
  case cancelled(String)

  var title: String {
    switch self {
    case .planning:
      return "턴 준비 중"
    case .ingestingAttachments:
      return "파일 읽는 중"
    case .routePlanned:
      return "실행 경로 결정"
    case .readingVisibleContext:
      return "화면 내용 참고"
    case .searchingTools:
      return "도구 검색 중"
    case .awaitingApproval:
      return "승인 대기 중"
    case .runningTool:
      return "도구 실행 중"
    case .observingTool:
      return "도구 결과 확인"
    case .compactingContext:
      return "컨텍스트 압축 중"
    case .generatingFinalAnswer:
      return "답변 생성 중"
    case .completed:
      return "턴 완료"
    case .failed:
      return "턴 실패"
    case .cancelled:
      return "턴 취소"
    }
  }

  var detail: String {
    switch self {
    case .planning:
      return "요청, 첨부, 활성 기능을 기준으로 다음 실행 단계를 고르고 있어요."
    case .ingestingAttachments(let count):
      return count == 0 ? "첨부 파일 없이 진행해요." : "첨부 파일 \(count)개를 agent workspace에 저장하고 있어요."
    case .routePlanned(let route):
      return route.detail
    case .readingVisibleContext:
      return "열려 있는 위젯/카드 context를 우선 읽고 이어서 답할게요."
    case .searchingTools(let connectorTitle):
      return "\(connectorTitle)에서 실행 가능한 도구를 찾고 있어요."
    case .awaitingApproval(let connectorTitle, let toolTitle):
      return "\(connectorTitle)의 \(toolTitle) 실행은 사용자 승인이 필요해요."
    case .runningTool(let connectorTitle, let toolTitle):
      return "\(connectorTitle)의 \(toolTitle)을 실행하고 있어요."
    case .observingTool(_, let toolTitle, let status):
      return "\(toolTitle) 실행 결과를 확인했어요. 상태: \(status)."
    case .compactingContext:
      return "긴 이전 대화를 요약 메모리로 바꿔 다음 답변 성능을 유지하고 있어요."
    case .generatingFinalAnswer(let source):
      return source.detail
    case .completed(let outcome):
      return outcome.detail
    case .failed(let reason):
      return reason
    case .cancelled(let reason):
      return reason
    }
  }

  var activity: UgotAgentTurnActivity? {
    switch self {
    case .completed, .cancelled:
      return nil
    case .failed(let reason):
      return UgotAgentTurnActivity(symbol: "exclamationmark.triangle", title: title, detail: reason, showsProgress: false)
    case .planning:
      return UgotAgentTurnActivity(symbol: "sparkles", title: title, detail: detail, showsProgress: true)
    case .ingestingAttachments:
      return UgotAgentTurnActivity(symbol: "folder.badge.plus", title: title, detail: detail, showsProgress: true)
    case .routePlanned:
      return UgotAgentTurnActivity(symbol: "point.topleft.down.curvedto.point.bottomright.up", title: title, detail: detail, showsProgress: true)
    case .readingVisibleContext:
      return UgotAgentTurnActivity(symbol: "rectangle.on.rectangle", title: title, detail: detail, showsProgress: true)
    case .searchingTools:
      return UgotAgentTurnActivity(symbol: "sparkle.magnifyingglass", title: title, detail: detail, showsProgress: true)
    case .awaitingApproval:
      return UgotAgentTurnActivity(symbol: "hand.raised.fill", title: title, detail: detail, showsProgress: false)
    case .runningTool:
      return UgotAgentTurnActivity(symbol: "checkmark.shield", title: title, detail: detail, showsProgress: true)
    case .observingTool:
      return UgotAgentTurnActivity(symbol: "wrench.and.screwdriver", title: title, detail: detail, showsProgress: true)
    case .compactingContext:
      return UgotAgentTurnActivity(symbol: "arrow.triangle.2.circlepath", title: title, detail: detail, showsProgress: true)
    case .generatingFinalAnswer:
      return UgotAgentTurnActivity(symbol: "sparkles.rectangle.stack", title: title, detail: detail, showsProgress: true)
    }
  }
}

enum UgotAgentTurnRoute: Equatable, Sendable {
  case model
  case nativeSkill(id: String, title: String?)
  case mcpConnector(id: String, title: String?)
  case mcpConnectors(count: Int)
  case visibleContext

  var detail: String {
    switch self {
    case .model:
      return "이번 턴은 모델 답변으로 처리해요."
    case .nativeSkill(_, let title):
      return "\(title ?? "Native skill") 경로로 처리해요."
    case .mcpConnector(_, let title):
      return "\(title ?? "MCP connector") 도구 경로로 처리해요."
    case .mcpConnectors(let count):
      return "활성 MCP connector \(count)개에서 도구를 검색해요."
    case .visibleContext:
      return "현재 화면의 위젯 context를 읽고 답해요."
    }
  }
}

enum UgotAgentFinalAnswerSource: Equatable, Sendable {
  case model
  case toolObservation(toolTitle: String)
  case widget(toolTitle: String)
  case guardrail

  var detail: String {
    switch self {
    case .model:
      return "모델이 대화 context를 바탕으로 최종 답변을 생성하고 있어요."
    case .toolObservation(let toolTitle):
      return "\(toolTitle) 실행 결과를 바탕으로 최종 답변을 생성하고 있어요."
    case .widget(let toolTitle):
      return "\(toolTitle) 결과 위젯을 표시하고 있어요."
    case .guardrail:
      return "도구 실행 없이 완료했다고 말하지 않도록 안전 답변을 만들고 있어요."
    }
  }
}

enum UgotAgentTurnOutcome: Equatable, Sendable {
  case answered
  case showedWidget(toolTitle: String)
  case requestedApproval(toolTitle: String)
  case skippedToolSearch
  case guardrailStopped

  var detail: String {
    switch self {
    case .answered:
      return "최종 답변을 대화에 추가했어요."
    case .showedWidget(let toolTitle):
      return "\(toolTitle) 결과 위젯을 대화에 추가했어요."
    case .requestedApproval(let toolTitle):
      return "\(toolTitle) 실행 승인을 요청했어요."
    case .skippedToolSearch:
      return "이번 요청에 맞는 실행 도구가 없어 모델 답변으로 이어갔어요."
    case .guardrailStopped:
      return "실제 도구 실행 없이 변경 완료라고 말하지 않도록 중단했어요."
    }
  }
}

enum UgotAgentTurnEvent: Equatable, Sendable {
  case ingestAttachments(count: Int)
  case routePlanned(UgotAgentTurnRoute)
  case readVisibleContext
  case searchTools(connectorTitle: String)
  case skipToolSearch(connectorTitle: String)
  case requestApproval(connectorTitle: String, toolTitle: String)
  case approveTool(connectorTitle: String, toolTitle: String)
  case runTool(connectorTitle: String, toolTitle: String)
  case observeTool(connectorTitle: String, toolTitle: String, status: String)
  case compactContext
  case finishCompaction
  case generateFinalAnswer(UgotAgentFinalAnswerSource)
  case complete(UgotAgentTurnOutcome)
  case fail(String)
  case cancel(String)

  var kind: UgotAgentTurnStepKind {
    switch self {
    case .ingestAttachments:
      return .plan
    case .routePlanned:
      return .plan
    case .readVisibleContext:
      return .plan
    case .searchTools:
      return .searchTools
    case .skipToolSearch:
      return .searchTools
    case .requestApproval:
      return .requestApproval
    case .approveTool:
      return .requestApproval
    case .runTool:
      return .runTool
    case .observeTool:
      return .observe
    case .compactContext, .finishCompaction:
      return .plan
    case .generateFinalAnswer:
      return .finalAnswer
    case .complete:
      return .complete
    case .fail:
      return .failed
    case .cancel:
      return .cancelled
    }
  }

  var nextPhase: UgotAgentTurnPhase {
    switch self {
    case .ingestAttachments(let count):
      return .ingestingAttachments(count: count)
    case .routePlanned(let route):
      return .routePlanned(route)
    case .readVisibleContext:
      return .readingVisibleContext
    case .searchTools(let connectorTitle):
      return .searchingTools(connectorTitle: connectorTitle)
    case .skipToolSearch:
      return .routePlanned(.model)
    case .requestApproval(let connectorTitle, let toolTitle):
      return .awaitingApproval(connectorTitle: connectorTitle, toolTitle: toolTitle)
    case .approveTool(let connectorTitle, let toolTitle):
      return .runningTool(connectorTitle: connectorTitle, toolTitle: toolTitle)
    case .runTool(let connectorTitle, let toolTitle):
      return .runningTool(connectorTitle: connectorTitle, toolTitle: toolTitle)
    case .observeTool(let connectorTitle, let toolTitle, let status):
      return .observingTool(connectorTitle: connectorTitle, toolTitle: toolTitle, status: status)
    case .compactContext:
      return .compactingContext
    case .finishCompaction:
      return .planning
    case .generateFinalAnswer(let source):
      return .generatingFinalAnswer(source: source)
    case .complete(let outcome):
      return .completed(outcome)
    case .fail(let reason):
      return .failed(reason)
    case .cancel(let reason):
      return .cancelled(reason)
    }
  }
}

struct UgotAgentTurnStep: Equatable, Sendable {
  let kind: UgotAgentTurnStepKind
  let title: String
  let detail: String
  let timestamp: String
}

enum UgotAgentTurnStepKind: String, Equatable, Sendable {
  case plan
  case searchTools = "search_tools"
  case requestApproval = "request_approval"
  case runTool = "run_tool"
  case observe
  case finalAnswer = "final_answer"
  case complete
  case failed
  case cancelled
}

struct UgotAgentTurnActivity: Equatable, Sendable {
  let symbol: String
  let title: String
  let detail: String
  let showsProgress: Bool
}
