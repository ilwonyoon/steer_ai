// Decide whether a stdin chunk represents a "cancel" intent (Esc / Ctrl-C).
//
// Raw-mode stdin can deliver arrow keys and other navigation as multi-byte
// CSI/SS3 escape sequences whose first byte is 0x1B. Treating those as cancel
// makes navigation flicker run_state to waiting, so we explicitly carve them
// out. Everything else starting with ESC — bare Esc, double Esc, Esc+Enter —
// counts as a cancel intent.
export function isCancelChunk(chunk) {
  if (!chunk || chunk.length === 0) return false;
  const first = chunk[0];
  if (first === 0x03) return true;
  if (first !== 0x1B) return false;
  if (chunk.length === 1) return true;
  const second = chunk[1];
  if (second === 0x5B || second === 0x4F) return false;
  return true;
}
