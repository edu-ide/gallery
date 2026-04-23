## MCP / Connector architecture guardrail

- For any MCP, connector, prompt/resource, widget, tool-search, approval, or mobile agent-loop work, first read and follow `.agents/skills/mcp-thin-host-boundary/SKILL.md`.
- The iOS/Android/KMP mobile app must stay a thin MCP host. Do not add Fortune/Mail/external-connector domain routing, localized domain keywords, or tool-name special cases to generic mobile MCP files.
- Put domain meaning in the MCP server contract: tool descriptions, annotations, localized `_meta` search hints, schemas, prompts, resources, and server-side target/account resolution.
- Before accepting MCP mobile changes, run `.agents/skills/mcp-thin-host-boundary/scripts/check_mobile_mcp_boundary.sh .` and either pass it or document the remaining migration debt explicitly.
