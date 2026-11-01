const a = [];
for (let i = 0; i < 3000000; i++) a.push(i * 2);
let t = 0;
for (let i = 0; i < a.length; i++) t += a[i];
for (const x of a) t += x;
console.log(t);
