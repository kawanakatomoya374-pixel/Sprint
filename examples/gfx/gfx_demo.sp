# gfx demo: draws a small scene and writes PNG / PPM / BMP.
# run:  sprint run --allow-write=build examples/gfx_demo.sp
import gfx

let c = gfx.canvas(320, 200, gfx.rgb(24, 26, 40))
# sky gradient
for y in range(120):
    c.line(0, y, 319, y, gfx.rgb(24 + y // 3, 40 + y // 2, 90 + y))
# sun and ground
c.fill_circle(250, 50, 22, gfx.rgb(255, 214, 90))
c.fill_rect(0, 120, 320, 80, gfx.rgb(40, 110, 60))
# house
c.fill_rect(60, 80, 80, 60, gfx.rgb(200, 90, 70))
c.fill_triangle(50, 80, 100, 40, 150, 80, gfx.rgb(120, 50, 40))
c.fill_rect(88, 105, 24, 35, gfx.rgb(70, 40, 30))
c.rect(60, 80, 80, 60, gfx.rgb(255, 255, 255))
# rainbow
for i in range(6):
    c.circle(250, 160, 60 - i * 3, gfx.hsv(i * 60, 80, 100))
# translucent overlay
c.set_alpha(110)
c.fill_rect(10, 150, 140, 40, gfx.rgb(0, 0, 0))
c.set_alpha(255)
c.text(16, 156, "Hello, Sprint!", gfx.rgb(255, 255, 255), 2)
c.text(16, 176, f"{c.width()}x{c.height()} px", gfx.rgb(180, 220, 255))

c.save_png("build/gfx_demo.png")
c.save_ppm("build/gfx_demo.ppm")
c.save_bmp("build/gfx_demo.bmp")
print("wrote", c.width(), c.height())
