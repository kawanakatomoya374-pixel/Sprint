const isDigit = (c) => c >= 48 && c <= 57;
const isAlpha = (c) => (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c === 95;
function tokenize(s) {
  const n = s.length;
  let i = 0, toks = 0, nums = 0, ids = 0, syms = 0;
  while (i < n) {
    const c = s.charCodeAt(i);
    if (c === 32 || c === 10) i++;
    else if (isDigit(c)) {
      let j = i;
      while (j < n && isDigit(s.charCodeAt(j))) j++;
      nums++; toks++; i = j;
    } else if (isAlpha(c)) {
      let j = i;
      while (j < n && (isAlpha(s.charCodeAt(j)) || isDigit(s.charCodeAt(j)))) j++;
      ids++; toks++; i = j;
    } else { syms++; toks++; i++; }
  }
  return [toks, nums, ids, syms];
}
const unit = "let x1 = foo(42, bar_baz) + 3 * (y - 17);\nif x1 >= 100 { print(x1) }\n";
const src = unit.repeat(20000);
let r;
for (let k = 1; k <= 5; k++) r = tokenize(src);
console.log(r.join(" "));
