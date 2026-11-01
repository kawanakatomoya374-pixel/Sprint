let s = "";
for (let i = 1; i <= 200000; i++) s += "x";
let n = 0;
for (let i = 0; i < s.length; i++) { if (s.charCodeAt(i) === 120) n++; }
const parts = [];
for (let i = 0; i < 300000; i++) parts.push(i + ":" + (i * 2));
console.log(n, parts.join(";").length);
