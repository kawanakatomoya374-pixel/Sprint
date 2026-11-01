class P {
  constructor(x, y) { this.x = x; this.y = y; }
  add(o) { return new P(this.x + o.x, this.y + o.y); }
  len2() { return this.x * this.x + this.y * this.y; }
}
let p = new P(0, 0); const d = new P(1, 2); let s = 0;
for (let i = 1; i <= 3000000; i++) { p = p.add(d); s = s + p.len2() % 3; }
console.log(s);
