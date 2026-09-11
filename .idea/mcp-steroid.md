# MCP Steroid Server

- **URL**: http://localhost:6315/mcp

=== Quick Start ===

Claude CLI:
  claude mcp add --transport http --scope user mcp-steroid http://localhost:6315/mcp

Codex CLI:
  codex mcp add mcp-steroid --url http://localhost:6315/mcp

Gemini CLI:
  gemini mcp add mcp-steroid --type http http://localhost:6315/mcp --scope user --trust

Cursor and other's JSON config:

This is what `mcpServers` JSON may look like:
  {
    "mcpServers": {
      "mcp-steroid": {
        "type": "http",
        "url": "http://localhost:6315/mcp"
      }
    }
  }
  

## Feedback

Report issues: https://github.com/jonnyzzz/mcp-steroid/issues

