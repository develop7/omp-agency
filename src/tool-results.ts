/** Operation identity and its opaque semantic result; null means no inline value. */
export type ToolDetails = { op: string; value: unknown };
const maxDetailsBytes = 32 * 1024;

/** The full value reaches the model; only small values are duplicated in history details. */
export function toolResult(op: string, result: { stdout: string; value: unknown }) {
  const json = result.value === null ? undefined : JSON.stringify(result.value, null, 2);
  const text = json === undefined ? result.stdout || "ok"
    : typeof result.value === "string" ? result.value : `\`\`\`json\n${json}\n\`\`\``;
  return {
    content: [{ type: "text" as const, text }],
    details: { op, value: json !== undefined && Buffer.byteLength(json) <= maxDetailsBytes ? result.value : null },
    ...(Array.isArray(result.value) && result.value.length === 0 ? { useless: true } : {}),
  };
}
