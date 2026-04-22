# UGOT MCP Apps Host Shell

Shared JavaScript host shell for rendering MCP Apps (`text/html;profile=mcp-app`) inside native iOS/Android WebViews.

The shell uses the official `@modelcontextprotocol/ext-apps/app-bridge` package for the View ↔ Host protocol. Native code owns auth and MCP network calls, while this shell owns iframe rendering, AppBridge handshake, tool input/result delivery, sizing, links, and model-context messages.

Build:

```bash
cd shared/mcp-apps-host
npm install
npm run build
```

The build output currently targets `iosApp/Resources/MCPAppsHost/host-shell.js`; Android can consume the same bundle from this package or copy it into assets.
