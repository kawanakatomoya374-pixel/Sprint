function steps(n) { let c = 0; while (n !== 1) { if (n % 2 === 0) n = n / 2; else n = 3 * n + 1; c = c + 1; } return c; }
let best = 0;
for (let i = 1; i <= 599999; i++) { const s = steps(i); if (s > best) best = s; }
console.log(best);
