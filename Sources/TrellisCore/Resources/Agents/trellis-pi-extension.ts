// Trellis agent state for pi (FR-AG08): reports when a prompt starts and finishes so the pane's tab can show it.
// Only the event name is sent, through Trellis's helper; nothing from the conversation leaves pi.
import { spawn } from "node:child_process";

export default function (pi: any) {
  const helper = process.env.TRELLIS_AGENT_HOOK;
  if (!helper || !process.env.TRELLIS_AGENT_NONCE) return;
  const send = (event: string) => {
    try {
      spawn(helper, ["agent-hook", event], { stdio: "ignore" }).on("error", () => {});
    } catch {}
  };
  pi.on("session_start", async () => send("start"));
  pi.on("agent_start", async () => send("working"));
  pi.on("tool_call", async () => send("working"));
  pi.on("agent_end", async () => send("done"));
  pi.on("session_shutdown", async () => send("end"));
}
