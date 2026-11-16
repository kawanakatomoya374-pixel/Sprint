# Drives tests/x11/events.sp from the outside through the XTest extension and checks what reached the screen.
import ctypes, time
x = ctypes.CDLL("libX11.so.6"); t = ctypes.CDLL("libXtst.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p
x.XKeysymToKeycode.restype = ctypes.c_ubyte
x.XGetImage.restype = ctypes.c_void_p
x.XDefaultRootWindow.restype = ctypes.c_ulong
d = ctypes.c_void_p(x.XOpenDisplay(None))
def key(sym, down): t.XTestFakeKeyEvent(d, x.XKeysymToKeycode(d, sym), down, 0)
def tap(sym): key(sym, 1); key(sym, 0); x.XFlush(d)
def move(px, py): t.XTestFakeMotionEvent(d, 0, px, py, 0); x.XFlush(d); time.sleep(0.1)
def btn(b, down): t.XTestFakeButtonEvent(d, b, down, 0); x.XFlush(d); time.sleep(0.05)
def pixel(px, py):
    img = x.XGetImage(d, ctypes.c_ulong(x.XDefaultRootWindow(d)), px, py, 1, 1, ctypes.c_ulong(-1), 2)
    data = ctypes.c_void_p.from_address(img + 16).value   # XImage.data
    return "%02x%02x%02x" % tuple(ctypes.string_at(data, 4)[2::-1])
got = ""
for _ in range(60):                                       # wait until the window shows its first frame
    got = pixel(50, 50)
    if got == "ffcc00": break
    time.sleep(0.05)
print("pixel 50,50 =", got, " 200,150 =", pixel(200, 150))
move(50, 50); btn(1, 1); btn(1, 0); btn(1, 1); btn(1, 0)  # double click
btn(3, 1); btn(3, 0)                                       # right click
btn(5, 1); btn(5, 0); btn(4, 1); btn(4, 0)                 # wheel down, up
tap(ord('a')); time.sleep(0.05)
key(0xffe3, 1); tap(ord('c')); key(0xffe3, 0)              # Ctrl+c
tap(0xff0d); tap(0xff51); tap(0xff09); tap(0xffbe)         # Enter Left Tab F1
key(0xffe1, 1); tap(0xff09); key(0xffe1, 0)                # Shift+Tab
time.sleep(0.3)
