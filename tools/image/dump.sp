# decodes an image file with stdlib/image.sp and writes the width and height (4 bytes each, little endian) followed by the RGBA pixels.
# usage: sprint run --allow-read=DIR --allow-write=DIR tools/image/dump.sp IN OUT
import fs
import image
import sys
import typed
let im = image.decode(fs.read_bytes(sys.args[0]))
let out = typed.u8(8 + len(im.rgba))
for i in range(4):
    out[i] = (im.width >> (8 * i)) & 255
    out[4 + i] = (im.height >> (8 * i)) & 255
for i in range(len(im.rgba)):
    out[8 + i] = im.rgba[i]
fs.write_bytes(sys.args[1], out)
