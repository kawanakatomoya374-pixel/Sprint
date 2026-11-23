# der: ASN.1 DER reading and writing, base64 and PEM - just enough for X.509 certificates, RSA keys and Authenticode (PKCS#7) signatures.
# Byte strings are arrays of ints 0..255.

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

export func cat(...parts):
    let out = []
    for p in parts:
        for b in p:
            out.append(b)
    return out

export func base64_decode(text):
    let out = []
    let acc = 0
    let bits = 0
    for i in range(len(text)):
        let ch = text[i]
        let v = -1
        if ch >= 65 and ch <= 90:
            v = ch - 65
        elif ch >= 97 and ch <= 122:
            v = ch - 71
        elif ch >= 48 and ch <= 57:
            v = ch + 4
        elif ch == 43:
            v = 62
        elif ch == 47:
            v = 63
        if v < 0:
            continue                      # '=', whitespace, anything else
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 255)
            acc = acc & ((1 << bits) - 1)
    return out

# the DER bytes of the first PEM block (any label), plus the label
export func pem_decode(text):
    let lines = text.split("\n")
    let label = ""
    let body = ""
    let inside = false
    for l in lines:
        let t = l.trim()
        if t.starts_with("-----BEGIN "):
            label = t.slice(11, len(t) - 5)
            inside = true
        elif t.starts_with("-----END "):
            break
        elif inside:
            body = body .. t
    return {label: label, der: base64_decode(body)}

# ---- writing ----------------------------------------------------------------------------------------------------
func length_bytes(n):
    if n < 128:
        return [n]
    let b = []
    let v = n
    while v > 0:
        b.insert(0, v & 255)
        v = v >> 8
    return cat([0x80 | len(b)], b)

export func tlv(tag, content):
    return cat([tag], length_bytes(len(content)), content)

export func seq(...parts):
    return tlv(0x30, cat(...parts))

export func set_of(...parts):
    return tlv(0x31, cat(...parts))

export func octets(b):
    return tlv(0x04, b)

export func null_():
    return [0x05, 0x00]

# an OBJECT IDENTIFIER from "1.2.840.113549.1.1.1"
export func oid(text):
    let arcs = []
    for p in text.split("."):
        arcs.append(to_int(p))
    let out = [arcs[0] * 40 + arcs[1]]
    for i in range(2, len(arcs)):
        let v = arcs[i]
        let chunk = [v & 127]
        v = v >> 7
        while v > 0:
            chunk.insert(0, (v & 127) | 128)
            v = v >> 7
        out = cat(out, chunk)
    return tlv(0x06, out)

# ---- reading ------------------------------------------------------------------------------------------------------
# the element at `off`: {tag, hdr (header length), len, start (content), end}
export func read(b, off):
    let tag = b[off]
    let l = b[off + 1]
    let p = off + 2
    if l >= 128:
        let n = l & 127
        l = 0
        for i in range(n):
            l = (l << 8) | b[p + i]
        p += n
    return {tag: tag, start: p, len: l, end: p + l, off: off}

export func slice(b, lo, hi):
    let out = []
    for i in range(lo, hi):
        out.append(b[i])
    return out

# the children of a constructed element
export func children(b, e):
    let out = []
    let p = e.start
    while p < e.end:
        let c = read(b, p)
        out.append(c)
        p = c.end
    return out

# the content of an INTEGER without its leading zero byte
export func uint_bytes(b, e):
    let lo = e.start
    while lo < e.end - 1 and b[lo] == 0:
        lo += 1
    return slice(b, lo, e.end)

# an RSA private key (PKCS#1 or PKCS#8) -> {n, e, d, p, q, dp, dq, qinv} (big-endian byte arrays)
export func rsa_private_key(der):
    let top = read(der, 0)
    let kids = children(der, top)
    let rsa = top
    if kids[0].tag == 0x02 and kids[1].tag == 0x30:      # PKCS#8: version, AlgorithmIdentifier, OCTET STRING { RSAPrivateKey }
        let inner = kids[2]
        rsa = read(der, inner.start)
        kids = children(der, rsa)
    else:
        kids = children(der, rsa)
    # RSAPrivateKey: version, n, e, d, p, q, dp, dq, qinv
    return {n: uint_bytes(der, kids[1]), e: uint_bytes(der, kids[2]), d: uint_bytes(der, kids[3]), p: uint_bytes(der, kids[4]),
            q: uint_bytes(der, kids[5]), dp: uint_bytes(der, kids[6]), dq: uint_bytes(der, kids[7]), qinv: uint_bytes(der, kids[8])}

# an X.509 certificate -> {issuer: DER of the issuer Name, serial: DER of the serial INTEGER}
export func cert_ids(der):
    let top = read(der, 0)
    let tbs = children(der, top)[0]
    let f = children(der, tbs)
    let i = 0
    if f[0].tag == 0xa0:     # [0] version
        i = 1
    return {serial: slice(der, f[i].off, f[i].end), issuer: slice(der, f[i + 2].off, f[i + 2].end)}
