# Unified Local AI Chat With MCP Design

Date: 2026-04-18

## Summary

This design converges Gallery's split chat-style experiences into one unified local AI chat shell without turning the codebase into a fork-hostile monolith.

The target UX is:

- one primary AI chat experience
- one shared transcript per conversation
- one native composer that supports text, image, audio, connectors, and tools
- inline MCP widgets in the timeline with optional fullscreen expansion
- one local session history sidebar/drawer

The target implementation is not "delete all task screens and rewrite Gallery around one giant screen". Instead, the unified chat becomes a shared shell with capability providers and renderer adapters. Existing task entries remain as thin wrappers or entry aliases so upstream merges stay manageable.

## Goals

- Provide one coherent conversation flow for local AI chat.
- Allow text, image, audio, skills, mobile actions, interactive apps, and MCP connectors in the same transcript.
- Make MCP widgets feel like Claude/ChatGPT style inline app cards with fullscreen expansion, not separate pages by default.
- Keep the local model as the primary conversation runtime.
- Support conversation-scoped approval plus connector or tool level "always allow".
- Preserve upstream merge friendliness by extracting custom behavior into additive provider and adapter layers.

## Non-Goals

- Do not delete all existing built-in or custom tasks immediately.
- Do not rewrite the existing chat stack from scratch.
- Do not make MCP the only extensibility system.
- Do not require server-side session history support for MCP connectors.
- Do not force all widget cards to stay live and interactive forever.

## Current State

Gallery currently exposes multiple separate task flows:

- `AI Chat`
- `Ask Image`
- `Audio Scribe`
- `Agent Skills`
- `Mobile Actions`
- `Tiny Garden`
- `UGOT Fortune`

These are split across built-in chat tasks and custom task screens. Some share `LlmChatScreen` and `ChatView`, but others use separate custom task UIs and navigation routes. This produces fragmented UX and pushes product logic into hot upstream files such as:

- `ui/navigation/GalleryNavGraph.kt`
- `ui/llmchat/LlmChatScreen.kt`
- `ui/common/chat/ChatView.kt`
- `ui/common/chat/ChatPanel.kt`
- `ui/common/chat/MessageInputText.kt`
- `ui/modelmanager/ModelManagerViewModel.kt`

This design intentionally reduces future churn in those files.

## Product Principles

### One Conversation, Many Capabilities

Users should not think in terms of task IDs, modes, or presets. They should stay in one conversation and use whichever capability is needed at that moment.

### Local Model First

The active local model remains the main conversational agent. Connectors, tools, and widgets extend that conversation rather than replacing it.

### Inline By Default

MCP and app-like outputs appear as inline cards in the transcript. Fullscreen is an expansion state of a card, not a separate product surface.

### Graceful Capability Negotiation

When the current model cannot support image, audio, or a required tool quality threshold, the app proposes a compatible local model switch while preserving the same conversation.

### Merge-Friendly Isolation

Custom product behavior must be expressed through registries, providers, adapters, and wrapper routes instead of broad rewrites of upstream orchestration files.

## Target UX

## Shell

The unified chat screen contains:

- a local session history sidebar or drawer
- a main transcript area
- a native composer at the bottom
- a connector bar adjacent to the composer
- inline app and MCP widget cards in the transcript
- a fullscreen overlay for expanded widgets when needed

Back behavior is:

1. close open drawer
2. close fullscreen widget
3. prompt for conversation exit or navigate back to app home

It is not:

- back from Fortune card to AI Chat page
- back from one specialized task page to another

## Composer

The composer is one shared input surface that supports:

- plain text input
- image attachment
- audio attachment and recording
- connector pills
- tool and skill entry points
- attachment previews

The connector row is always visible near the composer. It exposes active connectors as pills and includes a `Connectors` affordance for fuller configuration.

## Inline Cards

The transcript supports:

- text responses
- image and audio content
- system and error messages
- approval cards
- MCP widget cards
- interactive app cards

MCP widget cards retain their position in the transcript. When a card is expanded, the fullscreen view preserves the composer outside the card context conceptually, matching the embedded-app model rather than page navigation.

## Session History

History is local and conversation-centric. A session stores:

- title
- last message preview
- active connectors
- approval policy state
- transcript items
- widget snapshots and state references
- model switching history

The session model does not depend on MCP servers exposing history APIs.

## Capability Model

The unified chat runtime uses capability providers instead of task-exclusive screens.

### Core Capability Types

- text conversation
- image input and image-aware prompting
- audio input and transcription or translation
- skill discovery and execution
- mobile action tool invocation
- MCP connector invocation
- interactive app rendering

### Provider Contract

Each capability provider declares:

- what inputs it supports
- what renderer types it contributes
- what tools it can expose
- what model requirements it has
- what permissions it needs
- what persistence fields it needs

This allows the shared shell to compose multiple capabilities in one conversation without embedding each product directly into core chat files.

## Architecture

## Shared Shell

Add a new unified chat surface as a shared shell, not a replacement fork of chat internals.

Proposed additive modules:

- `ui/unifiedchat/CapabilityProvider.kt`
- `ui/unifiedchat/CapabilityRegistry.kt`
- `ui/unifiedchat/ConversationOrchestrator.kt`
- `ui/unifiedchat/ConnectorBarState.kt`
- `ui/unifiedchat/MessageRendererRegistry.kt`
- `ui/unifiedchat/session/`
- `ui/unifiedchat/mcp/`
- `ui/unifiedchat/image/`
- `ui/unifiedchat/audio/`
- `ui/unifiedchat/mobileactions/`
- `ui/unifiedchat/skills/`
- `ui/unifiedchat/interactiveapps/`

The existing chat stack remains the base shell. The new layer extends it through slots and registries rather than replacing its internal control flow wholesale.

## Conversation Orchestrator

The orchestrator is responsible for:

- routing user input to the local model
- determining when a capability or connector should be invoked
- coordinating approval checks
- emitting transcript items
- managing widget lifecycle
- proposing model switches when a capability mismatch occurs

The orchestrator owns the active conversation runtime state, not the individual task wrappers.

## Message Renderer Registry

Extend the current message model by adding additive renderer support. The core transcript remains shared, but rendering becomes pluggable.

New additive message classes or equivalents should support:

- MCP widget card
- approval decision card
- interactive app card
- connector status card
- model-switch recommendation card

Existing message types remain intact. New renderers are registered alongside them.

## MCP Widget Hosting

The MCP host remains generic. The current `McpUiSession` pattern is retained and generalized.

The host responsibilities are:

- connect to MCP server
- select compatible widget resources
- inject the host bridge
- provide tool call routing
- persist widget state snapshots
- restore cards into inline or fullscreen presentation

Only one live widget host needs to be active at a time. Older cards remain in the transcript as cards with saved state and summary. When the user focuses an older card again, the host reconnects and rehydrates it on demand.

## Model Compatibility

Capability use is negotiated against the active model.

If the user initiates a capability that the active model does not support:

- the app proposes a compatible local model switch
- the conversation remains the same conversation
- the transcript remains intact
- the new model continues in the same session context

If no compatible model exists:

- keep the user in the current conversation
- emit a clear explanation
- suggest the nearest fallback behavior

## Approval Policy

Approval defaults to conversation-scoped allow.

Users may upgrade approval to:

- connector-level always allow
- tool-level always allow

Stored approval state is split into:

- per-conversation transient approvals
- durable always-allow approvals

Starting a new conversation resets conversation-scoped approvals but preserves always-allow decisions.

## Persistence and Restoration

Each conversation persists:

- transcript items
- active connector set
- current and previous model IDs
- approval state
- widget metadata
- widget state JSON or equivalent snapshot
- lightweight card summary for unloaded widgets

On restore:

- transcript items render immediately
- widget cards render as saved cards
- live widget connections are not all re-established automatically
- a card becomes live when the user reopens or expands it

This avoids expensive eager restoration and reduces runtime fragility.

## Existing Feature Mapping

Current separate tasks map into the unified chat as capabilities:

- `AI Chat` becomes the baseline conversation flow
- `Ask Image` becomes image input capability in the unified composer
- `Audio Scribe` becomes audio input capability in the unified composer
- `Agent Skills` becomes a skills capability provider and tool surface
- `Mobile Actions` becomes a mobile-actions provider and approval-governed tool surface
- `Tiny Garden` becomes an interactive app capability rendered inline or fullscreen
- `UGOT Fortune` becomes an MCP connector using the generic widget host

These entries should remain temporarily as launch aliases or wrappers, but they should enter the same unified shell.

## Upstream Merge-Friendly Strategy

This design deliberately avoids broad rewrites in upstream hot files.

### Rules

1. Keep `GalleryNavGraph` changes small and route-oriented.
2. Keep `LlmChatScreen`, `ChatView`, `ChatPanel`, and `MessageInputText` changes slot-based and additive.
3. Move connector, widget, approval, and capability logic into new helper modules under new directories.
4. Do not delete existing tasks immediately.
5. Convert existing tasks into thin wrappers that open the unified shell with capability hints, while the shell itself remains one product.

### Hot File Policy

The following files should only receive minimal integration edits:

- `GalleryNavGraph.kt`
- `LlmChatScreen.kt`
- `ChatView.kt`
- `ChatPanel.kt`
- `MessageInputText.kt`
- `ModelManagerViewModel.kt`

All domain-specific logic for MCP, audio, image, interactive apps, mobile actions, and approvals should live in new helper files.

### Why This Is Merge Friendly

- upstream can continue evolving the main chat shell
- local product logic stays in additive files
- wrappers preserve old entry points without forcing immediate deletion conflicts
- new behavior can often be reattached by reapplying slot wiring instead of remerging large logic blocks

## Migration Plan

### Phase 1

- introduce unified capability registry
- introduce connector bar slot and message renderer registry
- keep existing task routes
- route `UGOT Fortune` through shared MCP widget cards where possible

### Phase 2

- let `Ask Image`, `Audio Scribe`, and `Agent Skills` open the same unified shell
- preserve old task entries as wrappers for discoverability
- move capability-specific input affordances into shared composer

### Phase 3

- integrate `Mobile Actions` and `Tiny Garden` into the same shell as capabilities
- retire specialized navigation assumptions
- keep wrappers only as aliases or onboarding shortcuts

### Phase 4

- make unified chat the default primary conversation experience
- reduce product emphasis on separate task surfaces

## Error Handling

Errors must be explicit and typed, not collapsed into generic network failures.

Required categories:

- authentication required
- permission denied
- connector unavailable
- model incompatible
- widget render failed
- tool invocation failed

Errors appear in the transcript as system or retryable cards. Fullscreen widgets should fail in place and offer return to inline state rather than collapsing the whole shell.

## Testing Strategy

### Unit Tests

- capability negotiation
- approval state transitions
- renderer registration
- model switch recommendation logic
- widget snapshot persistence and restoration

### Integration Tests

- unified composer with text, image, and audio paths
- connector enable and disable behavior
- inline widget creation
- fullscreen expansion and collapse
- session restoration with dormant widget cards

### Runtime Smoke Tests

- local model conversation with no connectors
- image and audio prompts in the same transcript
- connector invocation that creates inline MCP cards
- fullscreen widget path
- app restart and session restore
- approval escalation from conversation to always-allow

### Regression Checks

- no back-navigation bounce from connector cards into unrelated task pages
- old widget cards remain in transcript
- connector state remains scoped to the correct conversation
- native auth and MCP widget hosting do not interfere with each other

## Decision

Adopt one unified local AI chat shell built on top of the current Gallery chat infrastructure, extended with capability providers, connector-aware composer UI, inline MCP widget cards, and merge-friendly adapter layers.

Do not collapse the app into a forked mega-screen. Use the existing chat shell as the base and converge features into it through additive modules and thin wrapper routes.
