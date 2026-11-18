// Trellis agent state for OpenCode 2.x (FR-AG21): reports when a turn starts, waits on you and finishes so the pane's
// tab can show it. Only the event name (and the model's ID) is sent, through Trellis's helper; nothing from the
// conversation leaves OpenCode. Trellis loads this with OPENCODE_CONFIG_CONTENT into the pane's own `--standalone`
// server, so the helper and the pane's hook channel come from the environment. It never prints and never throws.
import { spawn } from "node:child_process";

// The Trellis event for an OpenCode event, or null. A subagent session's turns are filtered by the caller.
export function trellisEvent(event) {
  switch (event?.type) {
    case "session.execution.started":
    case "permission.replied":
    case "form.replied":
    case "form.cancelled":
      return "working";
    case "permission.asked":
    case "form.created":
      return "needs-input";
    case "session.execution.succeeded":
      return "done";
    case "session.execution.failed":
      return "error";
    case "session.execution.interrupted":
      // Stopped by you: back to ready, no "Done" notification. A superseded run is followed by the next one.
      switch (event.data?.reason) {
        case "user": return "start";
        case "shutdown": return "end";
        case "superseded": return null;
        default: return "done";
      }
    default:
      return null;
  }
}

// The session an event belongs to: forms carry it on the form.
export function sessionOf(event) {
  return event?.data?.sessionID ?? event?.data?.form?.sessionID ?? null;
}

export default {
  id: "trellis-agent-state",
  async setup(ctx) {
    const helper = process.env.TRELLIS_AGENT_HOOK;
    if (!helper || !process.env.TRELLIS_AGENT_NONCE) return;
    // One helper at a time, in order: concurrent helpers race, and a late "working" would hide a finished turn. A helper
    // stuck past 5 s is killed rather than left to report out of order.
    let queue = Promise.resolve();
    const run = (name, payload) =>
      new Promise((resolve) => {
        let child;
        const timer = setTimeout(() => { try { child?.kill("SIGKILL"); } catch {} resolve(); }, 5000);
        const finish = () => { clearTimeout(timer); resolve(); };
        try {
          child = spawn(helper, ["agent-hook", name], { stdio: [payload ? "pipe" : "ignore", "ignore", "ignore"] });
          child.on("error", finish);
          child.on("exit", finish);
          if (payload) {
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify(payload));
          }
        } catch { finish(); }
      });
    const send = (name, payload) => { queue = queue.then(() => run(name, payload)); };
    // Execution events carry no parent: a session is asked once whether it is a subagent's.
    const roots = new Map();
    const isRoot = async (sessionID) => {
      if (!roots.has(sessionID)) {
        let root = true;
        try { root = !(await ctx.session.get({ sessionID }))?.parentID; } catch {}
        if (roots.size > 256) roots.clear();
        roots.set(sessionID, root);
      }
      return roots.get(sessionID);
    };
    const reportModel = async (sessionID) => {
      try {
        const model = (await ctx.session.get({ sessionID }))?.model;
        if (model?.id) send("info", { model: model.id, effort: { level: model.variant } });
      } catch {}
    };
    send("start");
    const abort = new AbortController();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: abort.signal })) {
          const name = trellisEvent(event);
          const sessionID = sessionOf(event);
          // A subagent's turns aren't the pane's, but its permission requests and questions wait on you all the same.
          const turn = event.type.startsWith("session.execution.");
          if (!name || !sessionID || (turn && !(await isRoot(sessionID)))) continue;
          send(name);
          if (event.type === "session.execution.started") await reportModel(sessionID);
        }
      } catch {}
    })();
    return () => abort.abort();
  },
};
