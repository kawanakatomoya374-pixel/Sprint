function counter() { let n = 0; return function () { n = n + 1; return n; }; }
const f = counter();
let r = 0;
for (let i = 1; i <= 20000000; i++) r = f();
console.log(r);
