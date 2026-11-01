const t = new Map();
for (let i = 0; i < 200000; i++) t.set("key" + i, i);
let s = 0;
for (let r = 1; r <= 10; r++) {
  for (const [k, v] of t) s += v;
  for (const k of t.keys()) s += k.length;
}
console.log(s);
