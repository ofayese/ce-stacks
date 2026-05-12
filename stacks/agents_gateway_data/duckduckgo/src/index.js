import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

function logStructured(severity, reason, detail) {
  console.error(
    JSON.stringify({
      ts: new Date().toISOString(),
      severity,
      reason,
      detail: detail != null ? String(detail) : null,
    }),
  );
}

process.on("unhandledRejection", (reason) => {
  logStructured("error", "unhandledRejection", reason);
  process.exit(1);
});

process.on("uncaughtException", (err) => {
  logStructured("error", "uncaughtException", err);
  process.exit(1);
});

const server = new McpServer({
  name: "demo-server",
  version: "1.0.0",
});

// Add a get current time tool
server.registerTool(
  "get_current_time",
  {
    title: "Get Current Time Tool",
    description: "Get the current server time",
    inputSchema: z.object({
      timezone: z
        .string()
        .describe("Timezone in IANA format, e.g., America/New_York"),
    }),
    outputSchema: z.object({ result: z.string() }),
  },
  async ({ timezone }) => {
    const currentTime = new Date().toLocaleString("en-US", {
      timeZone: timezone,
    });
    const output = { result: currentTime };
    return {
      content: [{ type: "text", text: JSON.stringify(output) }],
      structuredContent: output,
    };
  },
);

const transport = new StdioServerTransport();
try {
  await server.connect(transport);
} catch (err) {
  logStructured("error", "server.connect", err);
  process.exit(1);
}
