const words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu"];
const M = 2147483648;
// (seed * 1103515245 + 12345) % 2^31 without leaving the exactly-representable range: split the multiplier
function next(seed) {
  const hi = Math.floor(1103515245 / 65536), lo = 1103515245 % 65536;
  return (((seed * hi) % M) * 65536 + seed * lo + 12345) % M;
}
let seed = 12345;
const parts = [];
for (let i = 0; i < 200000; i++) {
  seed = next(seed);
  parts.push(words[Math.floor(seed / 65536) % 12] + String(seed % 50));
}
const text = parts.join(" ");
const counts = new Map();
for (let r = 0; r < 5; r++) {
  for (const w of text.split(" ")) counts.set(w, (counts.get(w) ?? 0) + 1);
}
const keys = [...counts.keys()];
keys.sort((a, b) => { if (counts.get(a) !== counts.get(b)) return counts.get(b) - counts.get(a); return a < b ? -1 : a > b ? 1 : 0; });
console.log(keys.length, keys[0], counts.get(keys[0]), keys[keys.length - 1], counts.get(keys[keys.length - 1]));
