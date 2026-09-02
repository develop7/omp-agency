export function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function bundleDir() {
  return import.meta.dirname ?? new URL(".", import.meta.url).pathname;
}
