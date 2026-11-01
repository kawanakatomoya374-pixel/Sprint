// the generator differs from the other languages' libraries (each has its own random); only the work is comparable
let seed = 7;
function rnd() { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % 1000001; }
const a = [];
for (let i = 0; i < 300000; i++) a.push(rnd());
a.sort((x, y) => x - y);
const b = [];
for (let i = 0; i < a.length; i++) { const x = a[i] * 2; if (x % 3 === 0) b.push(x); }
let s = 0;
for (let i = 0; i < b.length; i++) s += b[i];
a.sort((x, y) => y - x);
console.log(a[0], b.length, s);
