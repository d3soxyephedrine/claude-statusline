#!/usr/bin/env bun
// Background SSE watcher — connects to proxy /stream, writes live state to file.
// Auto-started by statusline.sh when bun is available. PID → /tmp/claude-proxy-watcher.pid.

const STATE = "/tmp/claude-proxy-state";
const PID_FILE = "/tmp/claude-proxy-watcher.pid";
const PROXY_PORT = process.env.CLAUDE_PROXY_PORT || "3456";
const PROXY_HOST = process.env.CLAUDE_PROXY_HOST || "127.0.0.1";
const BASE = `http://${PROXY_HOST}:${PROXY_PORT}`;
const STREAM = `${BASE}/stream`;
const HEALTH = `${BASE}/health`;

const state = {
  activity: "idle" as string,
  snippet: "",
  tool: "",
  reqs: 0,
  inTok: 0,
  outTok: 0,
  tokenExp: 0,
  ts: Date.now(),
};

function save() {
  state.ts = Date.now();
  Bun.write(STATE, JSON.stringify(state));
}

// Poll /health every 10s for cumulative stats + token expiry
setInterval(async () => {
  try {
    const r = await fetch(HEALTH);
    const d = (await r.json()) as any;
    state.reqs = d.stats?.totalRequests ?? state.reqs;
    state.inTok = d.stats?.totalInputTokens ?? state.inTok;
    state.outTok = d.stats?.totalOutputTokens ?? state.outTok;
    state.tokenExp = d.token?.expiresIn ?? 0;
    save();
  } catch {}
}, 10000);

// Initial health fetch
try {
  const r = await fetch(HEALTH);
  const d = (await r.json()) as any;
  state.reqs = d.stats?.totalRequests ?? 0;
  state.inTok = d.stats?.totalInputTokens ?? 0;
  state.outTok = d.stats?.totalOutputTokens ?? 0;
  state.tokenExp = d.token?.expiresIn ?? 0;
} catch {}

// SSE stream for live activity
async function stream() {
  while (true) {
    try {
      const res = await fetch(STREAM);
      if (!res.body) throw new Error("no body");
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });

        const parts = buf.split("\n\n");
        buf = parts.pop() || "";

        for (const part of parts) {
          if (part.startsWith(":")) continue;
          const lines = part.split("\n");
          const eventLine = lines.find((l) => l.startsWith("event: "));
          const dataLine = lines.find((l) => l.startsWith("data: "));
          if (!eventLine) continue;

          const event = eventLine.slice(7);
          let data: any = {};
          if (dataLine) {
            try { data = JSON.parse(dataLine.slice(6)); } catch {}
          }

          switch (event) {
            case "request_start":
              state.activity = "starting";
              state.snippet = `${data.model ?? "?"} msgs=${data.messages ?? "?"}`;
              state.reqs++;
              break;
            case "thinking_start":
              state.activity = "thinking";
              state.snippet = "";
              break;
            case "text_start":
              state.activity = "text";
              state.snippet = "";
              break;
            case "tool_start":
              state.activity = "tool";
              state.tool = data.name ?? "?";
              state.snippet = "";
              break;
            case "server_tool_start":
              state.activity = "server_tool";
              state.tool = data.name ?? "?";
              state.snippet = "";
              break;
            case "delta":
              state.snippet = (state.snippet + (data.text ?? ""))
                .replace(/\n+/g, " ")
                .trim()
                .slice(-250);
              break;
            case "tool_input":
              state.snippet = (data.summary ?? "").slice(0, 120);
              break;
            case "block_end":
              break;
            case "request_end":
              state.activity = "idle";
              state.snippet = `done out=${data.output_tokens ?? 0} ${data.stop_reason ?? ""}`;
              break;
          }
          save();
        }
      }
    } catch {
      state.activity = "disconnected";
      save();
      await Bun.sleep(3000);
    }
  }
}

await Bun.write(PID_FILE, String(process.pid));
save();
stream();
