---
name: mcp-thin-host-boundary
description: Enforce MCP client/server concern separation for UGOT mobile and agent hosts. Use when changing MCP tool search, prompt/resource attachments, approval UX, widget rendering, connector routing, Fortune/Mail/external connector support, or any mobile code that risks embedding connector-specific intent such as saved users, fortune, mail account, or domain keywords. Trigger when debugging wrong MCP tool selection, prompt argument routing, widget context, or adding external connectors.
---

# MCP Thin Host Boundary

Keep the mobile app a thin MCP host. Do not fix connector behavior by adding connector-domain rules to iOS/Android UI code.

## Non-negotiable boundary

- Mobile host may own protocol/UX mechanics only:
  - connector enablement and auth state
  - MCP initialize/listTools/listPrompts/listResources/callTool/readResource/getPrompt
  - prompt/resource attachments as structured context
  - approval modal and tool-call timeline projection
  - widget iframe/webview/App Bridge transport
  - generic annotations such as `readOnlyHint`, `destructiveHint`, `idempotentHint`, widget resource URI, output schema, and MCP errors
- MCP servers own domain meaning:
  - tool names, titles, descriptions, localized descriptions, prompt text, resource contents
  - `_meta` search hints/keywords and argument UI hints
  - default target resolution, saved-user lookup, account lookup, and domain-specific aliases
  - whether a tool is “today fortune”, “saju chart”, “mail summary”, etc.
- Shared/KMP core may own connector-agnostic agent state:
  - plan → search tools → approval → call tool → observe → final answer
  - retries, no-match handling, persistence, compaction, artifact/VFS, and typed turn state

## Forbidden in mobile MCP core

Do not add connector-specific keywords, examples, or fallback routing to files like:

- `iosApp/Sources/GalleryIOS/UgotMCPToolSearchIndex.swift`
- `iosApp/Sources/GalleryIOS/UgotMCPActionRunner.swift`
- Android/KMP equivalents

Examples of forbidden fixes:

- “If query contains 오늘/사주 then prefer show_today_fortune.”
- “If prompt name is explain-current-saju then block show_today_fortune.”
- “If target_name is David then call a Fortune saved-user tool.”
- “If mail account wording then call a specific mail tool by hardcoded name.”

Use server metadata/schema instead.

## Correct fix workflow

1. Reproduce with a smoke test using only MCP metadata and structured prompt/resource attachment data.
2. If tool selection is wrong, first inspect the server-provided tool/prompt/resource metadata.
3. Fix the MCP server contract:
   - improve tool description/title/annotations
   - add localized `_meta.tool/searchKeywords` or equivalent search hints
   - expose a higher-level tool when the client lacks required domain fields
   - make prompt arguments explicit and include selected values in prompt result
   - resolve defaults and saved targets server-side
4. Keep mobile changes generic:
   - consume metadata
   - render structured attachments/chips
   - validate read-only vs mutating policy
   - surface no-match/approval/tool observations
5. Add tests on both sides:
   - server: metadata and prompt/tool schema contract tests
   - mobile: generic ranking/state-machine tests with synthetic non-domain connectors
   - boundary: run `scripts/check_mobile_mcp_boundary.sh`

## Immediate triage checklist

When a selected MCP prompt/resource still answers with a previous/default target:

- Verify the user-visible attachment stores selected arguments structurally.
- Verify the prompt result includes selected argument values, not only display text.
- Verify a domain tool exists that can run with that selected value or server can resolve it.
- If required fields are domain-specific, add a server-side wrapper or make the server resolve `name`/resource URI to full domain params.
- Do not make the mobile host parse that domain object.

## If a quick hotfix is unavoidable

Place temporary connector-specific compatibility code behind a clearly named adapter file, mark it with `TODO(mcp-thin-host-boundary): remove after server metadata contract`, and add an issue/test proving it is temporary. Never put it in the generic search index or action runner.
