import { terminalScreenText, transcriptDisplayLines } from "../../agent/src/classifier.js";

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
