import gfx
let c = gfx.canvas(64, 48, 0x102030)
print(c.width(), c.height(), c.alpha(), c.get(3, 3) == 0x102030)
c.fill_rect(4, 4, 10, 8, 0xff0000)
c.rect(20, 4, 10, 8, 0x00ff00)
c.line(0, 47, 63, 0, 0x0000ff)
c.fill_circle(40, 30, 8, 0xffff00)
c.circle(40, 30, 12, 0xffffff)
c.fill_triangle(5, 40, 15, 20, 25, 40, 0xff00ff)
c.text(2, 14, "Az09 é", 0xffffff)
c.set_alpha(128)
c.fill_rect(0, 0, 64, 4, 0xffffff)
c.set_alpha(255)
print(c.get(5, 5), c.get(25, 4), c.get(0, 0), c.get(63, 0), c.get(40, 30))
let sum = 0
for y in range(48):
    for x in range(64):
        sum = (sum * 31 + c.get(x, y)) % 1000000007
print(sum)
print(c.text_width("abc"), c.text_width("abc", 2), c.text_width(""))
print(gfx.rgb(1, 2, 3), gfx.hsv(0, 100, 100), gfx.hsv(120, 100, 100), gfx.hsv(240, 100, 100), gfx.hsv(-120, 0, 50))
let d = gfx.canvas(4, 4)
d.pixel(1, 1, 0xabcdef)
c.blit(d, 60, 44)
print(c.get(61, 45) == 0xabcdef, c.get(63, 47) == 0)
c.save_png("build/test_gfx.png")
c.save_ppm("build/test_gfx.ppm")
c.save_bmp("build/test_gfx.bmp")
for bad in [func(): c.pixel(1, 1, -1), func(): c.pixel(1.5, 1, 0), func(): c.get(64, 0), func(): gfx.canvas(0, 5), func(): c.set_alpha(256), func(): c.nope(), func(): gfx.rgb(1, 2, 300)]:
    try:
        bad()
    catch e:
        print(e.kind, e.message)
try:
    c.save_png("/nonexistent_dir_zz/x.png")
catch e:
    print(e.kind)
