export function classifyTranscript({ session, entries }) {
  const timing = transcriptTiming(entries);
  const cardEntries = timing.latestUserAt
    ? entries.filter((entry) => entry.stream !== "user" && entry.timestamp > timing.latestUserAt)
    : entries;
  const rawText = cardEntries.map((entry) => entry.chunk).join("");
  const displayLines = transcriptDisplayLines(rawText);
  const card = classifyActionCard(session, displayLines, timing);

  return { rawText, displayLines, card };
}

export function transcriptDisplayLines(rawText) {
  const lines = cleanTerminalText(rawText)
    .replace(/\s+([⚠✖✔])\s*/g, "\n$1 ")
    .replace(/\s+([›>])\s+/g, "\n$1 ")
    .replace(/([^\n])›(?=\S)/g, "$1\n›")
    .replace(/\s*(\[(?:user|steer|codex|claude)\])/gi, "\n$1")
    .replace(/\s{2,}(gpt-[\w.-]+[^\n]*·[^\n]*)/g, "\n$1")
    .split("\n")
    .flatMap(splitTerminalDisplayLine)
    .map((line) => line.replace(/[ \t]{2,}/g, " ").trim())
    .filter(isMeaningfulTerminalLine)
    .slice(-28);

  return lines.length > 0 ? lines : ["[no transcript yet]"];
}

function transcriptTiming(entries) {
  let latestUserAt = null;
  let latestOutputAt = null;

  for (const entry of entries) {
    if (entry.stream === "user") {
      latestUserAt = maxTimestamp(latestUserAt, entry.timestamp);
      continue;
    }

    if ((entry.stream === "stdout" || entry.stream === "stderr") && transcriptDisplayLines(entry.chunk).some(isContentLineForAction)) {
      latestOutputAt = maxTimestamp(latestOutputAt, entry.timestamp);
    }
  }

  return { latestUserAt, latestOutputAt };
}

function maxTimestamp(current, next) {
  if (!next) return current;
  if (!current) return next;
  return next > current ? next : current;
}

function classifyActionCard(session, displayLines, timing = {}) {
  const provider = providerDisplayName(session.provider);
  const command = session.command || session.provider;
  const body = displayLines.join("\n");
  const lower = body.toLowerCase();
  const summary = displayLines.at(-1) || "No transcript captured yet.";
  const titlePrefix = `${provider} · ${command}`;
  const answered = timing.latestUserAt && (!timing.latestOutputAt || timing.latestUserAt >= timing.latestOutputAt);

  if (answered) {
    return {
      category: "answered",
      priority: "silent",
      title: `${titlePrefix} answered`,
      summary,
      actionPrompt: "Waiting for the session to produce a new actionable response.",
      options: [],
      state: "done",
      highlightedLineIndexes: []
    };
  }

  if (session.run_state === "blocked" || session.run_state === "disconnected" || hasAny(lower, [
    "blocked",
    "permission denied",
    "approval",
    "error:",
    "failed",
    "exception",
    "cannot",
    "can't",
    "fatal"
  ])) {
    return {
      category: "blocker",
      priority: "urgent",
      title: `${titlePrefix} needs unblock`,
      summary,
      actionPrompt: "Review the blocker and send the next instruction.",
      options: ["Use simplest fix", "Explain blocker", "Continue"],
      state: "active",
      highlightedLineIndexes: highlightIndexes(displayLines, ["blocked", "error", "failed", "permission", "approval"])
    };
  }

  if (hasAny(lower, ["decision", "choose", "option a", "option b", "which option", "confirm"])) {
    return {
      category: "decision",
      priority: "normal",
      title: `${titlePrefix} needs a decision`,
      summary,
      actionPrompt: "Choose a direction so the session can continue.",
      options: ["Use your recommendation", "Pick simpler option", "Explain options"],
      state: "active",
      highlightedLineIndexes: highlightIndexes(displayLines, ["decision", "choose", "option", "confirm"])
    };
  }

  if (body.includes("?") || hasAny(lower, ["should i", "do you want", "would you like", "need your input"])) {
    return {
      category: "question",
      priority: "normal",
      title: `${titlePrefix} has a question`,
      summary,
      actionPrompt: "Answer the question or give a direct next instruction.",
      options: ["Yes, continue", "Use your judgment", "Explain first"],
      state: "active",
      highlightedLineIndexes: highlightIndexes(displayLines, ["?", "should", "want", "input"])
    };
  }

  if (session.run_state === "ended" || hasAny(lower, ["complete", "completed", "done", "success", "passed"])) {
    return {
      category: "completion",
      priority: "silent",
      title: `${titlePrefix} completed`,
      summary,
      actionPrompt: "Review the result or send a follow-up instruction.",
      options: ["Summarize result", "Next task", "Archive"],
      state: "done",
      highlightedLineIndexes: highlightIndexes(displayLines, ["complete", "done", "success", "passed"])
    };
  }

  return {
    category: "progress",
    priority: "silent",
    title: `${titlePrefix} is running`,
    summary,
    actionPrompt: "Send a proactive instruction if needed.",
    options: ["Continue", "Summarize progress", "Pause after current step"],
    state: "done",
    highlightedLineIndexes: []
  };
}

function providerDisplayName(provider) {
  if (provider === "claude") return "Claude Code";
  if (provider === "codex") return "Codex CLI";
  if (provider === "gemini") return "Gemini CLI";
  return "CLI Session";
}

function hasAny(value, needles) {
  return needles.some((needle) => value.includes(needle));
}

function highlightIndexes(lines, needles) {
  return lines
    .map((line, index) => {
      const lower = line.toLowerCase();
      return needles.some((needle) => lower.includes(needle)) ? index : -1;
    })
    .filter((index) => index >= 0);
}

export function cleanTerminalText(value) {
  return value
    .replace(/\x1B\][^\x07]*(?:\x07|\x1B\\)/g, "")
    .replace(/\x1B[PX^_][\s\S]*?\x1B\\/g, "")
    .replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\x1B[@-Z\\-_]/g, "")
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "")
    .replace(/\r/g, "\n");
}

function splitTerminalDisplayLine(line) {
  return line
    .replace(/\s+(gpt-[\w.-]+[^\n]*·[^\n]*)/g, "\n$1")
    .split("\n");
}

function isMeaningfulTerminalLine(line) {
  if (!line) return false;
  if (!/[A-Za-z0-9가-힣⚠✖✔›>]/.test(line)) return false;
  if (!isContentLineForAction(line)) return false;
  return true;
}

function isContentLineForAction(line) {
  if (!line) return false;
  if (/^\s*(?:\[user\]|\[steer\])/.test(line)) return false;
  if (/^\s*›/.test(line)) return false;
  if (/^gpt-[\w.-]+.*·/i.test(line)) return false;
  if (/^\s*[A-Za-z]{1,2}\s*$/.test(line)) return false;
  if (/^\]1[01];\?\\?$/.test(line)) return false;
  if (/^Tip: Try the Codex App/i.test(line)) return false;
  if (/^https:\/\/chatgpt\.com\/codex/i.test(line)) return false;
  if (/Under-development features enabled/i.test(line)) return false;
  if (/features are incomplete/i.test(line)) return false;
  if (/suppress_unstable_features_warning/i.test(line)) return false;
  if (/config\.toml/i.test(line)) return false;
  if (/MCP client for `?pencil`? failed/i.test(line)) return false;
  if (/MCP startup failed/i.test(line)) return false;
  if (/No such file or directory/i.test(line)) return false;
  if (/os error 2/i.test(line)) return false;
  if (/MCP startup incomplete/i.test(line)) return false;
  if (/esc to interr/i.test(line)) return false;
  if (/esc again to edit previous message/i.test(line)) return false;
  if (/tab to queue message/i.test(line)) return false;
  if (/Starting MCP servers/i.test(line)) return false;
  if (/SStt|WWoorr|MMCC|rrvv|sseerr/i.test(line)) return false;
  if (/\/model\s+choose what model/i.test(line) && /\/permissions/i.test(line)) return false;
  if (/codex_a|xcodebui|xcodebuildmcp|context left/i.test(line) && line.length > 80) return false;
  return true;
}
