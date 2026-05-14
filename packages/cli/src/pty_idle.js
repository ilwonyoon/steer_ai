import { terminalScreenText, transcriptDisplayLines } from "../../agent/src/classifier.js";

/// G16 — sniff the Claude/Codex TUI for an interactive modal
/// that's waiting on a Mac-side keyboard decision (AskUserQuestion,
/// permission prompt, slash-command picker). Returns the modal's
/// rendered text when one is on screen, null otherwise.
///
/// We can't see the modal through Stop/Notification hooks — Claude
/// treats it as "still running" and Codex doesn't expose a
/// JSON-RPC notification for it. The PTY is the only available
/// signal. The detection key is the modal's footer:
///
///   Enter to select · ↑/↓ to navigate · Esc to cancel
///
/// — a string the TUI always renders below the option list. When
/// it's present, the lines above it (up to the box header) are
/// the modal body.
///
/// We deliberately return the *full* modal text, including the
/// option list, so the iPhone card surfaces enough context for
/// the user to know what they have to go back to the Mac for.
/// We do NOT try to act on it — the caller's contract is "tell
/// the user a Mac action is required."
export function extractInteractiveModalReport(provider, rawText) {
  if (!rawText) return null;
  const screen = terminalScreenText(rawText, { rows: 80, cols: 240 });
  if (!screen) return null;

  // Modal footer fingerprints. Claude TUI uses the exact phrase
  // "Enter to select" with arrow-key navigation hints. Codex
  // permission prompts use "esc to cancel" only, no arrows
  // (they're a numbered list with a numeric input). We accept
  // either footer so both providers' modals surface.
  const footerPatterns = [
    /Enter to select.*(?:to navigate|to cancel)/i,
    /Enter to confirm.*(?:to cancel)/i,
    /Press \d+(?:-\d+)? to (?:approve|allow|select)/i,
    /^\s*\d+\.\s*Allow\b.*\n\s*\d+\.\s*(?:Cancel|Always|Deny)\b/m,
  ];
  const hasFooter = footerPatterns.some((re) => re.test(screen));
  if (!hasFooter) return null;

  // Extract just the readable lines so the card body isn't full
  // of cursor-positioning escapes.
  const lines = transcriptDisplayLines(rawText)
    .map((line) => line.replace(/^•\s*/, "").trim())
    .filter((line) => line.length > 0)
    .filter((line) => !/(?:^|\s)Press \?\s*for help/i.test(line))
    .filter((line) => !/^[─━│┃┌┐└┘├┤┬┴┼\s]+$/.test(line)); // box-drawing-only rows

  // Keep the last ~30 readable lines — the modal lives at the
  // bottom of the screen. Older lines (a previous turn's body)
  // would dilute the card.
  const tail = lines.slice(-30);
  if (tail.length === 0) return null;
  return tail.join("\n");
}

export function extractPtyIdleReport(provider, rawText) {
  if (!rawText) return null;

  const screen = terminalScreenText(rawText, { rows: 80, cols: 240 });
  if (!hasInputPrompt(provider, screen)) return null;

  const bulletReports = provider === "codex"
    ? extractCodexBulletReports(rawText).filter((line) => isPtyReportLine(provider, line))
    : [];
  if (bulletReports.length > 0) {
    const recent = bulletReports.slice(-12);
    return recent.join("\n");
  }

  const lines = transcriptDisplayLines(rawText)
    .map((line) => line.replace(/^•\s*/, "").trim())
    .filter((line) => isPtyReportLine(provider, line));
  if (lines.length === 0) return null;

  const startIndex = Math.max(0, lines.length - 60);
  const report = lines.slice(startIndex).join("\n").trim();
  return report.length > 0 ? report : null;
}

function extractCodexBulletReports(rawText) {
  const cleaned = cleanPtyText(rawText);
  const reports = [];
  const pattern = /•\s*([^•›\n\r]+)/g;
  let match;

  while ((match = pattern.exec(cleaned))) {
    const report = match[1]
      .replace(/[ \t]{2,}/g, " ")
      .trim();
    if (report) reports.push(report);
  }

  return reports;
}

function cleanPtyText(value) {
  return value
    .replace(/\x1B\][^\x07]*(?:\x07|\x1B\\)/g, "")
    .replace(/\x1B[PX^_][\s\S]*?\x1B\\/g, "")
    .replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\x1B[@-Z\\-_]/g, "")
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "");
}

function hasInputPrompt(provider, screen) {
  if (provider === "codex") {
    return /(?:^|\n)\s*›\s*(?:$|[^\n]*)/m.test(screen);
  }

  if (provider === "claude") {
    return /(?:^|\n)\s*[>›]\s*(?:$|[^\n]*)/m.test(screen) || /esc to interrupt/i.test(screen);
  }

  return false;
}

function isPtyReportLine(provider, line) {
  if (!line) return false;
  if (/OpenAI Codex/i.test(line)) return false;
  if (/^Tip: Try the Codex App/i.test(line)) return false;
  if (/Starting MCP servers/i.test(line)) return false;
  if (/^Working\b/i.test(line)) return false;
  if (/esc to interrupt/i.test(line)) return false;
  if (/MCP startup/i.test(line)) return false;
  if (/MCP client for/i.test(line)) return false;
  if (/Under-development features/i.test(line)) return false;
  if (/incomplete and may behave unpredictably/i.test(line)) return false;
  if (/suppress.*warning/i.test(line)) return false;
  if (/config\.toml/i.test(line)) return false;
  if (/^│?\s*model:/i.test(line)) return false;
  if (/^│?\s*directory:/i.test(line)) return false;
  if (/^│?\s*change\s*│?$/i.test(line)) return false;
  if (/^│?\s*visit$/i.test(line)) return false;
  if (/^│?\s*this warning/i.test(line)) return false;
  if (/^│?\s*and may behave unpredictably/i.test(line)) return false;
  if (/^│?\s*true`? in .*\.codex/i.test(line)) return false;
  if (/^\s*[>›]/.test(line)) return false;
  return true;
}
