# sslasn1: a DER reader for SprintSSL (X.509 and friends). Byte strings are typed.u8 values.
#
#   let n = asn1.read(der, 0)            # {tag, cons, hs: header start, s: content start, e: content end}
#   for c in asn1.children(der, n): ...  # the nodes inside a constructed node
import sslcore

export const T_BOOL = 1
export const T_INT = 2
export const T_BITS = 3
export const T_OCTETS = 4
export const T_NULL = 5
export const T_OID = 6
export const T_UTF8 = 12
export const T_SEQ = 16
export const T_SET = 17
export const T_PRINTABLE = 19
export const T_IA5 = 22
export const T_UTC = 23
export const T_GENTIME = 24

func bad(msg):
    throw error("EASN1", msg)

# the node at offset o of b (a universal tag, or any tag number below 31 with its class bits kept in cls)
export func read(b, o):
    if o + 2 > len(b):
        bad("truncated")
    let t = b[o]
    let tag = t & 31
    if tag == 31:
        bad("high tag numbers are not supported")
    let p = o + 1
    let l = b[p]
    p += 1
    if l >= 128:
        let k = l & 127
        if k == 0 or k > 4 or p + k > len(b):
            bad("bad length")
        l = 0
        for i in range(k):
            l = (l << 8) | b[p + i]
        p += k
    if p + l > len(b):
        bad("length runs past the end")
    return {tag: tag, cls: t >> 6, cons: (t & 32) != 0, hs: o, s: p, e: p + l}

export func children(b, n):
    let out = []
    let o = n.s
    while o < n.e:
        let c = read(b, o)
        out.append(c)
        o = c.e
    return out

# the whole encoding of a node (header and content)
export func raw(b, n):
    return b.slice(n.hs, n.e)

export func content(b, n):
    return b.slice(n.s, n.e)

# an INTEGER's magnitude as bytes (a leading zero byte removed)
export func uint_bytes(b, n):
    let s = n.s
    while s < n.e - 1 and b[s] == 0:
        s += 1
    return b.slice(s, n.e)

export func to_int(b, n):
    let v = 0
    for i in range(n.s, n.e):
        v = (v << 8) | b[i]
    return v

export func oid(b, n):
    let parts = []
    let v = 0
    let first = true
    for i in range(n.s, n.e):
        v = (v << 7) | (b[i] & 127)
        if (b[i] & 128) == 0:
            if first:
                let a = 2 if v >= 80 else v // 40
                parts.append(to_string(a))
                parts.append(to_string(v - a * 40))
                first = false
            else:
                parts.append(to_string(v))
            v = 0
    return parts.join(".")

# BIT STRING content without the unused-bits byte
export func bits(b, n):
    return b.slice(n.s + 1, n.e)

export func days_from_civil(y, m, d):
    let yy = y - (1 if m <= 2 else 0)
    let era = yy // 400
    let yoe = yy - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) // 5 + d - 1
    let doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468

func digits(b, o, n):
    let v = 0
    for i in range(n):
        let c = b[o + i]
        if c < 48 or c > 57:
            bad("bad time")
        v = v * 10 + (c - 48)
    return v

# UTCTime / GeneralizedTime as seconds since 1970 (UTC)
export func time(b, n):
    let o = n.s
    let y = 0
    if n.tag == T_UTC:
        y = digits(b, o, 2)
        y += 2000 if y < 50 else 1900
        o += 2
    else:
        y = digits(b, o, 4)
        o += 4
    let mo = digits(b, o, 2)
    let d = digits(b, o + 2, 2)
    let h = digits(b, o + 4, 2)
    let mi = digits(b, o + 6, 2)
    let s = 0
    if o + 8 < n.e and b[o + 8] != 90:
        s = digits(b, o + 8, 2)
    return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s

# DER writers (for building test certificates and signatures)
export func enc(tag, body):
    let n = len(body)
    let hdr = [tag]
    if n < 128:
        hdr.append(n)
    elif n < 256:
        hdr.extend([0x81, n])
    elif n < 65536:
        hdr.extend([0x82, n >> 8, n & 255])
    else:
        hdr.extend([0x83, n >> 16, (n >> 8) & 255, n & 255])
    return sslcore.concat([hdr, body])
