const BRACKETED_PASTE_START = "\x1B[200~";
const BRACKETED_PASTE_END = "\x1B[201~";

export function formatPtyInstructionInput(provider, text) {
  const normalized = normalizeLineEndings(text);
  if (!normalized.includes("\n")) {
    return normalized;
  }

  if (supportsBracketedPaste(provider)) {
    return `${BRACKETED_PASTE_START}${normalized}${BRACKETED_PASTE_END}`;
  }

  return normalized;
}

function normalizeLineEndings(text) {
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function supportsBracketedPaste(provider) {
  return provider === "codex" || provider === "claude";
}
