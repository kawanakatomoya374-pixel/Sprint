# sslx509: X.509 certificates for SprintSSL: parsing, signature verification (RSA PKCS#1 v1.5 and PSS, ECDSA P-256 / P-384, Ed25519), chain validation
# against a list of trusted roots, host name matching.
#
#   let c = x509.parse(der)
#   x509.verify_chain([leaf, intermediate, ...], roots, "example.com", now)   # nil when fine, otherwise a reason string
import sslcore
import sslasn1 as asn1

const OID_RSA = "1.2.840.113549.1.1.1"
const OID_PSS = "1.2.840.113549.1.1.10"
const OID_EC = "1.2.840.10045.2.1"
const OID_P256 = "1.2.840.10045.3.1.7"
const OID_P384 = "1.3.132.0.34"
const OID_ED25519 = "1.3.101.112"
const OID_SAN = "2.5.29.17"
const OID_BC = "2.5.29.19"
const OID_KU = "2.5.29.15"
const OID_EKU = "2.5.29.37"
const OID_CN = "2.5.4.3"

# signature algorithm OID -> [kind, hash]
const SIGALGS = {
    "1.2.840.113549.1.1.11": ["rsa", 256], "1.2.840.113549.1.1.12": ["rsa", 384], "1.2.840.113549.1.1.13": ["rsa", 512],
    "1.2.840.113549.1.1.10": ["pss", 0],
    "1.2.840.10045.4.3.2": ["ecdsa", 256], "1.2.840.10045.4.3.3": ["ecdsa", 384], "1.2.840.10045.4.3.4": ["ecdsa", 512],
    "1.3.101.112": ["ed25519", 0]
}

# DigestInfo prefixes for PKCS#1 v1.5
const DI = {
    256: "3031300d060960864801650304020105000420",
    384: "3041300d060960864801650304020205000430",
    512: "3051300d060960864801650304020305000440"
}

func fail(msg):
    throw error("EX509", msg)

# ---- PEM ----
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
export func b64decode(s):
    let out = []
    let acc = 0
    let bits = 0
    for i in range(len(s)):
        let c = s[i]
        let v = -1
        if c >= 65 and c <= 90:
            v = c - 65
        elif c >= 97 and c <= 122:
            v = c - 71
        elif c >= 48 and c <= 57:
            v = c + 4
        elif c == 43 or c == 45:
            v = 62
        elif c == 47 or c == 95:
            v = 63
        if v < 0:
            continue
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 255)
            acc = acc & ((1 << bits) - 1)
    return sslcore.concat([out])

export func b64encode(b):
    let out = []
    let i = 0
    while i < len(b):
        let n = len(b) - i
        let v = b[i] << 16
        if n > 1:
            v = v | (b[i + 1] << 8)
        if n > 2:
            v = v | b[i + 2]
        out.append(B64.slice((v >> 18) & 63, ((v >> 18) & 63) + 1))
        out.append(B64.slice((v >> 12) & 63, ((v >> 12) & 63) + 1))
        out.append(B64.slice((v >> 6) & 63, ((v >> 6) & 63) + 1) if n > 1 else "=")
        out.append(B64.slice(v & 63, (v & 63) + 1) if n > 2 else "=")
        i += 3
    return out.join("")

# every CERTIFICATE block of a PEM text, as DER bytes
export func pem_certs(text):
    let out = []
    let pos = 0
    let head = "-----BEGIN CERTIFICATE-----"
    let tail = "-----END CERTIFICATE-----"
    while true:
        let a = text.find(head, pos)
        if a < 0:
            break
        let b = text.find(tail, a)
        if b < 0:
            break
        out.append(b64decode(text.slice(a + len(head), b)))
        pos = b + len(tail)
    return out

# ---- parsing ----
func parse_name_cn(der, name):
    let cn = nil
    for rdn in asn1.children(der, name):
        for atv in asn1.children(der, rdn):
            let kv = asn1.children(der, atv)
            if asn1.oid(der, kv[0]) == OID_CN:
                cn = sslcore.to_str(asn1.content(der, kv[1]))
    return cn

export func parse(der):
    let top = asn1.read(der, 0)
    let parts = asn1.children(der, top)
    if len(parts) != 3:
        fail("not a certificate")
    let tbs = parts[0]
    let f = asn1.children(der, tbs)
    let i = 0
    if f[0].cls == 2:             # [0] version
        i = 1
    let c = {der: der, tbs: asn1.raw(der, tbs), serial: asn1.uint_bytes(der, f[i]), ca: false, path_len: -1, key_usage: nil, san_dns: [], san_ip: [], eku: nil}
    let sa = asn1.children(der, f[i + 1])
    c.sig_oid = asn1.oid(der, sa[0])
    c.sig_params = asn1.raw(der, sa[1]) if len(sa) > 1 else nil
    c.issuer = asn1.raw(der, f[i + 2])
    let val = asn1.children(der, f[i + 3])
    c.not_before = asn1.time(der, val[0])
    c.not_after = asn1.time(der, val[1])
    c.subject = asn1.raw(der, f[i + 4])
    c.cn = parse_name_cn(der, f[i + 4])
    let spki = asn1.children(der, f[i + 5])
    let alg = asn1.children(der, spki[0])
    c.key_alg = asn1.oid(der, alg[0])
    c.key_curve = nil
    if len(alg) > 1 and alg[1].tag == asn1.T_OID:
        c.key_curve = asn1.oid(der, alg[1])
    c.key = asn1.bits(der, spki[1])
    c.spki = asn1.raw(der, f[i + 5])
    c.sig = asn1.bits(der, parts[2])
    for x in f.slice(i + 6):
        if x.cls != 2 or x.tag != 3:         # [3] extensions
            continue
        let exts = asn1.children(der, asn1.children(der, x)[0])
        for ex in exts:
            let e = asn1.children(der, ex)
            let id = asn1.oid(der, e[0])
            let v = e[len(e) - 1]
            let body = asn1.read(der, v.s)
            if id == OID_BC:
                for p in asn1.children(der, body):
                    if p.tag == asn1.T_BOOL:
                        c.ca = der[p.s] != 0
                    elif p.tag == asn1.T_INT:
                        c.path_len = asn1.to_int(der, p)
            elif id == OID_KU:
                let kb = asn1.bits(der, body)
                let v2 = 0
                for k in range(len(kb)):
                    v2 = v2 | (kb[k] << (8 * k))
                c.key_usage = v2
            elif id == OID_SAN:
                for g in asn1.children(der, body):
                    if g.cls == 2 and g.tag == 2:
                        c.san_dns.append(sslcore.to_str(asn1.content(der, g)))
                    elif g.cls == 2 and g.tag == 7:
                        c.san_ip.append(asn1.content(der, g))
            elif id == OID_EKU:
                c.eku = []
                for o in asn1.children(der, body):
                    c.eku.append(asn1.oid(der, o))
    return c

# ---- signatures ----
func pkcs1_ok(em, h, digest):
    let prefix = sslcore.unhex(DI[h])
    let n = len(em)
    let ps = n - 3 - len(prefix) - len(digest)
    if ps < 8:
        return false
    let ones = []
    for i in range(ps):
        ones.append(255)
    let exp = sslcore.concat([[0, 1], ones, [0], prefix, digest])
    return sslcore.eq(em, exp)

func mgf1(h, seed, n):
    let out = []
    let i = 0
    while len(out) < n:
        out.append(sslcore.hash(h, sslcore.concat([seed, [(i >> 24) & 255, (i >> 16) & 255, (i >> 8) & 255, i & 255]])))
        i += 1
    return sslcore.concat(out).slice(0, n)

func xor_bytes(a, b):
    let r = []
    for i in range(len(a)):
        r.append(a[i] ^ b[i])
    return r

# EMSA-PSS-Verify (RFC 8017 9.1.2) with MGF1 over the same hash; modbits is the bit length of the RSA modulus
func pss_ok(em_full, modbits, h, mhash):
    let hl = len(mhash)
    let emlen = (modbits - 1 + 7) // 8
    let em = em_full.slice(len(em_full) - emlen)
    if em[emlen - 1] != 0xbc or emlen < 2 * hl + 2:
        return false
    let db_len = emlen - hl - 1
    let masked = em.slice(0, db_len)
    let hh = em.slice(db_len, db_len + hl)
    let topbits = 8 * emlen - (modbits - 1)
    if (masked[0] >> (8 - topbits)) != 0 and topbits > 0:
        return false
    let db = xor_bytes(masked, mgf1(h, hh, db_len))
    if topbits > 0:
        db[0] = db[0] & (255 >> topbits)
    let i = 0
    while i < db_len and db[i] == 0:
        i += 1
    if i >= db_len or db[i] != 1:
        return false
    let salt = db.slice(i + 1)
    let mp = sslcore.concat([[0, 0, 0, 0, 0, 0, 0, 0], mhash, salt])
    return sslcore.eq(sslcore.hash(h, mp), hh)

func bit_length(n):
    let i = 0
    while i < len(n) - 1 and n[i] == 0:
        i += 1
    let top = n[i]
    let b = 0
    while top > 0:
        b += 1
        top = top >> 1
    return (len(n) - i - 1) * 8 + b

# the RSA parameters of a certificate's key: [n, e]
export func rsa_key(c):
    let seq = asn1.read(c.key, 0)
    let p = asn1.children(c.key, seq)
    return [asn1.uint_bytes(c.key, p[0]), asn1.uint_bytes(c.key, p[1])]

# (r, s) from an ECDSA DER signature
export func ecdsa_parts(sig):
    let seq = asn1.read(sig, 0)
    let p = asn1.children(sig, seq)
    return [asn1.uint_bytes(sig, p[0]), asn1.uint_bytes(sig, p[1])]

# verify a signature made with the key of certificate-like `key` {alg, curve, key}: scheme is "rsa-pkcs1", "rsa-pss", "ecdsa" or "ed25519" and h the hash (256, 384, 512)
export func verify_with(k, scheme, h, msg, sig):
    if scheme == "ed25519":
        return k.key_alg == OID_ED25519 and sslcore.ed25519_verify(sig, msg, k.key)
    if scheme == "ecdsa":
        if k.key_alg != OID_EC:
            return false
        let curve = 256 if k.key_curve == OID_P256 else (384 if k.key_curve == OID_P384 else 0)
        if curve == 0:
            return false
        let rs = nil
        try:
            rs = ecdsa_parts(sig)
        catch e:
            return false
        return sslcore.ecdsa_verify(curve, k.key, sslcore.hash(h, msg), rs[0], rs[1])
    if scheme == "rsa-pkcs1" or scheme == "rsa-pss":
        if k.key_alg != OID_RSA and k.key_alg != OID_PSS:
            return false
        let nk = rsa_key(k)
        let em = sslcore.rsa_public(nk[0], nk[1], sig)
        if em == nil:
            return false
        if scheme == "rsa-pkcs1":
            return pkcs1_ok(em, h, sslcore.hash(h, msg))
        return pss_ok(em, bit_length(nk[0]), h, sslcore.hash(h, msg))
    return false

# PSS parameters of a certificate signature: the hash (256 when absent)
func pss_hash(params):
    if params == nil:
        return 256
    let n = asn1.read(params, 0)
    for p in asn1.children(params, n):
        if p.cls == 2 and p.tag == 0:
            let alg = asn1.children(params, asn1.children(params, p)[0])
            let o = asn1.oid(params, alg[0])
            if o == "2.16.840.1.101.3.4.2.1":
                return 256
            if o == "2.16.840.1.101.3.4.2.2":
                return 384
            if o == "2.16.840.1.101.3.4.2.3":
                return 512
    return 256

# did `issuer` sign certificate `c`?
export func signed_by(c, issuer):
    let sa = SIGALGS[c.sig_oid]
    if sa == nil:
        return false
    let k = {key_alg: issuer.key_alg, key_curve: issuer.key_curve, key: issuer.key}
    if sa[0] == "rsa":
        return verify_with(k, "rsa-pkcs1", sa[1], c.tbs, c.sig)
    if sa[0] == "pss":
        return verify_with(k, "rsa-pss", pss_hash(c.sig_params), c.tbs, c.sig)
    return verify_with(k, sa[0], sa[1], c.tbs, c.sig)

# ---- names ----
func lower(s):
    return s.lower()

# does the host name match a certificate name (a wildcard stands for exactly the first label)?
export func name_matches(pattern, host):
    let p = pattern.lower()
    let h = host.lower()
    if p == h:
        return true
    if len(p) > 2 and p.slice(0, 2) == "*.":
        let dot = h.find(".", 0)
        if dot > 0 and h.slice(dot) == p.slice(1):
            return true
    return false

func ip_bytes(host):
    let p = host.split(".")
    if len(p) != 4:
        return nil
    let out = []
    for x in p:
        if len(x) == 0 or len(x) > 3:
            return nil
        let n = 0
        for i in range(len(x)):
            let ch = x[i]
            if ch < 48 or ch > 57:
                return nil
            n = n * 10 + ch - 48
        if n > 255:
            return nil
        out.append(n)
    return sslcore.concat([out])

export func host_matches(c, host):
    let ip = ip_bytes(host)
    if ip != nil:
        for a in c.san_ip:
            if sslcore.eq(a, ip):
                return true
        return false
    for n in c.san_dns:
        if name_matches(n, host):
            return true
    return false

func same_bytes(a, b):
    return sslcore.eq(a, b)

# Validate a chain (leaf first). `roots` is an array of parsed certificates that are trusted; `now` seconds since 1970 (nil: do not check dates).
# Returns nil when the chain is good, else a string saying why not. host nil: no name check.
export func verify_chain(chain, roots, host, now):
    if len(chain) == 0:
        return "no certificate"
    let leaf = chain[0]
    if host != nil and not host_matches(leaf, host):
        return "the certificate is not valid for " .. host
    let cur = leaf
    for depth in range(10):
        if now != nil and (now < cur.not_before or now > cur.not_after):
            return "certificate expired or not yet valid (" .. (cur.cn ?? "?") .. ")"
        if cur.key_usage != nil and cur != leaf and (cur.key_usage & 4) == 0 and cur.ca:
            return "CA certificate may not sign certificates"
        for r in roots:
            if same_bytes(r.subject, cur.issuer) and signed_by(cur, r):
                if now != nil and (now < r.not_before or now > r.not_after):
                    return "the root certificate has expired"
                return nil
        # a root that was sent with the chain and is trusted by itself
        let next = nil
        for c in chain.slice(1):
            if same_bytes(c.subject, cur.issuer) and signed_by(cur, c):
                next = c
                break
        if next == nil:
            return "no trusted issuer for " .. (cur.cn ?? "?")
        if not next.ca:
            return "an intermediate is not a CA"
        if next.path_len >= 0 and depth > next.path_len:
            return "path length exceeded"
        cur = next
    return "chain too long"
