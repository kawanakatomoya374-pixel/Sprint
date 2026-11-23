# image: BMP, PNG and JPEG decoders written in Sprint.
#
#   import image
#   let im = image.decode(bytes)      # bytes: a string, an array of ints 0..255 or a typed.u8 (for example from fs.read_bytes)
#   im.width, im.height               # pixels
#   im.rgba                           # typed.u8, width * height * 4 bytes, row by row from the top: R, G, B, A
#   image.format(bytes)               # "bmp" | "png" | "jpeg" | nil
#
# BMP: 1 / 4 / 8 bits with a palette (RLE4 / RLE8 too), 16 (555 or bit fields), 24, 32 bits (bit fields), top-down or bottom-up.
# PNG: every colour type and bit depth (1 / 2 / 4 / 8 / 16), tRNS, Adam7 interlacing; zlib (inflate) is built in.
# JPEG: baseline, extended sequential and progressive Huffman JPEG (8 bit), any sampling, restart intervals, gray / YCbCr / RGB / Adobe
#       CMYK and YCCK. The inverse DCT, the "fancy" chroma upsampling and the colour conversion follow libjpeg (jidctint.c, jdsample.c,
#       jdcolor.c), so the pixels equal what libjpeg(-turbo) produces.
import typed

func fail(msg):
    throw error("ValueError", msg)

export func format(d):
    if len(d) >= 8 and d[0] == 0x89 and d[1] == 0x50 and d[2] == 0x4e and d[3] == 0x47:
        return "png"
    if len(d) >= 3 and d[0] == 0xff and d[1] == 0xd8 and d[2] == 0xff:
        return "jpeg"
    if len(d) >= 14 and d[0] == 0x42 and d[1] == 0x4d:
        return "bmp"
    return nil

export func decode(d):
    let f = format(d)
    if f == "png":
        return decode_png(d)
    if f == "jpeg":
        return decode_jpeg(d)
    if f == "bmp":
        return decode_bmp(d)
    fail("unrecognized image format")

func u16le(d, o):
    return d[o] | (d[o + 1] << 8)

func u32le(d, o):
    return d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)

func s32le(d, o):
    let v = u32le(d, o)
    return v - (1 << 32) if v >= (1 << 31) else v

func u32be(d, o):
    return (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]

func clamp8(v):
    if v < 0:
        return 0
    if v > 255:
        return 255
    return v

# ====================================================================================================================
# inflate (RFC 1950 / 1951)
# ====================================================================================================================
const LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
const CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

# a canonical Huffman code from the code lengths: {count[len], symbol[]}  (puff.c)
func huff_build(lengths, n):
    let count = []
    for i in range(16):
        count.append(0)
    for i in range(n):
        count[lengths[i]] += 1
    let offs = [0, 0]
    for l in range(1, 15):
        offs.append(offs[l] + count[l])
    let symbol = []
    for i in range(n):
        symbol.append(0)
    for i in range(n):
        if lengths[i] != 0:
            symbol[offs[lengths[i]]] = i
            offs[lengths[i]] += 1
    return {count: count, symbol: symbol}

let FIXED_LIT = nil
let FIXED_DIST = nil

# the decompressed data of a zlib stream (or a raw deflate stream) starting at `start`, as a typed.u8
export func inflate(src, start, zlib):
    let pos = start
    if zlib:
        pos += 2                          # CMF, FLG (no preset dictionary support needed for PNG)
    let buf = 0
    let cnt = 0
    let cap = 1 << 16
    let out = typed.u8(cap)
    let on = 0
    let end = len(src)
    func bits(n):
        while cnt < n:
            if pos >= end:
                fail("inflate: unexpected end of data")
            buf = buf | (src[pos] << cnt)
            pos += 1
            cnt += 8
        let v = buf & ((1 << n) - 1)
        buf = buf >> n
        cnt -= n
        return v
    func decode(h):
        let code = 0
        let first = 0
        let index = 0
        let count = h.count
        for l in range(1, 16):
            if cnt == 0:
                if pos >= end:
                    fail("inflate: unexpected end of data")
                buf = src[pos]
                pos += 1
                cnt = 8
            code = code | (buf & 1)
            buf = buf >> 1
            cnt -= 1
            let c = count[l]
            if code - c < first:
                return h.symbol[index + (code - first)]
            index += c
            first += c
            first = first << 1
            code = code << 1
        fail("inflate: bad Huffman code")
    func grow(need):
        while on + need > cap:
            cap = cap * 2
        let bigger = typed.u8(cap)
        for i in range(on):
            bigger[i] = out[i]
        out = bigger
    func codes(lit, dist):
        while true:
            let sym = decode(lit)
            if sym < 256:
                if on >= cap:
                    grow(1)
                out[on] = sym
                on += 1
            elif sym == 256:
                return nil
            else:
                sym -= 257
                if sym >= 29:
                    fail("inflate: bad length symbol")
                let length = LEN_BASE[sym] + bits(LEN_EXTRA[sym])
                let ds = decode(dist)
                if ds >= 30:
                    fail("inflate: bad distance symbol")
                let distance = DIST_BASE[ds] + bits(DIST_EXTRA[ds])
                if distance > on:
                    fail("inflate: distance too far back")
                if on + length > cap:
                    grow(length)
                for i in range(length):
                    out[on] = out[on - distance]
                    on += 1
    if FIXED_LIT == nil:
        let l = []
        for i in range(288):
            l.append(8 if i < 144 else (9 if i < 256 else (7 if i < 280 else 8)))
        FIXED_LIT = huff_build(l, 288)
        let dl = []
        for i in range(30):
            dl.append(5)
        FIXED_DIST = huff_build(dl, 30)
    let last = 0
    while last == 0:
        last = bits(1)
        let kind = bits(2)
        if kind == 0:
            buf = 0
            cnt = 0
            let n = src[pos] | (src[pos + 1] << 8)
            pos += 4
            if on + n > cap:
                grow(n)
            for i in range(n):
                out[on] = src[pos + i]
                on += 1
            pos += n
        elif kind == 1:
            codes(FIXED_LIT, FIXED_DIST)
        elif kind == 2:
            let nlen = bits(5) + 257
            let ndist = bits(5) + 1
            let ncode = bits(4) + 4
            let lengths = []
            for i in range(19):
                lengths.append(0)
            for i in range(ncode):
                lengths[CL_ORDER[i]] = bits(3)
            let clh = huff_build(lengths, 19)
            let ll = []
            while len(ll) < nlen + ndist:
                let sym = decode(clh)
                if sym < 16:
                    ll.append(sym)
                else:
                    let prev = 0
                    let rep = 0
                    if sym == 16:
                        if len(ll) == 0:
                            fail("inflate: bad repeat")
                        prev = ll[len(ll) - 1]
                        rep = 3 + bits(2)
                    elif sym == 17:
                        rep = 3 + bits(3)
                    else:
                        rep = 11 + bits(7)
                    for i in range(rep):
                        ll.append(prev)
            let l1 = []
            for i in range(nlen):
                l1.append(ll[i])
            let l2 = []
            for i in range(ndist):
                l2.append(ll[nlen + i])
            codes(huff_build(l1, nlen), huff_build(l2, ndist))
        else:
            fail("inflate: bad block type")
    let res = typed.u8(on)
    for i in range(on):
        res[i] = out[i]
    return res

# ====================================================================================================================
# PNG
# ====================================================================================================================
func paeth(a, b, c):
    let p = a + b - c
    let pa = p - a
    if pa < 0:
        pa = -pa
    let pb = p - b
    if pb < 0:
        pb = -pb
    let pc = p - c
    if pc < 0:
        pc = -pc
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c

# undo the scanline filters of one (sub)image in place: `raw` holds `h` rows of (1 + rowbytes) bytes at `off`; returns the offset after it
func png_unfilter(raw, off, h, rowbytes, bpp):
    let prev = -1                          # start offset of the previous unfiltered row (data after its filter byte)
    for y in range(h):
        let ft = raw[off]
        let row = off + 1
        if ft == 1:
            for i in range(bpp, rowbytes):
                raw[row + i] = (raw[row + i] + raw[row + i - bpp]) & 255
        elif ft == 2:
            if prev >= 0:
                for i in range(rowbytes):
                    raw[row + i] = (raw[row + i] + raw[prev + i]) & 255
        elif ft == 3:
            for i in range(rowbytes):
                let a = raw[row + i - bpp] if i >= bpp else 0
                let b = raw[prev + i] if prev >= 0 else 0
                raw[row + i] = (raw[row + i] + ((a + b) >> 1)) & 255
        elif ft == 4:
            for i in range(rowbytes):
                let a = raw[row + i - bpp] if i >= bpp else 0
                let b = raw[prev + i] if prev >= 0 else 0
                let c = raw[prev + i - bpp] if (prev >= 0 and i >= bpp) else 0
                raw[row + i] = (raw[row + i] + paeth(a, b, c)) & 255
        elif ft != 0:
            fail("png: bad filter type " .. to_string(ft))
        prev = row
        off += 1 + rowbytes
    return off

func decode_png(d):
    let pos = 8
    let w = 0
    let h = 0
    let depth = 0
    let ctype = 0
    let interlace = 0
    let palette = []
    let trns = []
    let idat = []
    let n = len(d)
    while pos + 8 <= n:
        let clen = u32be(d, pos)
        let tag = (d[pos + 4] << 24) | (d[pos + 5] << 16) | (d[pos + 6] << 8) | d[pos + 7]
        let body = pos + 8
        if tag == 0x49484452:                       # IHDR
            w = u32be(d, body)
            h = u32be(d, body + 4)
            depth = d[body + 8]
            ctype = d[body + 9]
            interlace = d[body + 12]
        elif tag == 0x504c5445:                     # PLTE
            for i in range(clen // 3):
                palette.append([d[body + 3 * i], d[body + 3 * i + 1], d[body + 3 * i + 2]])
        elif tag == 0x74524e53:                     # tRNS
            for i in range(clen):
                trns.append(d[body + i])
        elif tag == 0x49444154:                     # IDAT
            idat.append([body, clen])
        elif tag == 0x49454e44:
            break
        pos = body + clen + 4
    if w == 0 or h == 0:
        fail("png: no IHDR")
    # concatenate the IDAT data
    let total = 0
    for c in idat:
        total += c[1]
    let z = typed.u8(total)
    let at = 0
    for c in idat:
        for i in range(c[1]):
            z[at + i] = d[c[0] + i]
        at += c[1]
    let raw = inflate(z, 0, true)
    let channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    let bits_pp = channels * depth
    let bpp = (bits_pp + 7) // 8
    let rgba = typed.u8(w * h * 4)
    let maxv = (1 << depth) - 1
    # a sample reader over the unfiltered rows
    func put_row(rowoff, y, x0, dx, count):
        # row data at raw[rowoff ...]; pixels x0, x0 + dx, ... of line y
        for i in range(count):
            let x = x0 + i * dx
            let o = (y * w + x) * 4
            let r = 0
            let g = 0
            let b = 0
            let a = 255
            if depth == 8:
                let p = rowoff + i * channels
                if ctype == 6:
                    r = raw[p]
                    g = raw[p + 1]
                    b = raw[p + 2]
                    a = raw[p + 3]
                elif ctype == 2:
                    r = raw[p]
                    g = raw[p + 1]
                    b = raw[p + 2]
                    if len(trns) >= 6 and r == trns[1] and g == trns[3] and b == trns[5]:
                        a = 0
                elif ctype == 0:
                    r = raw[p]
                    g = r
                    b = r
                    if len(trns) >= 2 and r == trns[1]:
                        a = 0
                elif ctype == 4:
                    r = raw[p]
                    g = r
                    b = r
                    a = raw[p + 1]
                else:
                    let e = raw[p]
                    if e >= len(palette):
                        fail("png: palette index out of range")
                    r = palette[e][0]
                    g = palette[e][1]
                    b = palette[e][2]
                    if e < len(trns):
                        a = trns[e]
            elif depth == 16:
                let p = rowoff + i * channels * 2
                if ctype == 6:
                    r = raw[p]
                    g = raw[p + 2]
                    b = raw[p + 4]
                    a = raw[p + 6]
                elif ctype == 2:
                    r = raw[p]
                    g = raw[p + 2]
                    b = raw[p + 4]
                    if len(trns) >= 6 and ((raw[p] << 8) | raw[p + 1]) == ((trns[0] << 8) | trns[1]) and ((raw[p + 2] << 8) | raw[p + 3]) == ((trns[2] << 8) | trns[3]) and ((raw[p + 4] << 8) | raw[p + 5]) == ((trns[4] << 8) | trns[5]):
                        a = 0
                elif ctype == 0:
                    r = raw[p]
                    g = r
                    b = r
                    if len(trns) >= 2 and ((raw[p] << 8) | raw[p + 1]) == ((trns[0] << 8) | trns[1]):
                        a = 0
                else:
                    r = raw[p]
                    g = r
                    b = r
                    a = raw[p + 2]
            else:
                # 1, 2 or 4 bits per sample: one channel (gray or palette index)
                let bit = i * depth
                let v = (raw[rowoff + (bit >> 3)] >> (8 - depth - (bit & 7))) & maxv
                if ctype == 3:
                    if v >= len(palette):
                        fail("png: palette index out of range")
                    r = palette[v][0]
                    g = palette[v][1]
                    b = palette[v][2]
                    if v < len(trns):
                        a = trns[v]
                else:
                    r = v * 255 // maxv
                    g = r
                    b = r
                    if len(trns) >= 2 and v == ((trns[0] << 8) | trns[1]):
                        a = 0
            rgba[o] = r
            rgba[o + 1] = g
            rgba[o + 2] = b
            rgba[o + 3] = a
    if interlace == 0:
        let rowbytes = (w * bits_pp + 7) // 8
        if len(raw) < h * (rowbytes + 1):
            fail("png: not enough image data")
        png_unfilter(raw, 0, h, rowbytes, bpp)
        for y in range(h):
            put_row(y * (rowbytes + 1) + 1, y, 0, 1, w)
    else:
        # Adam7: seven passes
        let xs = [0, 4, 0, 2, 0, 1, 0]
        let ys = [0, 0, 4, 0, 2, 0, 1]
        let dxs = [8, 8, 4, 4, 2, 2, 1]
        let dys = [8, 8, 8, 4, 4, 2, 2]
        let off = 0
        for p in range(7):
            let pw = (w - xs[p] + dxs[p] - 1) // dxs[p]
            let ph = (h - ys[p] + dys[p] - 1) // dys[p]
            if pw <= 0 or ph <= 0:
                continue
            let rowbytes = (pw * bits_pp + 7) // 8
            let start = off
            off = png_unfilter(raw, off, ph, rowbytes, bpp)
            for r in range(ph):
                put_row(start + r * (rowbytes + 1) + 1, ys[p] + r * dys[p], xs[p], dxs[p], pw)
    return {width: w, height: h, rgba: rgba}

# ====================================================================================================================
# BMP
# ====================================================================================================================
func mask_shift(m):
    let s = 0
    while s < 32 and ((m >> s) & 1) == 0:
        s += 1
    let n = 0
    while s + n < 32 and ((m >> (s + n)) & 1) == 1:
        n += 1
    return [s, n]

func scale_to_8(v, bits):
    if bits == 0:
        return 255
    if bits >= 8:
        return v >> (bits - 8)
    return v * 255 // ((1 << bits) - 1)

func decode_bmp(d):
    let off = u32le(d, 10)
    let hs = u32le(d, 14)
    let w = 0
    let h = 0
    let planes = 1
    let bpp = 0
    let comp = 0
    let ncolors = 0
    if hs == 12:
        w = u16le(d, 18)
        h = u16le(d, 20)
        bpp = u16le(d, 24)
    else:
        w = s32le(d, 18)
        h = s32le(d, 22)
        bpp = u16le(d, 28)
        comp = u32le(d, 30)
        ncolors = u32le(d, 46)
    let top_down = false
    if h < 0:
        h = -h
        top_down = true
    if w <= 0 or h == 0:
        fail("bmp: bad size")
    # bit masks (BI_BITFIELDS = 3, BI_ALPHABITFIELDS = 6, or implied by the depth)
    let masks = [0, 0, 0, 0]
    let mpos = 14 + hs
    if comp == 3 or comp == 6:
        if hs >= 52:
            masks = [u32le(d, 54), u32le(d, 58), u32le(d, 62), u32le(d, 66) if hs >= 56 else 0]
        else:
            masks = [u32le(d, mpos), u32le(d, mpos + 4), u32le(d, mpos + 8), u32le(d, mpos + 12) if comp == 6 else 0]
            mpos += 12 + (4 if comp == 6 else 0)
    elif bpp == 16:
        masks = [0x7c00, 0x03e0, 0x001f, 0]
    elif bpp == 32:
        masks = [0x00ff0000, 0x0000ff00, 0x000000ff, 0]
    # the palette
    let palette = []
    if bpp <= 8:
        let entries = ncolors if ncolors > 0 else (1 << bpp)
        let psize = 3 if hs == 12 else 4
        let pp = 14 + hs
        for i in range(entries):
            if pp + psize * i + 2 < len(d):
                palette.append([d[pp + psize * i + 2], d[pp + psize * i + 1], d[pp + psize * i]])
    let rgba = typed.u8(w * h * 4)
    func set_px(x, y, r, g, b, a):
        let yy = y if top_down else h - 1 - y
        let o = (yy * w + x) * 4
        rgba[o] = r
        rgba[o + 1] = g
        rgba[o + 2] = b
        rgba[o + 3] = a
    if comp == 1 or comp == 2:            # RLE8 / RLE4
        let x = 0
        let y = 0
        let p = off
        for i in range(w * h * 4):
            rgba[i] = 0
        func put_index(idx):
            if x < w and y < h:
                let c = palette[idx] if idx < len(palette) else [0, 0, 0]
                set_px(x, y, c[0], c[1], c[2], 255)
            x += 1
        while p + 1 < len(d):
            let count = d[p]
            let val = d[p + 1]
            p += 2
            if count > 0:
                for i in range(count):
                    if comp == 1:
                        put_index(val)
                    else:
                        put_index((val >> 4) if (i & 1) == 0 else (val & 15))
            elif val == 0:
                x = 0
                y += 1
            elif val == 1:
                break
            elif val == 2:
                x += d[p]
                y += d[p + 1]
                p += 2
            else:
                for i in range(val):
                    if comp == 1:
                        put_index(d[p + i])
                    else:
                        let b = d[p + (i >> 1)]
                        put_index((b >> 4) if (i & 1) == 0 else (b & 15))
                let nbytes = val if comp == 1 else (val + 1) // 2
                p += nbytes + (nbytes & 1)
        return {width: w, height: h, rgba: rgba}
    let stride = ((w * bpp + 31) // 32) * 4
    if off + stride * h > len(d):
        fail("bmp: truncated pixel data")
    let sh = []
    for m in masks:
        sh.append(mask_shift(m) if m != 0 else [0, 0])
    for y in range(h):
        let row = off + y * stride
        for x in range(w):
            if bpp <= 8:
                let bit = x * bpp
                let v = (d[row + (bit >> 3)] >> (8 - bpp - (bit & 7))) & ((1 << bpp) - 1)
                let c = palette[v] if v < len(palette) else [0, 0, 0]
                set_px(x, y, c[0], c[1], c[2], 255)
            elif bpp == 24:
                let p = row + x * 3
                set_px(x, y, d[p + 2], d[p + 1], d[p], 255)
            else:
                let p = row + x * (bpp // 8)
                let v = u32le(d, p) if bpp == 32 else u16le(d, p)
                let r = scale_to_8((v & masks[0]) >> sh[0][0], sh[0][1])
                let g = scale_to_8((v & masks[1]) >> sh[1][0], sh[1][1])
                let b = scale_to_8((v & masks[2]) >> sh[2][0], sh[2][1])
                let a = 255
                if masks[3] != 0:
                    a = scale_to_8((v & masks[3]) >> sh[3][0], sh[3][1])
                set_px(x, y, r, g, b, a)
    return {width: w, height: h, rgba: rgba}

# ====================================================================================================================
# JPEG
# ====================================================================================================================
const ZZ = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
            35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

# a JPEG Huffman table: code lengths counts[1..16] and the symbols in code order -> decoding tables (spec F.2.2.3)
func jhuff_build(counts, symbols):
    let mincode = []
    let maxcode = []
    let valptr = []
    for i in range(18):
        mincode.append(0)
        maxcode.append(-1)
        valptr.append(0)
    let code = 0
    let k = 0
    for l in range(1, 17):
        valptr[l] = k
        mincode[l] = code
        code += counts[l]
        k += counts[l]
        maxcode[l] = code - 1 if counts[l] > 0 else -1
        code = code << 1
    return {mincode: mincode, maxcode: maxcode, valptr: valptr, symbols: symbols}

const FIX_0_298631336 = 2446
const FIX_0_390180644 = 3196
const FIX_0_541196100 = 4433
const FIX_0_765366865 = 6270
const FIX_0_899976223 = 7373
const FIX_1_175875602 = 9633
const FIX_1_501321110 = 12299
const FIX_1_847759065 = 15137
const FIX_1_961570560 = 16069
const FIX_2_053119869 = 16819
const FIX_2_562915447 = 20995
const FIX_3_072711026 = 25172

# libjpeg's jpeg_idct_islow: coefficients of one block (natural order, at `co`) times the quantisation table -> 8x8 samples into `plane`
func idct_block(coef, co, qt, plane, po, stride, ws):
    for c in range(8):
        if coef[co + c + 8] == 0 and coef[co + c + 16] == 0 and coef[co + c + 24] == 0 and coef[co + c + 32] == 0 and coef[co + c + 40] == 0 and coef[co + c + 48] == 0 and coef[co + c + 56] == 0:
            let dc = (coef[co + c] * qt[c]) << 2
            for r in range(8):
                ws[c + 8 * r] = dc
            continue
        let z2 = coef[co + c + 16] * qt[c + 16]
        let z3 = coef[co + c + 48] * qt[c + 48]
        let z1 = (z2 + z3) * FIX_0_541196100
        let tmp2 = z1 + z3 * (-FIX_1_847759065)
        let tmp3 = z1 + z2 * FIX_0_765366865
        z2 = coef[co + c] * qt[c]
        z3 = coef[co + c + 32] * qt[c + 32]
        let tmp0 = (z2 + z3) << 13
        let tmp1 = (z2 - z3) << 13
        let tmp10 = tmp0 + tmp3
        let tmp13 = tmp0 - tmp3
        let tmp11 = tmp1 + tmp2
        let tmp12 = tmp1 - tmp2
        tmp0 = coef[co + c + 56] * qt[c + 56]
        tmp1 = coef[co + c + 40] * qt[c + 40]
        tmp2 = coef[co + c + 24] * qt[c + 24]
        tmp3 = coef[co + c + 8] * qt[c + 8]
        z1 = tmp0 + tmp3
        z2 = tmp1 + tmp2
        z3 = tmp0 + tmp2
        let z4 = tmp1 + tmp3
        let z5 = (z3 + z4) * FIX_1_175875602
        tmp0 = tmp0 * FIX_0_298631336
        tmp1 = tmp1 * FIX_2_053119869
        tmp2 = tmp2 * FIX_3_072711026
        tmp3 = tmp3 * FIX_1_501321110
        z1 = z1 * (-FIX_0_899976223)
        z2 = z2 * (-FIX_2_562915447)
        z3 = z3 * (-FIX_1_961570560)
        z4 = z4 * (-FIX_0_390180644)
        z3 += z5
        z4 += z5
        tmp0 += z1 + z3
        tmp1 += z2 + z4
        tmp2 += z2 + z3
        tmp3 += z1 + z4
        ws[c] = (tmp10 + tmp3 + 1024) >> 11
        ws[c + 56] = (tmp10 - tmp3 + 1024) >> 11
        ws[c + 8] = (tmp11 + tmp2 + 1024) >> 11
        ws[c + 48] = (tmp11 - tmp2 + 1024) >> 11
        ws[c + 16] = (tmp12 + tmp1 + 1024) >> 11
        ws[c + 40] = (tmp12 - tmp1 + 1024) >> 11
        ws[c + 24] = (tmp13 + tmp0 + 1024) >> 11
        ws[c + 32] = (tmp13 - tmp0 + 1024) >> 11
    for r in range(8):
        let w = 8 * r
        let o = po + r * stride
        let z2 = ws[w + 2]
        let z3 = ws[w + 6]
        let z1 = (z2 + z3) * FIX_0_541196100
        let tmp2 = z1 + z3 * (-FIX_1_847759065)
        let tmp3 = z1 + z2 * FIX_0_765366865
        let tmp0 = (ws[w] + ws[w + 4]) << 13
        let tmp1 = (ws[w] - ws[w + 4]) << 13
        let tmp10 = tmp0 + tmp3
        let tmp13 = tmp0 - tmp3
        let tmp11 = tmp1 + tmp2
        let tmp12 = tmp1 - tmp2
        tmp0 = ws[w + 7]
        tmp1 = ws[w + 5]
        tmp2 = ws[w + 3]
        tmp3 = ws[w + 1]
        z1 = tmp0 + tmp3
        z2 = tmp1 + tmp2
        z3 = tmp0 + tmp2
        let z4 = tmp1 + tmp3
        let z5 = (z3 + z4) * FIX_1_175875602
        tmp0 = tmp0 * FIX_0_298631336
        tmp1 = tmp1 * FIX_2_053119869
        tmp2 = tmp2 * FIX_3_072711026
        tmp3 = tmp3 * FIX_1_501321110
        z1 = z1 * (-FIX_0_899976223)
        z2 = z2 * (-FIX_2_562915447)
        z3 = z3 * (-FIX_1_961570560)
        z4 = z4 * (-FIX_0_390180644)
        z3 += z5
        z4 += z5
        tmp0 += z1 + z3
        tmp1 += z2 + z4
        tmp2 += z2 + z3
        tmp3 += z1 + z4
        plane[o] = clamp8(((tmp10 + tmp3 + 131072) >> 18) + 128)
        plane[o + 7] = clamp8(((tmp10 - tmp3 + 131072) >> 18) + 128)
        plane[o + 1] = clamp8(((tmp11 + tmp2 + 131072) >> 18) + 128)
        plane[o + 6] = clamp8(((tmp11 - tmp2 + 131072) >> 18) + 128)
        plane[o + 2] = clamp8(((tmp12 + tmp1 + 131072) >> 18) + 128)
        plane[o + 5] = clamp8(((tmp12 - tmp1 + 131072) >> 18) + 128)
        plane[o + 3] = clamp8(((tmp13 + tmp0 + 131072) >> 18) + 128)
        plane[o + 4] = clamp8(((tmp13 - tmp0 + 131072) >> 18) + 128)

func decode_jpeg(d):
    let n = len(d)
    let pos = 2
    let qts = [nil, nil, nil, nil]
    let dcs = [nil, nil, nil, nil]
    let acs = [nil, nil, nil, nil]
    let comps = []
    let width = 0
    let height = 0
    let progressive = false
    let restart = 0
    let adobe = -1
    let jfif = false
    let hmax = 1
    let vmax = 1
    let mcux = 0
    let mcuy = 0
    let seen_sof = false
    # entropy-coded segment reader
    let bitbuf = 0
    let bitcnt = 0
    let eobrun = 0
    let hit_marker = false
    func rd_reset():
        bitbuf = 0
        bitcnt = 0
        hit_marker = false
    func fill():
        # read one more byte into the bit buffer (zeros once a marker was reached)
        let b = 0
        if not hit_marker and pos < n:
            b = d[pos]
            if b == 0xff:
                let b2 = d[pos + 1] if pos + 1 < n else 0xd9
                if b2 == 0:
                    pos += 2
                else:
                    hit_marker = true
                    b = 0
            else:
                pos += 1
        bitbuf = (bitbuf << 8) | b
        bitcnt += 8
    func getbits(k):
        if k == 0:
            return 0
        while bitcnt < k:
            fill()
        let v = (bitbuf >> (bitcnt - k)) & ((1 << k) - 1)
        bitcnt -= k
        bitbuf = bitbuf & ((1 << bitcnt) - 1)
        return v
    func getbit():
        if bitcnt == 0:
            fill()
        bitcnt -= 1
        let v = (bitbuf >> bitcnt) & 1
        bitbuf = bitbuf & ((1 << bitcnt) - 1)
        return v
    func hdecode(h):
        let code = getbit()
        let l = 1
        while l <= 16:
            if h.maxcode[l] >= 0 and code <= h.maxcode[l] and code >= h.mincode[l]:
                return h.symbols[h.valptr[l] + code - h.mincode[l]]
            code = (code << 1) | getbit()
            l += 1
        fail("jpeg: bad Huffman code")
    func extend(v, t):
        if t == 0:
            return 0
        if v < (1 << (t - 1)):
            return v - (1 << t) + 1
        return v
    func read_marker_bytes():
        # after an entropy segment: move to the next marker
        while pos + 1 < n and not (d[pos] == 0xff and d[pos + 1] != 0 and d[pos + 1] != 0xff and not (d[pos + 1] >= 0xd0 and d[pos + 1] <= 0xd7)):
            pos += 1
    while pos + 4 <= n:
        if d[pos] != 0xff:
            pos += 1
            continue
        let m = d[pos + 1]
        if m == 0xff:
            pos += 1
            continue
        if m == 0xd8 or m == 0x01 or (m >= 0xd0 and m <= 0xd7):
            pos += 2
            continue
        if m == 0xd9:
            break
        let len_ = (d[pos + 2] << 8) | d[pos + 3]
        let seg = pos + 4
        let segend = pos + 2 + len_
        if m == 0xdb:                                   # DQT
            let p = seg
            while p < segend:
                let pq = d[p] >> 4
                let tq = d[p] & 15
                p += 1
                let t = []
                for i in range(64):
                    t.append(0)
                for i in range(64):
                    if pq == 0:
                        t[ZZ[i]] = d[p]
                        p += 1
                    else:
                        t[ZZ[i]] = (d[p] << 8) | d[p + 1]
                        p += 2
                qts[tq] = t
        elif m == 0xc4:                                 # DHT
            let p = seg
            while p < segend:
                let tc = d[p] >> 4
                let th = d[p] & 15
                p += 1
                let counts = [0]
                let total = 0
                for i in range(16):
                    counts.append(d[p + i])
                    total += d[p + i]
                p += 16
                let symbols = []
                for i in range(total):
                    symbols.append(d[p + i])
                p += total
                if tc == 0:
                    dcs[th] = jhuff_build(counts, symbols)
                else:
                    acs[th] = jhuff_build(counts, symbols)
        elif m == 0xc0 or m == 0xc1 or m == 0xc2:       # SOF0 / SOF1 / SOF2
            if d[seg] != 8:
                fail("jpeg: only 8-bit samples are supported")
            progressive = m == 0xc2
            height = (d[seg + 1] << 8) | d[seg + 2]
            width = (d[seg + 3] << 8) | d[seg + 4]
            let nc = d[seg + 5]
            comps = []
            for i in range(nc):
                let p = seg + 6 + 3 * i
                comps.append({id: d[p], h: d[p + 1] >> 4, v: d[p + 1] & 15, tq: d[p + 2], pred: 0})
            hmax = 1
            vmax = 1
            for c in comps:
                if c.h > hmax:
                    hmax = c.h
                if c.v > vmax:
                    vmax = c.v
            mcux = (width + 8 * hmax - 1) // (8 * hmax)
            mcuy = (height + 8 * vmax - 1) // (8 * vmax)
            for c in comps:
                c.bw = mcux * c.h                            # blocks per row / column, padded to whole MCUs
                c.bh = mcuy * c.v
                c.cw = (width * c.h + hmax - 1) // hmax      # the component's real size in samples
                c.ch = (height * c.v + vmax - 1) // vmax
                c.nbx = (c.cw + 7) // 8                      # blocks that carry image data (non-interleaved scans)
                c.nby = (c.ch + 7) // 8
                c.coef = typed.i16(c.bw * c.bh * 64)
            seen_sof = true
        elif m == 0xc3 or (m >= 0xc5 and m <= 0xcf and m != 0xc8 and m != 0xcc):
            fail("jpeg: arithmetic coding and lossless JPEG are not supported")
        elif m == 0xdd:                                 # DRI
            restart = (d[seg] << 8) | d[seg + 1]
        elif m == 0xe0:
            if len_ >= 7 and d[seg] == 0x4a and d[seg + 1] == 0x46:
                jfif = true
        elif m == 0xee:
            if len_ >= 14 and d[seg] == 0x41 and d[seg + 1] == 0x64 and d[seg + 2] == 0x6f:
                adobe = d[seg + 11]
        elif m == 0xda:                                 # SOS: one scan
            if not seen_sof:
                fail("jpeg: scan before the frame header")
            let ns = d[seg]
            let sc = []
            for i in range(ns):
                let cid = d[seg + 1 + 2 * i]
                let tb = d[seg + 2 + 2 * i]
                let found = nil
                for c in comps:
                    if c.id == cid:
                        found = c
                if found == nil:
                    fail("jpeg: scan refers to an unknown component")
                sc.append({c: found, dc: tb >> 4, ac: tb & 15})
            let ss = d[seg + 1 + 2 * ns]
            let se = d[seg + 2 + 2 * ns]
            let ah = d[seg + 3 + 2 * ns] >> 4
            let al = d[seg + 3 + 2 * ns] & 15
            pos = segend
            rd_reset()
            eobrun = 0
            for s in sc:
                s.c.pred = 0
            # one block of a scan
            func do_block(s, bx, by):
                let c = s.c
                let co = (by * c.bw + bx) * 64
                let coef = c.coef
                if not progressive:
                    let t = hdecode(dcs[s.dc])
                    c.pred += extend(getbits(t), t)
                    coef[co] = c.pred
                    let ach = acs[s.ac]
                    let k = 1
                    while k < 64:
                        let rs = hdecode(ach)
                        let r = rs >> 4
                        let sz = rs & 15
                        if sz == 0:
                            if r == 15:
                                k += 16
                                continue
                            break
                        k += r
                        if k > 63:
                            break
                        coef[co + ZZ[k]] = extend(getbits(sz), sz)
                        k += 1
                elif ss == 0:
                    if ah == 0:                                  # DC first
                        let t = hdecode(dcs[s.dc])
                        c.pred += extend(getbits(t), t)
                        coef[co] = c.pred << al
                    elif getbit() == 1:                          # DC refinement
                        coef[co] = coef[co] | (1 << al)
                elif ah == 0:                                    # AC first
                    if eobrun > 0:
                        eobrun -= 1
                    else:
                        let ach = acs[s.ac]
                        let k = ss
                        while k <= se:
                            let rs = hdecode(ach)
                            let r = rs >> 4
                            let sz = rs & 15
                            if sz == 0:
                                if r < 15:
                                    eobrun = (1 << r) - 1
                                    if r > 0:
                                        eobrun += getbits(r)
                                    break
                                k += 16
                                continue
                            k += r
                            if k > 63:
                                break
                            coef[co + ZZ[k]] = extend(getbits(sz), sz) * (1 << al)
                            k += 1
                else:                                            # AC refinement
                    let p1 = 1 << al
                    let m1 = -1 << al
                    let k = ss
                    if eobrun == 0:
                        let ach = acs[s.ac]
                        while k <= se:
                            let rs = hdecode(ach)
                            let r = rs >> 4
                            let sz = rs & 15
                            let val = 0
                            if sz != 0:
                                val = p1 if getbit() == 1 else m1
                            elif r != 15:
                                eobrun = 1 << r
                                if r > 0:
                                    eobrun += getbits(r)
                                break
                            while k <= se:
                                let cur = coef[co + ZZ[k]]
                                if cur != 0:
                                    if getbit() == 1:
                                        if (cur & p1) == 0:
                                            coef[co + ZZ[k]] = cur + (p1 if cur >= 0 else m1)
                                else:
                                    r -= 1
                                    if r < 0:
                                        break
                                k += 1
                            if val != 0 and k <= 63:
                                coef[co + ZZ[k]] = val
                            k += 1
                    if eobrun > 0:
                        while k <= se:
                            let cur = coef[co + ZZ[k]]
                            if cur != 0:
                                if getbit() == 1:
                                    if (cur & p1) == 0:
                                        coef[co + ZZ[k]] = cur + (p1 if cur >= 0 else m1)
                            k += 1
                        eobrun -= 1
            # the MCU loop (with restart intervals)
            let total = 0
            let single = len(sc) == 1
            if single:
                total = sc[0].c.nbx * sc[0].c.nby
            else:
                total = mcux * mcuy
            let cnt = 0
            while cnt < total:
                if restart > 0 and cnt > 0 and cnt % restart == 0:
                    # the restart marker: skip to it
                    rd_reset()
                    while pos + 1 < n and not (d[pos] == 0xff and d[pos + 1] >= 0xd0 and d[pos + 1] <= 0xd7):
                        pos += 1
                    pos += 2
                    eobrun = 0
                    for s in sc:
                        s.c.pred = 0
                if single:
                    let c = sc[0].c
                    do_block(sc[0], cnt % c.nbx, cnt // c.nbx)
                else:
                    let mx = cnt % mcux
                    let my = cnt // mcux
                    for s in sc:
                        for v in range(s.c.v):
                            for h in range(s.c.h):
                                do_block(s, mx * s.c.h + h, my * s.c.v + v)
                cnt += 1
            # the next marker
            while pos + 1 < n and not (d[pos] == 0xff and d[pos + 1] != 0 and d[pos + 1] != 0xff and not (d[pos + 1] >= 0xd0 and d[pos + 1] <= 0xd7)):
                pos += 1
            continue
        pos = segend
    if not seen_sof:
        fail("jpeg: no frame header")
    # ---- dequantise + inverse DCT into one sample plane per component ----
    let ws = []
    for i in range(64):
        ws.append(0)
    for c in comps:
        let qt = qts[c.tq]
        if qt == nil:
            fail("jpeg: missing quantisation table")
        let stride = c.bw * 8
        c.plane = typed.u8(stride * c.bh * 8)
        c.stride = stride
        for by in range(c.bh):
            for bx in range(c.bw):
                idct_block(c.coef, (by * c.bw + bx) * 64, qt, c.plane, by * 8 * stride + bx * 8, stride, ws)
        c.coef = nil
    # ---- upsample every component to the full size (libjpeg's "fancy" upsampling) ----
    let full = []
    for c in comps:
        let up = typed.u8(width * height)
        let hs = hmax // c.h
        let vs = vmax // c.v
        let pl = c.plane
        let st = c.stride
        if hs == 1 and vs == 1:
            for y in range(height):
                for x in range(width):
                    up[y * width + x] = pl[y * st + x]
        elif hs == 2 and vs == 1 and c.cw > 2 and hmax % c.h == 0 and vmax % c.v == 0:
            for y in range(height):
                let r = y * st
                for x in range(width):
                    let i = x >> 1
                    let v = 0
                    if i == 0 and (x & 1) == 0:
                        v = pl[r]
                    elif i == c.cw - 1 and (x & 1) == 1:
                        v = pl[r + i]
                    elif (x & 1) == 0:
                        v = (3 * pl[r + i] + pl[r + i - 1] + 1) >> 2
                    else:
                        v = (3 * pl[r + i] + pl[r + i + 1] + 2) >> 2
                    up[y * width + x] = v
        elif hs == 2 and vs == 2 and c.cw > 2 and hmax % c.h == 0 and vmax % c.v == 0:
            for y in range(height):
                let sy = y >> 1
                let ny = sy - 1 if (y & 1) == 0 else sy + 1
                if ny < 0:
                    ny = 0
                if ny > c.ch - 1:
                    ny = c.ch - 1
                if sy > c.ch - 1:
                    sy = c.ch - 1
                let r0 = sy * st
                let r1 = ny * st
                for x in range(width):
                    let i = x >> 1
                    let this = 3 * pl[r0 + i] + pl[r1 + i]
                    let v = 0
                    if (x & 1) == 0:
                        if i == 0:
                            v = (this * 4 + 8) >> 4
                        else:
                            let last = 3 * pl[r0 + i - 1] + pl[r1 + i - 1]
                            v = (this * 3 + last + 8) >> 4
                    else:
                        if i == c.cw - 1:
                            v = (this * 4 + 7) >> 4
                        else:
                            let nxt = 3 * pl[r0 + i + 1] + pl[r1 + i + 1]
                            v = (this * 3 + nxt + 7) >> 4
                    up[y * width + x] = v
        elif hs == 1 and vs == 2 and hmax % c.h == 0 and vmax % c.v == 0:
            for y in range(height):
                let sy = y >> 1
                let ny = sy - 1 if (y & 1) == 0 else sy + 1
                if ny < 0:
                    ny = 0
                if ny > c.ch - 1:
                    ny = c.ch - 1
                if sy > c.ch - 1:
                    sy = c.ch - 1
                let bias = 1 if (y & 1) == 0 else 2
                for x in range(width):
                    up[y * width + x] = (3 * pl[sy * st + x] + pl[ny * st + x] + bias) >> 2
        else:
            for y in range(height):
                for x in range(width):
                    up[y * width + x] = pl[(y // vs) * st + x // hs]
        c.plane = nil
        full.append(up)
    # ---- colour conversion (jdcolor.c) ----
    let rgba = typed.u8(width * height * 4)
    let nc = len(comps)
    if nc == 1:
        let g = full[0]
        for i in range(width * height):
            rgba[4 * i] = g[i]
            rgba[4 * i + 1] = g[i]
            rgba[4 * i + 2] = g[i]
            rgba[4 * i + 3] = 255
    elif nc == 3:
        let ycc = true
        if jfif:
            ycc = true
        elif adobe >= 0:
            ycc = adobe != 0
        elif comps[0].id == 0x52 and comps[1].id == 0x47 and comps[2].id == 0x42:
            ycc = false
        let y0 = full[0]
        let cb = full[1]
        let cr = full[2]
        if ycc:
            # fixed-point tables as in libjpeg: 16 fractional bits
            let cr_r = []
            let cb_b = []
            let cr_g = []
            let cb_g = []
            for i in range(256):
                let x = i - 128
                cr_r.append((91881 * x + 32768) >> 16)
                cb_b.append((116130 * x + 32768) >> 16)
                cr_g.append(-46802 * x)
                cb_g.append(-22554 * x + 32768)
            for i in range(width * height):
                let y = y0[i]
                rgba[4 * i] = clamp8(y + cr_r[cr[i]])
                rgba[4 * i + 1] = clamp8(y + ((cb_g[cb[i]] + cr_g[cr[i]]) >> 16))
                rgba[4 * i + 2] = clamp8(y + cb_b[cb[i]])
                rgba[4 * i + 3] = 255
        else:
            for i in range(width * height):
                rgba[4 * i] = y0[i]
                rgba[4 * i + 1] = cb[i]
                rgba[4 * i + 2] = cr[i]
                rgba[4 * i + 3] = 255
    elif nc == 4:
        # Adobe CMYK / YCCK: the values are stored inverted
        let c0 = full[0]
        let c1 = full[1]
        let c2 = full[2]
        let k = full[3]
        for i in range(width * height):
            let r = c0[i]
            let g = c1[i]
            let b = c2[i]
            if adobe == 2:                                   # YCCK: convert the first three to (inverted) CMY
                let y = c0[i]
                let cbv = c1[i] - 128
                let crv = c2[i] - 128
                r = clamp8(y + ((91881 * crv + 32768) >> 16))
                g = clamp8(y + ((-22554 * cbv - 46802 * crv + 32768) >> 16))
                b = clamp8(y + ((116130 * cbv + 32768) >> 16))
            rgba[4 * i] = (r * k[i] + 127) // 255
            rgba[4 * i + 1] = (g * k[i] + 127) // 255
            rgba[4 * i + 2] = (b * k[i] + 127) // 255
            rgba[4 * i + 3] = 255
    else:
        fail("jpeg: unsupported number of components")
    return {width: width, height: height, rgba: rgba}
