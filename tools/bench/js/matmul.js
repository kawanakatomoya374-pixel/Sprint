function make(n) { const m = []; for (let i = 0; i < n; i++) { const r = []; for (let j = 0; j < n; j++) r.push((i * j) % 7 + 1); m.push(r); } return m; }
function mul(a, b, n) { const c = []; for (let i = 0; i < n; i++) { const row = []; for (let j = 0; j < n; j++) { let s = 0; for (let k = 0; k < n; k++) s = s + a[i][k] * b[k][j]; row.push(s); } c.push(row); } return c; }
const n = 200;
const c = mul(make(n), make(n), n);
console.log(c[10][10], c[199][199]);
