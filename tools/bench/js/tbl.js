const t = new Map();
for (let i = 0; i < 1000000; i++) t.set("k" + (i % 5000), i);
let n = 0;
for (let i = 0; i < 2000000; i++) n += t.get("k" + (i % 5000));
console.log(n);
