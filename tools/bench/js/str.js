const parts = [];
for (let i = 0; i < 500000; i++) parts.push("item" + i);
const s = parts.join(",");
let c = 0;
for (const w of s.split(",")) { if (w.slice(0, 5) === "item1") c++; }
console.log(s.length, c);
