#!/usr/bin/env python3
"""Compares stdlib/image.sp with PIL (libpng / libjpeg-turbo) on generated images.  usage: python3 tools/image/check.py [png] [bmp] [jpeg]"""
import io, os, random, subprocess, sys, tempfile
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPRINT = os.path.join(ROOT, "build/sprint")
random.seed(7)

def pattern(w, h, mode):
    """a test picture with gradients, sharp edges and noise"""
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            r = (x * 255 // max(1, w - 1))
            g = (y * 255 // max(1, h - 1))
            b = ((x ^ y) * 4) & 255
            if (x // 5 + y // 7) % 3 == 0:
                r, g, b = 255 - r, 255 - g, 255 - b
            if random.random() < 0.05:
                r = random.randrange(256)
            px[x, y] = (r, g, b)
    if mode == "RGB":
        return im
    if mode == "RGBA":
        a = Image.linear_gradient("L").resize((w, h))
        im = im.convert("RGBA"); im.putalpha(a); return im
    if mode == "L":
        return im.convert("L")
    if mode == "LA":
        im = im.convert("L").convert("LA"); im.putalpha(Image.linear_gradient("L").resize((w, h))); return im
    if mode == "P":
        return im.quantize(colors=40)
    if mode == "1":
        return im.convert("L").convert("1")
    raise ValueError(mode)

def run(path, wd):
    out = os.path.join(wd, "out.bin")
    r = subprocess.run([SPRINT, "run", f"--allow-read={wd}", f"--allow-write={wd}", os.path.join(ROOT, "tools/image/dump.sp"), path, out], capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr.strip().split("\n")[0]
    data = open(out, "rb").read()
    return (int.from_bytes(data[0:4], "little"), int.from_bytes(data[4:8], "little"), data[8:]), None

def compare(name, blob, wd, tol=0):
    ext = name.split(".")[-1]
    path = os.path.join(wd, "in." + ext)
    open(path, "wb").write(blob)
    try:
        ref = Image.open(io.BytesIO(blob)).convert("RGBA")
    except Exception as e:                      # a format PIL itself cannot read: nothing to compare with
        print(f"skip {name}: PIL cannot read it ({type(e).__name__})"); return True
    got, err = run(path, wd)
    if got is None:
        print(f"FAIL {name}: {err}"); return False
    w, h, px = got
    want = ref.tobytes()
    if (w, h) != ref.size:
        print(f"FAIL {name}: size {w}x{h} vs {ref.size}"); return False
    bad = sum(1 for a, b in zip(px, want) if abs(a - b) > tol)
    if bad:
        print(f"FAIL {name}: {bad} of {len(want)} bytes differ (tolerance {tol})"); return False
    print(f"ok   {name}"); return True

def png_cases():
    c = []
    for mode in ("RGB", "RGBA", "L", "LA", "P", "1"):
        for (w, h) in ((1, 1), (7, 5), (33, 20)):
            for interlace in (False, True):
                if (w, h) == (1, 1) and interlace: continue
                b = io.BytesIO()
                pattern(w, h, mode).save(b, "PNG", interlace=interlace) if False else None
                im = pattern(w, h, mode)
                bio = io.BytesIO()
                # PIL has no interlaced PNG writer: build those with the system convert instead
                if interlace:
                    import subprocess as sp
                    tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False); tmp.close()
                    im.save(tmp.name, "PNG")
                    out = tmp.name + ".i.png"
                    sp.run(["convert", tmp.name, "-interlace", "PNG", out], check=True, capture_output=True)
                    c.append((f"png {mode} {w}x{h} interlaced", open(out, "rb").read()))
                else:
                    im.save(bio, "PNG"); c.append((f"png {mode} {w}x{h}", bio.getvalue()))
    # transparency chunks and 16-bit
    im = pattern(20, 12, "P"); bio = io.BytesIO(); im.save(bio, "PNG", transparency=3); c.append(("png P tRNS", bio.getvalue()))
    im = pattern(20, 12, "RGB"); bio = io.BytesIO(); im.save(bio, "PNG", transparency=(255, 0, 0)); c.append(("png RGB tRNS", bio.getvalue()))
    for bits in ("8", "16"):
        tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False); tmp.close()
        pattern(19, 11, "RGBA").save(tmp.name + ".src.png")
        subprocess.run(["convert", tmp.name + ".src.png", "-depth", bits, tmp.name], check=True, capture_output=True)
        c.append((f"png RGBA depth {bits} (convert)", open(tmp.name, "rb").read()))
    for depth in (2, 4):
        tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False); tmp.close()
        pattern(23, 9, "L").save(tmp.name + ".src.png")
        subprocess.run(["convert", tmp.name + ".src.png", "-depth", str(depth), "-define", f"png:bit-depth={depth}", tmp.name], check=True, capture_output=True)
        c.append((f"png gray depth {depth} (convert)", open(tmp.name, "rb").read()))
    bio = io.BytesIO(); pattern(300, 200, "RGB").save(bio, "PNG", compress_level=9); c.append(("png RGB 300x200", bio.getvalue()))
    bio = io.BytesIO(); pattern(64, 64, "RGB").save(bio, "PNG", compress_level=0); c.append(("png stored blocks", bio.getvalue()))
    return c

def bmp_cases():
    c = []
    for mode, bits in (("RGB", None), ("RGBA", None), ("L", None), ("P", None), ("1", None)):
        for (w, h) in ((1, 1), (5, 3), (31, 17)):
            im = pattern(w, h, mode)
            bio = io.BytesIO(); im.save(bio, "BMP"); c.append((f"bmp {mode} {w}x{h}", bio.getvalue()))
    for (w, h) in ((13, 9),):
        tmp = tempfile.NamedTemporaryFile(suffix=".bmp", delete=False); tmp.close()
        pattern(w, h, "RGB").save(tmp.name + ".src.png")
        for opt, name in (("BMP3:", "bmp3"), ("BMP:", "bmp default")):
            subprocess.run(["convert", tmp.name + ".src.png", opt + tmp.name], check=True, capture_output=True)
            c.append((f"{name} 24-bit {w}x{h}", open(tmp.name, "rb").read()))
        subprocess.run(["convert", tmp.name + ".src.png", "-colors", "16", "BMP3:" + tmp.name], check=True, capture_output=True)
        c.append(("bmp 4-bit palette", open(tmp.name, "rb").read()))
        subprocess.run(["convert", tmp.name + ".src.png", "-colors", "200", "-compress", "RLE", "BMP3:" + tmp.name], check=True, capture_output=True)
        c.append(("bmp 8-bit RLE", open(tmp.name, "rb").read()))
        subprocess.run(["convert", tmp.name + ".src.png", "-define", "bmp:subtype=RGB565", "BMP3:" + tmp.name], check=True, capture_output=True)
        c.append(("bmp 565 (convert)", open(tmp.name, "rb").read()))
    return c

def jpeg_cases():
    c = []
    for mode in ("RGB", "L"):
        for sub in ((0, 1, 2) if mode == "RGB" else (None,)):
            for q in (30, 85, 100):
                for prog in (False, True):
                    for (w, h) in ((16, 16), (37, 29), (130, 70)):
                        im = pattern(w, h, mode)
                        bio = io.BytesIO()
                        kw = dict(quality=q, progressive=prog)
                        if sub is not None: kw["subsampling"] = sub
                        im.save(bio, "JPEG", **kw)
                        c.append((f"jpeg {mode} sub={sub} q={q} {'progressive' if prog else 'baseline'} {w}x{h}", bio.getvalue()))
    im = pattern(50, 40, "RGB"); bio = io.BytesIO(); im.save(bio, "JPEG", quality=80, restart_marker_blocks=3); c.append(("jpeg restart intervals", bio.getvalue()))
    im = pattern(50, 40, "RGB"); bio = io.BytesIO(); im.save(bio, "JPEG", quality=80, optimize=True); c.append(("jpeg optimized huffman", bio.getvalue()))
    return c

def main():
    what = sys.argv[1:] or ["png", "bmp", "jpeg"]
    bad = 0
    with tempfile.TemporaryDirectory() as wd:
        for kind in what:
            cases = {"png": png_cases, "bmp": bmp_cases, "jpeg": jpeg_cases}[kind]()
            for name, blob in cases:
                if not compare(name, blob, wd):
                    bad += 1
            print(f"{kind}: {len(cases)} images")
    sys.exit(1 if bad else 0)

main()
