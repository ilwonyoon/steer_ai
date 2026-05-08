export function classifyTranscript({ session, entries }) {
  const timing = transcriptTiming(entries);
  const cardEntries = selectActionSourceEntries(session, entries, timing.latestUserIndex);
  const rawText = cardEntries.map((entry) => entry.chunk).join("");
  const displayLines = transcriptDisplayLines(rawText);
  const card = classifyActionCard(session, displayLines, timing);

  return { rawText, displayLines, card };
}

function selectActionSourceEntries(session, entries, latestUserIndex) {
  const userCutoff = (latestUserIndex !== null && latestUserIndex !== undefined) ? latestUserIndex : -1;
  const candidates = entries
    .map((entry, index) => ({ entry, index }))
    .filter(({ entry, index }) => entry.stream !== "user" && index > userCutoff)
    .map(({ entry }) => entry);
  const reports = candidates.filter((entry) => entry.stream === "report");
  if (reports.length > 0) return reports;

  if (session.adapter_kind === "pty-bridge") {
    return candidates.filter((entry) => entry.stream !== "pty" && entry.stream !== "system");
  }

  return candidates.filter((entry) => entry.stream !== "system");
}

export function transcriptDisplayLines(rawText) {
  const splitLines = transcriptDisplayText(rawText)
    .replace(/\s+([⚠✖✔])\s*/g, "\n$1 ")
    .replace(/\s+([›>])\s+/g, "\n$1 ")
    .replace(/([^\n])›(?=\S)/g, "$1\n›")
    .replace(/\s*(\[(?:user|steer|codex|claude)\])/gi, "\n$1")
    .replace(/\s{2,}(gpt-[\w.-]+[^\n]*·[^\n]*)/g, "\n$1")
    .split("\n")
    .flatMap(splitTerminalDisplayLine);
  const normalizedLines = dedentDisplayLines(splitLines).map(normalizeTerminalDisplayLine);
  const lines = retainReadableDisplayLines(normalizedLines);

  return lines.length > 0 ? lines : ["[no transcript yet]"];
}

function transcriptDisplayText(rawText) {
  return shouldRenderAsTerminalScreen(rawText)
    ? terminalScreenText(rawText)
    : cleanTerminalText(rawText);
}

function shouldRenderAsTerminalScreen(rawText) {
  return /\x1B\[[0-?]*[ -/]*[HfGJK]/.test(rawText) || /\r(?!\n)/.test(rawText);
}

function dedentDisplayLines(lines) {
  const indents = lines
    .filter((line) => line.trim().length > 0)
    .map((line) => line.match(/^[ \t]*/)?.[0].length ?? 0)
    .filter((indent) => indent > 0);
  if (indents.length === 0) return lines;

  const commonIndent = Math.min(...indents);
  return lines.map((line) => line.startsWith(" ".repeat(commonIndent)) ? line.slice(commonIndent) : line);
}

function retainReadableDisplayLines(lines) {
  const retained = [];

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (isMeaningfulTerminalLine(line)) {
      retained.push(line);
      continue;
    }

    if (line.trim().length === 0 && retained.length > 0 && retained.at(-1) !== "" && hasLaterMeaningfulLine(lines, index + 1)) {
      retained.push("");
    }
  }

  while (retained.at(-1) === "") retained.pop();
  return retained;
}

function hasLaterMeaningfulLine(lines, startIndex) {
  for (let index = startIndex; index < lines.length; index += 1) {
    if (isMeaningfulTerminalLine(lines[index])) return true;
  }
  return false;
}

function transcriptTiming(entries) {
  let latestUserAt = null;
  let latestOutputAt = null;
  let latestUserIndex = null;
  let latestOutputIndex = null;

  for (const [index, entry] of entries.entries()) {
    if (entry.stream === "user") {
      latestUserAt = maxTimestamp(latestUserAt, entry.timestamp);
      latestUserIndex = index;
      continue;
    }

    if (["report", "stdout", "stderr"].includes(entry.stream) && transcriptDisplayLines(entry.chunk).some(isContentLineForAction)) {
      latestOutputAt = maxTimestamp(latestOutputAt, entry.timestamp);
      latestOutputIndex = index;
    }
  }

  return { latestUserAt, latestOutputAt, latestUserIndex, latestOutputIndex };
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
  const answered = timing.latestUserIndex !== null
    && timing.latestUserIndex !== undefined
    && (timing.latestOutputIndex === null || timing.latestOutputIndex === undefined || timing.latestUserIndex >= timing.latestOutputIndex);

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

  if (session.run_state === "disconnected") {
    return {
      category: "disconnected",
      priority: "silent",
      title: `${titlePrefix} disconnected`,
      summary,
      actionPrompt: "Start a new wrapped session to continue.",
      options: [],
      state: "done",
      highlightedLineIndexes: []
    };
  }

  if (session.run_state === "running") {
    return {
      category: "progress",
      priority: "silent",
      title: `${titlePrefix} is running`,
      summary,
      actionPrompt: "Waiting for the session to stop with an actionable response.",
      options: [],
      state: "done",
      highlightedLineIndexes: []
    };
  }

  if (session.run_state === "blocked" || hasAny(lower, [
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

  if (session.run_state === "waiting") {
    return {
      category: "waiting",
      priority: "normal",
      title: `${titlePrefix} is waiting`,
      summary,
      actionPrompt: "Send the next instruction so the session can continue.",
      options: ["Continue", "Summarize result", "Start next task"],
      state: "active",
      highlightedLineIndexes: highlightIndexes(displayLines, ["complete", "completed", "done", "success", "passed", "next"])
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

export function terminalScreenText(value, { rows = 60, cols = 240 } = {}) {
  const screen = Array.from({ length: rows }, () => Array(cols).fill(" "));
  let row = 0;
  let col = 0;
  let index = 0;

  const clampCursor = () => {
    row = Math.max(0, Math.min(rows - 1, row));
    col = Math.max(0, Math.min(cols - 1, col));
  };

  const putChar = (char) => {
    if (char === "\n") {
      row = Math.min(rows - 1, row + 1);
      return;
    }
    if (char === "\r") {
      col = 0;
      return;
    }
    if (char === "\b") {
      col = Math.max(0, col - 1);
      return;
    }
    const codePoint = char.codePointAt(0) ?? 0;
    if (codePoint < 32 || codePoint === 127) return;

    screen[row][col] = char;
    col += 1;
    if (col >= cols) {
      col = 0;
      row = Math.min(rows - 1, row + 1);
    }
  };

  while (index < value.length) {
    const char = value[index];

    if (char === "\x1B") {
      const consumed = consumeEscape(value, index, {
        moveCursor(nextRow, nextCol) {
          row = nextRow ?? row;
          col = nextCol ?? col;
          clampCursor();
        },
        eraseLine() {
          screen[row].fill(" ", col);
        },
        eraseDisplay() {
          for (let currentRow = row; currentRow < rows; currentRow += 1) {
            screen[currentRow].fill(" ", currentRow === row ? col : 0);
          }
        },
        reverseIndex() {
          row = Math.max(0, row - 1);
        }
      });
      if (consumed > 0) {
        index += consumed;
        continue;
      }
    }

    putChar(char);
    index += 1;
  }

  return screen
    .map((line) => line.join("").trimEnd())
    .filter((line) => line.trim().length > 0)
    .join("\n");
}

function consumeEscape(value, start, actions) {
  const next = value[start + 1];
  if (!next) return 1;

  if (next === "]") {
    const belIndex = value.indexOf("\x07", start + 2);
    const stIndex = value.indexOf("\x1B\\", start + 2);
    if (belIndex === -1 && stIndex === -1) return value.length - start;
    if (belIndex !== -1 && (stIndex === -1 || belIndex < stIndex)) return belIndex - start + 1;
    return stIndex - start + 2;
  }

  if (next === "P" || next === "X" || next === "^" || next === "_") {
    const stIndex = value.indexOf("\x1B\\", start + 2);
    return stIndex === -1 ? value.length - start : stIndex - start + 2;
  }

  if (next === "M") {
    actions.reverseIndex();
    return 2;
  }

  if (next !== "[") return 2;

  const match = /\x1B\[([0-?]*)([ -/]*)([@-~])/.exec(value.slice(start));
  if (!match || match.index !== 0) return 1;

  const [, params, _intermediate, command] = match;
  applyCsi(params, command, actions);
  return match[0].length;
}

function applyCsi(params, command, actions) {
  const normalizedParams = params.replace(/^\?/, "");
  const parts = normalizedParams
    .split(";")
    .filter(Boolean)
    .map((part) => Number.parseInt(part, 10));

  switch (command) {
    case "H":
    case "f": {
      const nextRow = Math.max((parts[0] || 1) - 1, 0);
      const nextCol = Math.max((parts[1] || 1) - 1, 0);
      actions.moveCursor(nextRow, nextCol);
      break;
    }
    case "G": {
      const nextCol = Math.max((parts[0] || 1) - 1, 0);
      actions.moveCursor(undefined, nextCol);
      break;
    }
    case "K":
      actions.eraseLine();
      break;
    case "J":
      actions.eraseDisplay();
      break;
    default:
      break;
  }
}

function splitTerminalDisplayLine(line) {
  return line
    .replace(/\s+(gpt-[\w.-]+[^\n]*·[^\n]*)/g, "\n$1")
    .split("\n");
}

function normalizeTerminalDisplayLine(line) {
  return line
    .replace(/\?•Work(?:ing)?\b.*$/i, "?")
    .replace(/\s+$/g, "");
}

function isMeaningfulTerminalLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return false;
  if (!/[A-Za-z0-9가-힣⚠✖✔›>]/.test(trimmed)) return false;
  if (!isContentLineForAction(trimmed)) return false;
  return true;
}

function isContentLineForAction(line) {
  const trimmed = line.trim();
  if (!trimmed) return false;
  if (/^(?:\[user\]|\[steer\])/.test(trimmed)) return false;
  if (/^›/.test(trimmed)) return false;
  if (/^gpt-[\w.-]+.*·/i.test(trimmed)) return false;
  if (/^[A-Za-z]{1,2}$/.test(trimmed)) return false;
  if (/^\]1[01];\?\\?$/.test(trimmed)) return false;
  if (/^Tip: Try the Codex App/i.test(trimmed)) return false;
  if (/^https:\/\/chatgpt\.com\/codex/i.test(trimmed)) return false;
  if (/Under-development features enabled/i.test(trimmed)) return false;
  if (/features are incomplete/i.test(trimmed)) return false;
  if (/suppress_unstable_features_warning/i.test(trimmed)) return false;
  if (/config\.toml/i.test(trimmed)) return false;
  if (/MCP client for `?pencil`? failed/i.test(trimmed)) return false;
  if (/MCP startup failed/i.test(trimmed)) return false;
  if (/No such file or direc/i.test(trimmed)) return false;
  if (/os error 2/i.test(trimmed)) return false;
  if (/MCP startup incomplete/i.test(trimmed)) return false;
  if (/esc to interr/i.test(trimmed)) return false;
  if (/esc again to edit previous message/i.test(trimmed)) return false;
  if (/tab to queue message/i.test(trimmed)) return false;
  if (/auto mode on/i.test(trimmed)) return false;
  if (/shift\+tab/i.test(trimmed)) return false;
  if (/esc to interrupt/i.test(trimmed)) return false;
  if (/tokens?\)/i.test(trimmed)) return false;
  if (/running stop hooks/i.test(trimmed)) return false;
  if (/Cultivating/i.test(trimmed)) return false;
  if (/Crunching/i.test(trimmed)) return false;
  if (/\*?Worked for \d+/i.test(trimmed)) return false;
  if (/\*?Baked for \d+/i.test(trimmed)) return false;
  if (/^\d+$/.test(trimmed)) return false;
  if (/Starting MCP servers/i.test(trimmed)) return false;
  if (/SStt|WWoorr|MMCC|rrvv|sseerr/i.test(trimmed)) return false;
  if (/(Working[•. ]*){2,}/i.test(trimmed)) return false;
  if (/^Wo•Wor/i.test(trimmed)) return false;
  if (/xcodebui.*xcodebuild.*•/i.test(trimmed)) return false;
  if (/\/model\s+choose what model/i.test(trimmed) && /\/permissions/i.test(trimmed)) return false;
  if (/codex_a|xcodebui|xcodebuildmcp|context left/i.test(trimmed) && trimmed.length > 80) return false;
  return true;
}
