# bn: unsigned big integers and RSA private-key operations (CRT, Montgomery multiplication), written in Sprint.
#
# A number is an array of `k` limbs of 24 bits, least significant first (a product of two limbs fits in 48 bits, so sums of many stay
# far below Sprint's 63-bit ints). Only what signing needs: conversion from / to big-endian bytes, compare, add, subtract, reduce,
# Montgomery multiply, modular exponentiation and the RSA CRT private operation.

const BITS = 24
const BASE = 1 << 24
const MASK = BASE - 1

export func zeros(k):
    let a = []
    for i in range(k):
        a.append(0)
    return a

# big-endian bytes -> k limbs
export func from_be(bytes, k):
    let a = zeros(k)
    let acc = 0
    let nb = 0
    let idx = 0
    let i = len(bytes) - 1
    while i >= 0:
        acc = acc | (bytes[i] << nb)
        nb += 8
        if nb >= BITS:
            a[idx] = acc & MASK
            idx += 1
            acc = acc >> BITS
            nb -= BITS
        i -= 1
    if nb > 0 and idx < k:
        a[idx] = acc
    return a

# k limbs -> `n` big-endian bytes
export func to_be(a, n):
    let out = []
    let acc = 0
    let nb = 0
    let idx = 0
    while len(out) < n:
        if nb < 8:
            let limb = a[idx] if idx < len(a) else 0
            idx += 1
            acc = acc | (limb << nb)
            nb += BITS
        out.append(acc & 255)
        acc = acc >> 8
        nb -= 8
    let rev = []
    let j = len(out) - 1
    while j >= 0:
        rev.append(out[j])
        j -= 1
    return rev

export func cmp(a, b):
    let i = len(a) - 1
    while i >= 0:
        if a[i] != b[i]:
            return 1 if a[i] > b[i] else -1
        i -= 1
    return 0

export func is_zero(a):
    for x in a:
        if x != 0:
            return false
    return true

# a -= b (a >= b)
func sub_in(a, b):
    let borrow = 0
    for i in range(len(a)):
        let v = a[i] - b[i] - borrow
        if v < 0:
            v += BASE
            borrow = 1
        else:
            borrow = 0
        a[i] = v

# a += b (same length, the final carry is returned)
func add_in(a, b):
    let carry = 0
    for i in range(len(a)):
        let v = a[i] + b[i] + carry
        a[i] = v & MASK
        carry = v >> BITS
    return carry

# x (any number of limbs) mod n (k limbs), bit by bit
export func reduce(x, n):
    let k = len(n)
    let r = zeros(k)
    let i = len(x) * BITS - 1
    while i >= 0:
        # r = 2r + bit i
        let carry = (x[i // BITS] >> (i % BITS)) & 1
        for j in range(k):
            let v = (r[j] << 1) | carry
            r[j] = v & MASK
            carry = v >> BITS
        if carry == 1 or cmp(r, n) >= 0:
            sub_in(r, n)
        i -= 1
    return r

# -n^-1 mod 2^24 (n odd)
func neg_inv(n0):
    let x = n0
    for i in range(5):
        let t = (n0 * x) & MASK
        x = (x * ((2 - t) & MASK)) & MASK
    return (BASE - x) & MASK

# the Montgomery context of an odd modulus n (k limbs): R = 2^(24k)
export func ctx(n):
    let k = len(n)
    # R^2 mod n by doubling 1, 2 * 24k times
    let r = zeros(k)
    r[0] = 1
    if cmp(r, n) >= 0:
        sub_in(r, n)
    for i in range(2 * BITS * k):
        let carry = 0
        for j in range(k):
            let v = (r[j] << 1) | carry
            r[j] = v & MASK
            carry = v >> BITS
        if carry == 1 or cmp(r, n) >= 0:
            sub_in(r, n)
    return {n: n, k: k, ninv: neg_inv(n[0]), r2: r}

# a * b * R^-1 mod n (CIOS)
export func mont_mul(a, b, c):
    let n = c.n
    let k = c.k
    let ninv = c.ninv
    let t = zeros(k + 2)
    for i in range(k):
        let bi = b[i]
        let carry = 0
        for j in range(k):
            let v = t[j] + a[j] * bi + carry
            t[j] = v & MASK
            carry = v >> BITS
        let v = t[k] + carry
        t[k] = v & MASK
        t[k + 1] = v >> BITS
        let m = (t[0] * ninv) & MASK
        carry = (t[0] + m * n[0]) >> BITS
        for j in range(1, k):
            let w = t[j] + m * n[j] + carry
            t[j - 1] = w & MASK
            carry = w >> BITS
        let w = t[k] + carry
        t[k - 1] = w & MASK
        t[k] = t[k + 1] + (w >> BITS)
        t[k + 1] = 0
    let r = []
    for j in range(k):
        r.append(t[j])
    if t[k] != 0 or cmp(r, n) >= 0:
        sub_in(r, n)
    return r

# base^exp mod n; base < n, exp = k-limb number; binary left-to-right
export func mod_exp(base, exp, c):
    let k = c.k
    let one = zeros(k)
    one[0] = 1
    let bm = mont_mul(base, c.r2, c)       # base in Montgomery form
    let acc = mont_mul(one, c.r2, c)       # 1 in Montgomery form
    let i = len(exp) * BITS - 1
    while i >= 0 and ((exp[i // BITS] >> (i % BITS)) & 1) == 0:
        i -= 1
    while i >= 0:
        acc = mont_mul(acc, acc, c)
        if ((exp[i // BITS] >> (i % BITS)) & 1) == 1:
            acc = mont_mul(acc, bm, c)
        i -= 1
    return mont_mul(acc, one, c)           # out of Montgomery form

# a * b (full product, len(a) + len(b) limbs)
func mul_full(a, b):
    let r = zeros(len(a) + len(b))
    for i in range(len(a)):
        let carry = 0
        for j in range(len(b)):
            let v = r[i + j] + a[i] * b[j] + carry
            r[i + j] = v & MASK
            carry = v >> BITS
        r[i + len(b)] = r[i + len(b)] + carry
    return r

# the RSA private operation x^d mod n through the Chinese remainder theorem. key = {p, q, dp, dq, qinv} as big-endian byte arrays
export func rsa_private(x_bytes, key, nbytes):
    let hk = (nbytes // 2 * 8 + BITS - 1) // BITS + 1          # limbs of a half-size number (one spare)
    let p = from_be(key.p, hk)
    let q = from_be(key.q, hk)
    let dp = from_be(key.dp, hk)
    let dq = from_be(key.dq, hk)
    let qinv = from_be(key.qinv, hk)
    let xl = from_be(x_bytes, (nbytes * 8 + BITS - 1) // BITS)
    let cp = ctx(p)
    let cq = ctx(q)
    let m1 = mod_exp(reduce(xl, p), dp, cp)
    let m2 = mod_exp(reduce(xl, q), dq, cq)
    # h = qinv * (m1 - m2) mod p
    let m2p = reduce(m2, p)
    let diff = []
    for v in m1:
        diff.append(v)
    if cmp(diff, m2p) < 0:
        add_in(diff, p)
    sub_in(diff, m2p)
    let qinv_m = mont_mul(qinv, cp.r2, cp)     # qinv * R
    let h = mont_mul(qinv_m, diff, cp)         # qinv * diff
    # m = m2 + h * q
    let hq = mul_full(h, q)
    let carry = 0
    for i in range(len(hq)):
        let v = hq[i] + (m2[i] if i < len(m2) else 0) + carry
        hq[i] = v & MASK
        carry = v >> BITS
    return to_be(hq, nbytes)

# x^e mod n for a small exponent e (verification); n and x are big-endian byte arrays
export func rsa_public(x_bytes, e, n_bytes):
    let k = (len(n_bytes) * 8 + BITS - 1) // BITS
    let n = from_be(n_bytes, k)
    let c = ctx(n)
    let ex = zeros(k)
    ex[0] = e & MASK
    ex[1] = e >> BITS
    return to_be(mod_exp(from_be(x_bytes, k), ex, c), len(n_bytes))

# ---- key generation ---------------------------------------------------------------------------------------------------
# `rng(n)` must return n cryptographically strong random bytes (random.bytes).

func mul_small(a, m):                      # a * m (m < 2^24) into len(a) + 1 limbs
    let r = []
    let carry = 0
    for i in range(len(a)):
        let v = a[i] * m + carry
        r.append(v & MASK)
        carry = v >> BITS
    r.append(carry)
    return r

func mod_small(a, m):                      # a mod m for a small m
    let r = 0
    let i = len(a) - 1
    while i >= 0:
        r = ((r << BITS) | a[i]) % m
        i -= 1
    return r

func div_small(a, m):                      # a / m (exact or truncated), same length
    let q = zeros(len(a))
    let r = 0
    let i = len(a) - 1
    while i >= 0:
        let v = (r << BITS) | a[i]
        q[i] = v // m
        r = v % m
        i -= 1
    return q

func trim(a):                              # drop high zero limbs (keeps at least one)
    let n = len(a)
    while n > 1 and a[n - 1] == 0:
        n -= 1
    let r = []
    for i in range(n):
        r.append(a[i])
    return r

func pad(a, k):
    let r = []
    for i in range(k):
        r.append(a[i] if i < len(a) else 0)
    return r

func bit_length(a):
    let i = len(a) - 1
    while i >= 0 and a[i] == 0:
        i -= 1
    if i < 0:
        return 0
    let b = 0
    let v = a[i]
    while v > 0:
        b += 1
        v = v >> 1
    return i * BITS + b

func sub_small(a, m):                      # a - m (a >= m)
    let r = []
    for v in a:
        r.append(v)
    let borrow = m
    let i = 0
    while borrow > 0 and i < len(r):
        let v = r[i] - (borrow & MASK)
        borrow = borrow >> BITS
        if v < 0:
            v += BASE
            borrow += 1
        r[i] = v
        i += 1
    return r

func small_primes():
    let ps = []
    let sieve = []
    for i in range(2000):
        sieve.append(true)
    for i in range(2, 2000):
        if sieve[i]:
            ps.append(i)
            let j = i * i
            while j < 2000:
                sieve[j] = false
                j += i
    return ps

let SMALL_PRIMES = small_primes()

# a random number of exactly `bits` bits, the two top bits and the lowest bit set
func random_candidate(bits, rng):
    let nbytes = (bits + 7) // 8
    let b = rng(nbytes)
    let bytes = []
    for i in range(nbytes):
        bytes.append(b[i])
    let extra = nbytes * 8 - bits
    bytes[0] = bytes[0] & (255 >> extra)
    bytes[0] = bytes[0] | (0x80 >> extra)
    if bits >= 2:
        if extra < 7:
            bytes[0] = bytes[0] | (0x40 >> extra)
        else:
            bytes[1] = bytes[1] | 0x80
    bytes[nbytes - 1] = bytes[nbytes - 1] | 1
    return bytes

export func is_prime(n, rounds, rng):
    for p in SMALL_PRIMES:
        if mod_small(n, p) == 0:
            return bit_length(n) <= 11 and false or (len(n) == 1 and n[0] == p)
    let k = len(n)
    let c = ctx(n)
    let nm1 = sub_small(n, 1)
    # n - 1 = d * 2^s
    let s = 0
    let d = []
    for v in nm1:
        d.append(v)
    while (d[0] & 1) == 0:
        let carry = 0
        let i = len(d) - 1
        while i >= 0:
            let v = d[i]
            d[i] = (v >> 1) | (carry << (BITS - 1))
            carry = v & 1
            i -= 1
        s += 1
    let nbits = bit_length(n)
    let one = zeros(k)
    one[0] = 1
    for r in range(rounds):
        # a random base in [2, n - 2]
        let a = []
        while true:
            let rb = rng((nbits + 7) // 8)
            let bytes = []
            for i in range(len(rb)):
                bytes.append(rb[i])
            a = from_be(bytes, k)
            a = reduce(a, n)
            if cmp(a, one) > 0 and cmp(a, nm1) < 0:
                break
        let x = mod_exp(a, d, c)
        if cmp(x, one) == 0 or cmp(x, nm1) == 0:
            continue
        let composite = true
        for i in range(s - 1):
            x = mont_mul(mont_mul(x, x, c), c.r2, c)
            if cmp(x, nm1) == 0:
                composite = false
                break
        if composite:
            return false
    return true

export func random_prime(bits, rng, rounds = 24):
    let k = (bits + BITS - 1) // BITS + 1
    while true:
        let n = from_be(random_candidate(bits, rng), k)
        if is_prime(n, rounds, rng):
            return n

func ext_gcd_inv(a, m):                    # a^-1 mod m for small ints (m prime)
    let r0 = m
    let r1 = a % m
    let t0 = 0
    let t1 = 1
    while r1 != 0:
        let q = r0 // r1
        let r2 = r0 - q * r1
        r0 = r1
        r1 = r2
        let t2 = t0 - q * t1
        t0 = t1
        t1 = t2
    return t0 % m

# an RSA key of `bits` bits (public exponent 65537): {n, e, d, p, q, dp, dq, qinv} as big-endian byte arrays
export func rsa_generate(bits, rng):
    let e = 65537
    let half = bits // 2
    let k = (bits + BITS - 1) // BITS + 2
    let p = []
    let q = []
    while true:
        p = random_prime(half, rng)
        if mod_small(sub_small(p, 1), e) != 0:
            break
    while true:
        q = random_prime(bits - half, rng)
        if cmp(pad(p, k), pad(q, k)) != 0 and mod_small(sub_small(q, 1), e) != 0:
            break
    let pm1 = sub_small(p, 1)
    let qm1 = sub_small(q, 1)
    let phi = trim(mul_full(pad(pm1, k), pad(qm1, k)))
    let n = trim(mul_full(pad(p, k), pad(q, k)))
    # d = (1 + t * phi) / e with t = -phi^-1 mod e
    let r = mod_small(phi, e)
    let t = (e - ext_gcd_inv(r, e)) % e
    let numer = mul_small(pad(phi, len(phi) + 1), t)
    numer = add_small_to(numer, 1)
    let d = trim(div_small(numer, e))
    let pk = len(p)
    let dp = reduce(pad(d, k), pad(pm1, len(pad(d, k))))
    let dq = reduce(pad(d, k), pad(qm1, len(pad(d, k))))
    # q^-1 mod p = q^(p-2) mod p
    let cp = ctx(pad(p, pk))
    let pm2 = sub_small(pad(p, pk), 2)
    let qinv = mod_exp(reduce(pad(q, k), pad(p, pk)), pm2, cp)
    func bytes_of(a):
        let b = to_be(a, len(a) * 3)
        let lo = 0
        while lo < len(b) - 1 and b[lo] == 0:
            lo += 1
        let out = []
        for i in range(lo, len(b)):
            out.append(b[i])
        return out
    return {n: bytes_of(n), e: [1, 0, 1], d: bytes_of(d), p: bytes_of(p), q: bytes_of(q), dp: bytes_of(dp), dq: bytes_of(dq), qinv: bytes_of(qinv)}

func add_small_to(a, v):
    let r = []
    for x in a:
        r.append(x)
    let i = 0
    let carry = v
    while carry > 0 and i < len(r):
        let s = r[i] + carry
        r[i] = s & MASK
        carry = s >> BITS
        i += 1
    return r
