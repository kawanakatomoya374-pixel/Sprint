let n = 0; const parts = [];
for (let i = 0; i < 200000; i++) {
  const s = `item-${i}-${i * 2}`;
  n += s.length;
  if (s.includes("99")) parts.push(s.toUpperCase());
  const u = s.replace("item", "x").slice(0, 3);
  n += u.length;
}
console.log(n, parts.length);
