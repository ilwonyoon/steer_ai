// Format an instruction text + attachment paths into a single string the
// underlying CLI (codex / claude) will see on stdin. The model is expected to
// follow the file references and read them. We use a marker line so the
// formatting is grep-able in transcripts.

const MARKER = "[attached image]";

export function formatInstructionWithAttachments(text, attachments) {
  const trimmedText = (text ?? "").replace(/\s+$/, "");
  const paths = (attachments ?? [])
    .map((value) => (typeof value === "string" ? value.trim() : ""))
    .filter((value) => value.length > 0);
  if (paths.length === 0) return trimmedText;

  const lines = paths.map((p) => `${MARKER} ${p}`);
  if (trimmedText.length === 0) return lines.join("\n");
  return `${trimmedText}\n\n${lines.join("\n")}`;
}

export const ATTACHMENT_MARKER = MARKER;
