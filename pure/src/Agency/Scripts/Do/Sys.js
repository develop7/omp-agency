function canonicalIso(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function nowIso() {
  return canonicalIso(new Date());
}

export function formatEpochIso(epoch) {
  return canonicalIso(new Date(epoch * 1000));
}

export function bundleDir() {
  return import.meta.dirname ?? new URL(".", import.meta.url).pathname;
}

let tempSequence = 0;

export function uniqueTempPath(path) {
  return function () {
    tempSequence += 1;
    return `${path}.tmp.${process.pid}.${tempSequence}`;
  };
}

export function isCanonicalIso(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return false;
  const date = new Date(value);
  return !Number.isNaN(date.valueOf()) && date.toISOString().replace(/\.\d{3}Z$/, "Z") === value;
}
