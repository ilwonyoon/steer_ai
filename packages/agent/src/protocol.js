export function encodeMessage(message) {
  return `${JSON.stringify(message)}\n`;
}

export function createLineDecoder(onMessage) {
  let buffer = "";

  return function decode(chunk) {
    buffer += chunk.toString("utf8");
    let newlineIndex = buffer.indexOf("\n");

    while (newlineIndex !== -1) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);

      if (line.length > 0) {
        onMessage(JSON.parse(line));
      }

      newlineIndex = buffer.indexOf("\n");
    }
  };
}
