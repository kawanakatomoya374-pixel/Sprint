import gfx
# canvas methods, table members and string / mixed equality inside hot (compiled) functions
let THEME = {"bg": 0x203040, "fg": 0xe0e0e0, "radius": 3}
class Panel:
    let mode = "plain"
    func init(self, m):
        self.mode = m
    func draw(self, c, x, y, i):
        if self.mode == "round":
            c.fill_round_rect(x, y, 14, 10, THEME.radius, THEME.bg)
        elif self.mode != "plain":
            c.fill_rect(x, y, 14, 10, THEME.fg)
        else:
            c.rect(x, y, 14, 10, THEME.fg)
        if i % 7 == 0:
            c.set_alpha(120)
        else:
            c.set_alpha(255)
        c.text(x + 1, y + 1, "ab", THEME.fg)
        return c.get(x + 2, y + 2)
let c = gfx.canvas(96, 64, 0x101010)
let ps = [Panel("plain"), Panel("round"), Panel("x")]
let acc = 0
for i in range(3000):
    acc += ps[i % 3].draw(c, (i * 5) % 80, (i * 3) % 50, i) % 1000
    if i == 2000:
        ps[0].mode = "round"
print(acc, c.hash())
let s = "dead"
let n = 0
for i in range(2000):
    let v = "dead" if i % 3 == 0 else "live"
    if v == s:
        n += 1
    if v != "live":
        n += 2
    let q = v == s
    if q:
        n += 4
print(n)
