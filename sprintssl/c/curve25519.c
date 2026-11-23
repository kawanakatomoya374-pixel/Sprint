/* X25519 (RFC 7748) and Ed25519 (RFC 8032) on the 16 x 16-bit limb field arithmetic of TweetNaCl */
#include <string.h>
#include "sslcore.h"

typedef int64_t gf[16];
static const gf gf0 = {0}, gf1 = {1}, C121665 = {0xDB41, 1};
static const gf D = {0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203};
static const gf D2 = {0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406};
static const gf X = {0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169};
static const gf Y = {0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666};
static const gf I = {0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83};
static const uint8_t ELL[32] = {0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10};

static void set25519(gf r, const gf a) { memcpy(r, a, sizeof(gf)); }
static void car25519(gf o) {
    for (int i = 0; i < 16; i++) {
        o[i] += (int64_t)1 << 16;
        int64_t c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        o[i] -= c * ((int64_t)1 << 16);
    }
}
static void sel25519(gf p, gf q, int64_t b) {
    int64_t c = ~(b - 1);
    for (int i = 0; i < 16; i++) {
        int64_t t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}
static void pack25519(uint8_t *o, const gf n) {
    gf m, t;
    set25519(t, n);
    car25519(t); car25519(t); car25519(t);
    for (int j = 0; j < 2; j++) {
        m[0] = t[0] - 0xffed;
        for (int i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        int64_t b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        sel25519(t, m, 1 - b);
    }
    for (int i = 0; i < 16; i++) {
        o[2 * i] = (uint8_t)(t[i] & 0xff);
        o[2 * i + 1] = (uint8_t)(t[i] >> 8);
    }
}
static int neq25519(const gf a, const gf b) {
    uint8_t c[32], d[32];
    pack25519(c, a);
    pack25519(d, b);
    uint8_t x = 0;
    for (int i = 0; i < 32; i++) x |= (uint8_t)(c[i] ^ d[i]);
    return x != 0;
}
static uint8_t par25519(const gf a) {
    uint8_t d[32];
    pack25519(d, a);
    return d[0] & 1;
}
static void unpack25519(gf o, const uint8_t *n) {
    for (int i = 0; i < 16; i++) o[i] = n[2 * i] + ((int64_t)n[2 * i + 1] << 8);
    o[15] &= 0x7fff;
}
static void fadd(gf o, const gf a, const gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] + b[i]; }
static void fsub(gf o, const gf a, const gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] - b[i]; }
static void fmul(gf o, const gf a, const gf b) {
    int64_t t[31] = {0};
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
    for (int i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
    for (int i = 0; i < 16; i++) o[i] = t[i];
    car25519(o);
    car25519(o);
}
static void fsq(gf o, const gf a) { fmul(o, a, a); }
static void inv25519(gf o, const gf i) {
    gf c;
    set25519(c, i);
    for (int a = 253; a >= 0; a--) {
        fsq(c, c);
        if (a != 2 && a != 4) fmul(c, c, i);
    }
    set25519(o, c);
}
static void pow2523(gf o, const gf i) {
    gf c;
    set25519(c, i);
    for (int a = 250; a >= 0; a--) {
        fsq(c, c);
        if (a != 1) fmul(c, c, i);
    }
    set25519(o, c);
}

void ssl_x25519(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]) {
    uint8_t z[32];
    int64_t x[80];
    gf a, b, c, d, e, f;
    memcpy(z, scalar, 32);
    z[31] = (uint8_t)((z[31] & 127) | 64);
    z[0] &= 248;
    unpack25519(x, point);
    for (int i = 0; i < 16; i++) {
        b[i] = x[i];
        d[i] = a[i] = c[i] = 0;
    }
    a[0] = d[0] = 1;
    for (int i = 254; i >= 0; i--) {
        int64_t r = (z[i >> 3] >> (i & 7)) & 1;
        sel25519(a, b, r);
        sel25519(c, d, r);
        fadd(e, a, c); fsub(a, a, c); fadd(c, b, d); fsub(b, b, d);
        fsq(d, e); fsq(f, a); fmul(a, c, a); fmul(c, b, e);
        fadd(e, a, c); fsub(a, a, c); fsq(b, a); fsub(c, d, f);
        fmul(a, c, C121665); fadd(a, a, d); fmul(c, c, a); fmul(a, d, f);
        fmul(d, b, x); fsq(b, e);
        sel25519(a, b, r);
        sel25519(c, d, r);
    }
    for (int i = 0; i < 16; i++) {
        x[i + 16] = a[i];
        x[i + 32] = c[i];
        x[i + 48] = b[i];
        x[i + 64] = d[i];
    }
    inv25519(x + 32, x + 32);
    fmul(x + 16, x + 16, x + 32);
    pack25519(out, x + 16);
}
void ssl_x25519_base(uint8_t out[32], const uint8_t scalar[32]) {
    uint8_t nine[32] = {9};
    ssl_x25519(out, scalar, nine);
}

/* ---- Ed25519 ---- */
static void eadd(gf p[4], gf q[4]) {
    gf a, b, c, d, t, e, f, g, h;
    fsub(a, p[1], p[0]); fsub(t, q[1], q[0]); fmul(a, a, t);
    fadd(b, p[0], p[1]); fadd(t, q[0], q[1]); fmul(b, b, t);
    fmul(c, p[3], q[3]); fmul(c, c, D2);
    fmul(d, p[2], q[2]); fadd(d, d, d);
    fsub(e, b, a); fsub(f, d, c); fadd(g, d, c); fadd(h, b, a);
    fmul(p[0], e, f); fmul(p[1], h, g); fmul(p[2], g, f); fmul(p[3], e, h);
}
static void cswap(gf p[4], gf q[4], uint8_t b) {
    for (int i = 0; i < 4; i++) sel25519(p[i], q[i], b);
}
static void epack(uint8_t *r, gf p[4]) {
    gf tx, ty, zi;
    inv25519(zi, p[2]);
    fmul(tx, p[0], zi);
    fmul(ty, p[1], zi);
    pack25519(r, ty);
    r[31] ^= (uint8_t)(par25519(tx) << 7);
}
static void scalarmult(gf p[4], gf q[4], const uint8_t *s) {
    set25519(p[0], gf0); set25519(p[1], gf1); set25519(p[2], gf1); set25519(p[3], gf0);
    for (int i = 255; i >= 0; i--) {
        uint8_t b = (uint8_t)((s[i / 8] >> (i & 7)) & 1);
        cswap(p, q, b);
        eadd(q, p);
        eadd(p, p);
        cswap(p, q, b);
    }
}
static void scalarbase(gf p[4], const uint8_t *s) {
    gf q[4];
    set25519(q[0], X); set25519(q[1], Y); set25519(q[2], gf1); fmul(q[3], X, Y);
    scalarmult(p, q, s);
}
static void modL(uint8_t *r, int64_t x[64]) {
    int64_t carry;
    for (int i = 63; i >= 32; i--) {
        carry = 0;
        for (int j = i - 32; j < i - 12; j++) {
            x[j] += carry - 16 * x[i] * ELL[j - (i - 32)];
            carry = (x[j] + 128) >> 8;
            x[j] -= carry * 256;
        }
        x[i - 12] += carry;
        x[i] = 0;
    }
    carry = 0;
    for (int j = 0; j < 32; j++) {
        x[j] += carry - (x[31] >> 4) * ELL[j];
        carry = x[j] >> 8;
        x[j] &= 255;
    }
    for (int j = 0; j < 32; j++) x[j] -= carry * ELL[j];
    for (int i = 0; i < 32; i++) {
        x[i + 1] += x[i] >> 8;
        r[i] = (uint8_t)(x[i] & 255);
    }
}
static void reduce64(uint8_t r[64]) {
    int64_t x[64];
    for (int i = 0; i < 64; i++) x[i] = r[i];
    for (int i = 0; i < 64; i++) r[i] = 0;
    modL(r, x);
}
static void sha512_3(uint8_t out[64], const uint8_t *a, size_t al, const uint8_t *b, size_t bl, const uint8_t *c, size_t cl) {
    ssl_sha512_ctx h;
    ssl_sha512_init(&h, 0);
    ssl_sha512_update(&h, a, al);
    ssl_sha512_update(&h, b, bl);
    ssl_sha512_update(&h, c, cl);
    ssl_sha512_final(&h, out);
}

void ssl_ed25519_pub(uint8_t pub[32], const uint8_t seed[32]) {
    uint8_t d[64];
    gf p[4];
    ssl_hash(512, seed, 32, d);
    d[0] &= 248; d[31] &= 127; d[31] |= 64;
    scalarbase(p, d);
    epack(pub, p);
}
void ssl_ed25519_sign(uint8_t sig[64], const uint8_t *msg, size_t n, const uint8_t seed[32]) {
    uint8_t d[64], pub[32], r[64], h[64];
    gf p[4];
    ssl_hash(512, seed, 32, d);
    d[0] &= 248; d[31] &= 127; d[31] |= 64;
    scalarbase(p, d);
    epack(pub, p);
    sha512_3(r, d + 32, 32, msg, n, msg, 0);
    reduce64(r);
    scalarbase(p, r);
    epack(sig, p);
    sha512_3(h, sig, 32, pub, 32, msg, n);
    reduce64(h);
    int64_t x[64] = {0};
    for (int i = 0; i < 32; i++) x[i] = r[i];
    for (int i = 0; i < 32; i++)
        for (int j = 0; j < 32; j++) x[i + j] += (int64_t)h[i] * d[j];
    modL(sig + 32, x);
}
static int unpackneg(gf r[4], const uint8_t p[32]) {
    gf t, chk, num, den, den2, den4, den6;
    set25519(r[2], gf1);
    unpack25519(r[1], p);
    fsq(num, r[1]); fmul(den, num, D); fsub(num, num, r[2]); fadd(den, r[2], den);
    fsq(den2, den); fsq(den4, den2); fmul(den6, den4, den2);
    fmul(t, den6, num); fmul(t, t, den);
    pow2523(t, t);
    fmul(t, t, num); fmul(t, t, den); fmul(t, t, den); fmul(r[0], t, den);
    fsq(chk, r[0]); fmul(chk, chk, den);
    if (neq25519(chk, num)) fmul(r[0], r[0], I);
    fsq(chk, r[0]); fmul(chk, chk, den);
    if (neq25519(chk, num)) return -1;
    if (par25519(r[0]) == (p[31] >> 7)) fsub(r[0], gf0, r[0]);
    fmul(r[3], r[0], r[1]);
    return 0;
}
int ssl_ed25519_verify(const uint8_t sig[64], const uint8_t *msg, size_t n, const uint8_t pub[32]) {
    uint8_t t[32], h[64];
    gf p[4], q[4];
    /* S must be below the group order (RFC 8032 5.1.7) */
    int lt = 0;
    for (int i = 31; i >= 0; i--) {
        if (sig[32 + i] < ELL[i]) { lt = 1; break; }
        if (sig[32 + i] > ELL[i]) break;
    }
    if (!lt) return -1;
    if (unpackneg(q, pub)) return -1;
    sha512_3(h, sig, 32, pub, 32, msg, n);
    reduce64(h);
    scalarmult(p, q, h);
    scalarbase(q, sig + 32);
    eadd(p, q);
    epack(t, p);
    uint8_t d = 0;
    for (int i = 0; i < 32; i++) d |= (uint8_t)(t[i] ^ sig[i]);
    return d ? -1 : 0;
}
