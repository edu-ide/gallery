import Foundation

@main
struct AgentTurnStateSmoke {
  static func main() {
    var turn = UgotAgentTurnState.start(
      userPrompt: "오늘의 운세 알려줘",
      attachmentCount: 0,
      activeSkillIds: [],
      activeConnectorIds: ["fortune"]
    )
    assert(turn.phase == .planning)
    turn.apply(.routePlanned(.mcpConnector(id: "fortune", title: "Fortune")))
    turn.apply(.searchTools(connectorTitle: "Fortune"))
    turn.apply(.requestApproval(connectorTitle: "Fortune", toolTitle: "오늘의 운세"))
    turn.apply(.approveTool(connectorTitle: "Fortune", toolTitle: "오늘의 운세"))
    turn.apply(.observeTool(connectorTitle: "Fortune", toolTitle: "오늘의 운세", status: "success"))
    turn.apply(.generateFinalAnswer(.toolObservation(toolTitle: "오늘의 운세")))
    turn.apply(.complete(.answered))
    assert(turn.isTerminal)
    assert(turn.steps.map(\.kind) == [.plan, .plan, .searchTools, .requestApproval, .requestApproval, .observe, .finalAnswer, .complete])

    var fallback = UgotAgentTurnState.start(
      userPrompt: "그냥 대화하자",
      attachmentCount: 0,
      activeSkillIds: [],
      activeConnectorIds: ["fortune"]
    )
    fallback.apply(.routePlanned(.mcpConnectors(count: 1)))
    fallback.apply(.searchTools(connectorTitle: "활성 MCP 커넥터"))
    fallback.apply(.skipToolSearch(connectorTitle: "활성 MCP 커넥터"))
    assert(!fallback.isTerminal)
    fallback.apply(.generateFinalAnswer(.model))
    fallback.apply(.complete(.answered))
    assert(fallback.isTerminal)

    print("agent_turn_state_smoke: ok")
  }
}
