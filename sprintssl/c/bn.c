/* Big numbers (32-bit limbs, Montgomery multiplication), RSA public operations, and the NIST curves P-256 and P-384 (ECDSA verification, ECDH).
 * Everything here is variable time: fine for verification (the inputs are public); for ECDH with a fresh private key per connection it is a known limitation. */
#include <string.h>
#include "sslcore.h"

#define MAXL 130
typedef struct {
    size_t n;
    uint32_t m[MAXL];
    uint32_t rr[MAXL];
    uint32_t n0;
} mont;

static int bn_load(uint32_t *r, size_t n, const uint8_t *b, size_t len) {
    while (len > 0 && *b == 0) { b++; len--; }
    if (len > 4 * n) return -1;
    memset(r, 0, n * 4);
    for (size_t i = 0; i < len; i++) r[i / 4] |= (uint32_t)b[len - 1 - i] << (8 * (i % 4));
    return 0;
}
static void bn_store(uint8_t *out, size_t len, const uint32_t *a) {
    for (size_t i = 0; i < len; i++) out[len - 1 - i] = (uint8_t)(a[i / 4] >> (8 * (i % 4)));
}
static int bn_cmp(const uint32_t *a, const uint32_t *b, size_t n) {
    for (size_t i = n; i-- > 0;)
        if (a[i] != b[i]) return a[i] > b[i] ? 1 : -1;
    return 0;
}
static uint32_t bn_sub(uint32_t *r, const uint32_t *a, const uint32_t *b, size_t n) {
    uint64_t br = 0;
    for (size_t i = 0; i < n; i++) {
        uint64_t x = (uint64_t)a[i] - b[i] - br;
        r[i] = (uint32_t)x;
        br = (x >> 32) & 1;
    }
    return (uint32_t)br;
}
static uint32_t bn_add(uint32_t *r, const uint32_t *a, const uint32_t *b, size_t n) {
    uint64_t c = 0;
    for (size_t i = 0; i < n; i++) {
        uint64_t x = (uint64_t)a[i] + b[i] + c;
        r[i] = (uint32_t)x;
        c = x >> 32;
    }
    return (uint32_t)c;
}
static int bn_iszero(const uint32_t *a, size_t n) {
    uint32_t x = 0;
    for (size_t i = 0; i < n; i++) x |= a[i];
    return x == 0;
}

static int mont_init(mont *mt, const uint8_t *mod, size_t len) {
    while (len > 0 && *mod == 0) { mod++; len--; }
    if (len == 0 || (mod[len - 1] & 1) == 0) return -1;
    size_t n = (len + 3) / 4;
    if (n > 128) return -1;
    mt->n = n;
    memset(mt->m, 0, sizeof mt->m);
    bn_load(mt->m, n, mod, len);
    uint32_t inv = mt->m[0];
    for (int i = 0; i < 5; i++) inv *= 2 - mt->m[0] * inv;
    mt->n0 = 0 - inv;
    /* rr = 2^(64 n) mod m, by doubling 1 that many times */
    uint32_t x[MAXL] = {0};
    x[0] = 1;
    for (size_t i = 0; i < 64 * n; i++) {
        uint32_t c = bn_add(x, x, x, n);
        if (c || bn_cmp(x, mt->m, n) >= 0) bn_sub(x, x, mt->m, n);
    }
    memset(mt->rr, 0, sizeof mt->rr);
    memcpy(mt->rr, x, n * 4);
    return 0;
}
static void mmul(const mont *mt, uint32_t *r, const uint32_t *a, const uint32_t *b) {
    size_t n = mt->n;
    uint32_t t[MAXL + 2] = {0};
    for (size_t i = 0; i < n; i++) {
        uint64_t c = 0, x;
        for (size_t j = 0; j < n; j++) {
            x = (uint64_t)t[j] + (uint64_t)a[j] * b[i] + c;
            t[j] = (uint32_t)x;
            c = x >> 32;
        }
        x = (uint64_t)t[n] + c;
        t[n] = (uint32_t)x;
        t[n + 1] = (uint32_t)(x >> 32);
        uint32_t m = t[0] * mt->n0;
        x = (uint64_t)t[0] + (uint64_t)m * mt->m[0];
        c = x >> 32;
        for (size_t j = 1; j < n; j++) {
            x = (uint64_t)t[j] + (uint64_t)m * mt->m[j] + c;
            t[j - 1] = (uint32_t)x;
            c = x >> 32;
        }
        x = (uint64_t)t[n] + c;
        t[n - 1] = (uint32_t)x;
        t[n] = t[n + 1] + (uint32_t)(x >> 32);
    }
    if (t[n] || bn_cmp(t, mt->m, n) >= 0) bn_sub(t, t, mt->m, n);
    memcpy(r, t, n * 4);
}
static void to_mont(const mont *mt, uint32_t *r, const uint32_t *a) { mmul(mt, r, a, mt->rr); }
static void from_mont(const mont *mt, uint32_t *r, const uint32_t *a) {
    uint32_t one[MAXL] = {0};
    one[0] = 1;
    mmul(mt, r, a, one);
}
/* r = a^e in the Montgomery domain; e is big-endian bytes */
static void mexp(const mont *mt, uint32_t *r, const uint32_t *a, const uint8_t *e, size_t el) {
    uint32_t acc[MAXL], one[MAXL] = {0};
    one[0] = 1;
    to_mont(mt, acc, one);
    for (size_t i = 0; i < el; i++)
        for (int b = 7; b >= 0; b--) {
            mmul(mt, acc, acc, acc);
            if ((e[i] >> b) & 1) mmul(mt, acc, acc, a);
        }
    memcpy(r, acc, mt->n * 4);
}

int ssl_rsa_public(const uint8_t *n, size_t nl, const uint8_t *e, size_t el, const uint8_t *in, size_t il, uint8_t *out) {
    mont mt;
    if (mont_init(&mt, n, nl)) return -1;
    uint32_t s[MAXL], sm[MAXL], r[MAXL];
    if (bn_load(s, mt.n, in, il) || bn_cmp(s, mt.m, mt.n) >= 0) return -1;
    to_mont(&mt, sm, s);
    mexp(&mt, r, sm, e, el);
    from_mont(&mt, r, r);
    bn_store(out, nl, r);
    return 0;
}

/* ---- elliptic curves y^2 = x^3 - 3x + b ---- */
typedef struct {
    size_t bytes, n;
    mont f, o;               /* arithmetic modulo p and modulo the group order */
    uint32_t b[12], gx[12], gy[12];     /* b, G in the p-Montgomery domain */
    uint8_t pm2[48], nm2[48];
    uint8_t nb[48];
} curve;
typedef struct {
    uint32_t x[12], y[12], z[12];       /* Jacobian, Montgomery domain; z = 0 is infinity */
} jpt;

static const char *P256_P = "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff";
static const char *P256_B = "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b";
static const char *P256_N = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551";
static const char *P256_GX = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296";
static const char *P256_GY = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";
static const char *P384_P = "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff";
static const char *P384_B = "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef";
static const char *P384_N = "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973";
static const char *P384_GX = "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7";
static const char *P384_GY = "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f";

static void unhex(uint8_t *out, const char *h, size_t bytes) {
    for (size_t i = 0; i < bytes; i++) {
        uint8_t v = 0;
        for (int k = 0; k < 2; k++) {
            char c = h[2 * i + (size_t)k];
            v = (uint8_t)(v * 16 + (c <= '9' ? c - '0' : c - 'a' + 10));
        }
        out[i] = v;
    }
}
static int curve_init(curve *c, int id) {
    size_t bytes = id == 256 ? 32 : id == 384 ? 48 : 0;
    if (!bytes) return -1;
    c->bytes = bytes;
    c->n = bytes / 4;
    uint8_t p[48], n[48], t[48];
    unhex(p, id == 256 ? P256_P : P384_P, bytes);
    unhex(n, id == 256 ? P256_N : P384_N, bytes);
    memcpy(c->nb, n, bytes);
    if (mont_init(&c->f, p, bytes) || mont_init(&c->o, n, bytes)) return -1;
    uint32_t v[12];
    unhex(t, id == 256 ? P256_B : P384_B, bytes); bn_load(v, c->n, t, bytes); to_mont(&c->f, c->b, v);
    unhex(t, id == 256 ? P256_GX : P384_GX, bytes); bn_load(v, c->n, t, bytes); to_mont(&c->f, c->gx, v);
    unhex(t, id == 256 ? P256_GY : P384_GY, bytes); bn_load(v, c->n, t, bytes); to_mont(&c->f, c->gy, v);
    memcpy(c->pm2, p, bytes);
    memcpy(c->nm2, n, bytes);
    c->pm2[bytes - 1] = (uint8_t)(c->pm2[bytes - 1] - 2);      /* both end in ...ff or ...51 / ...73: no borrow */
    c->nm2[bytes - 1] = (uint8_t)(c->nm2[bytes - 1] - 2);
    return 0;
}

static void fadd_(const curve *c, uint32_t *r, const uint32_t *a, const uint32_t *b) {
    uint32_t car = bn_add(r, a, b, c->n);
    if (car || bn_cmp(r, c->f.m, c->n) >= 0) bn_sub(r, r, c->f.m, c->n);
}
static void fsub_(const curve *c, uint32_t *r, const uint32_t *a, const uint32_t *b) {
    if (bn_sub(r, a, b, c->n)) bn_add(r, r, c->f.m, c->n);
}
static void fmul_(const curve *c, uint32_t *r, const uint32_t *a, const uint32_t *b) { mmul(&c->f, r, a, b); }

static int jis_inf(const curve *c, const jpt *p) { return bn_iszero(p->z, c->n); }
static void jdouble(const curve *c, jpt *r, const jpt *p) {
    if (jis_inf(c, p) || bn_iszero(p->y, c->n)) { memset(r, 0, sizeof *r); return; }
    uint32_t delta[12], gamma[12], beta[12], alpha[12], t1[12], t2[12], x3[12], y3[12], z3[12];
    fmul_(c, delta, p->z, p->z);
    fmul_(c, gamma, p->y, p->y);
    fmul_(c, beta, p->x, gamma);
    fsub_(c, t1, p->x, delta);
    fadd_(c, t2, p->x, delta);
    fmul_(c, alpha, t1, t2);
    fadd_(c, t1, alpha, alpha);
    fadd_(c, alpha, t1, alpha);                      /* 3 (x - delta)(x + delta) */
    fmul_(c, x3, alpha, alpha);
    fadd_(c, t1, beta, beta); fadd_(c, t1, t1, t1);  /* 4 beta */
    fadd_(c, t2, t1, t1);                            /* 8 beta */
    fsub_(c, x3, x3, t2);
    fadd_(c, z3, p->y, p->z);
    fmul_(c, z3, z3, z3);
    fsub_(c, z3, z3, gamma);
    fsub_(c, z3, z3, delta);
    fsub_(c, t1, t1, x3);
    fmul_(c, y3, alpha, t1);
    fmul_(c, t2, gamma, gamma);
    fadd_(c, t2, t2, t2); fadd_(c, t2, t2, t2); fadd_(c, t2, t2, t2);   /* 8 gamma^2 */
    fsub_(c, y3, y3, t2);
    memcpy(r->x, x3, c->n * 4); memcpy(r->y, y3, c->n * 4); memcpy(r->z, z3, c->n * 4);
}
static void jadd(const curve *c, jpt *r, const jpt *p, const jpt *q) {
    if (jis_inf(c, p)) { *r = *q; return; }
    if (jis_inf(c, q)) { *r = *p; return; }
    uint32_t z1z1[12], z2z2[12], u1[12], u2[12], s1[12], s2[12], h[12], rr[12], hh[12], hhh[12], v[12], x3[12], y3[12], z3[12], t[12];
    fmul_(c, z1z1, p->z, p->z);
    fmul_(c, z2z2, q->z, q->z);
    fmul_(c, u1, p->x, z2z2);
    fmul_(c, u2, q->x, z1z1);
    fmul_(c, t, q->z, z2z2); fmul_(c, s1, p->y, t);
    fmul_(c, t, p->z, z1z1); fmul_(c, s2, q->y, t);
    fsub_(c, h, u2, u1);
    fsub_(c, rr, s2, s1);
    if (bn_iszero(h, c->n)) {
        if (bn_iszero(rr, c->n)) jdouble(c, r, p);
        else memset(r, 0, sizeof *r);
        return;
    }
    fmul_(c, hh, h, h);
    fmul_(c, hhh, h, hh);
    fmul_(c, v, u1, hh);
    fmul_(c, x3, rr, rr);
    fsub_(c, x3, x3, hhh);
    fsub_(c, x3, x3, v);
    fsub_(c, x3, x3, v);
    fsub_(c, t, v, x3);
    fmul_(c, y3, rr, t);
    fmul_(c, t, s1, hhh);
    fsub_(c, y3, y3, t);
    fmul_(c, z3, p->z, q->z);
    fmul_(c, z3, z3, h);
    memcpy(r->x, x3, c->n * 4); memcpy(r->y, y3, c->n * 4); memcpy(r->z, z3, c->n * 4);
}
static void jmul(const curve *c, jpt *r, const jpt *p, const uint8_t *k, size_t kl) {
    jpt acc;
    memset(&acc, 0, sizeof acc);
    for (size_t i = 0; i < kl; i++)
        for (int b = 7; b >= 0; b--) {
            jdouble(c, &acc, &acc);
            if ((k[i] >> b) & 1) jadd(c, &acc, &acc, p);
        }
    *r = acc;
}
static void jaffine(const curve *c, uint8_t *x, uint8_t *y, const jpt *p) {
    uint32_t zi[12], z2[12], z3[12], ax[12], ay[12];
    mexp(&c->f, zi, p->z, c->pm2, c->bytes);
    fmul_(c, z2, zi, zi);
    fmul_(c, z3, z2, zi);
    fmul_(c, ax, p->x, z2);
    fmul_(c, ay, p->y, z3);
    from_mont(&c->f, ax, ax);
    from_mont(&c->f, ay, ay);
    if (x) bn_store(x, c->bytes, ax);
    if (y) bn_store(y, c->bytes, ay);
}
/* load an uncompressed point and check it is on the curve */
static int jload(const curve *c, jpt *p, const uint8_t *pub, size_t pl) {
    if (pl != 1 + 2 * c->bytes || pub[0] != 4) return -1;
    uint32_t x[12], y[12];
    if (bn_load(x, c->n, pub + 1, c->bytes) || bn_load(y, c->n, pub + 1 + c->bytes, c->bytes)) return -1;
    if (bn_cmp(x, c->f.m, c->n) >= 0 || bn_cmp(y, c->f.m, c->n) >= 0) return -1;
    to_mont(&c->f, p->x, x);
    to_mont(&c->f, p->y, y);
    memcpy(p->z, c->f.rr, c->n * 4);
    uint32_t one[12] = {1};
    to_mont(&c->f, p->z, one);
    uint32_t l[12], r[12], t[12];
    fmul_(c, l, p->y, p->y);
    fmul_(c, r, p->x, p->x);
    fmul_(c, r, r, p->x);
    fadd_(c, t, p->x, p->x);
    fadd_(c, t, t, p->x);
    fsub_(c, r, r, t);
    fadd_(c, r, r, c->b);
    return bn_cmp(l, r, c->n) == 0 ? 0 : -1;
}

int ssl_ecdsa_verify(int curve_id, const uint8_t *pub, size_t pl, const uint8_t *hash, size_t hl, const uint8_t *r, size_t rl, const uint8_t *s, size_t sl) {
    curve c;
    if (curve_init(&c, curve_id)) return -1;
    size_t n = c.n;
    jpt q, g, a, b, sum;
    if (jload(&c, &q, pub, pl)) return -1;
    uint32_t rv[12], sv[12], zv[12], w[12], sm[12], u1[12], u2[12], zm[12], rm[12];
    if (bn_load(rv, n, r, rl) || bn_load(sv, n, s, sl)) return -1;
    if (bn_iszero(rv, n) || bn_iszero(sv, n) || bn_cmp(rv, c.o.m, n) >= 0 || bn_cmp(sv, c.o.m, n) >= 0) return -1;
    if (hl > c.bytes) hl = c.bytes;                      /* the leftmost bits of the hash */
    if (bn_load(zv, n, hash, hl)) return -1;
    to_mont(&c.o, sm, sv);
    mexp(&c.o, w, sm, c.nm2, c.bytes);                   /* s^-1 (Montgomery) */
    to_mont(&c.o, zm, zv);
    to_mont(&c.o, rm, rv);
    mmul(&c.o, u1, zm, w);
    mmul(&c.o, u2, rm, w);
    from_mont(&c.o, u1, u1);
    from_mont(&c.o, u2, u2);
    uint8_t u1b[48], u2b[48];
    bn_store(u1b, c.bytes, u1);
    bn_store(u2b, c.bytes, u2);
    memcpy(g.x, c.gx, n * 4); memcpy(g.y, c.gy, n * 4);
    uint32_t one[12] = {1};
    to_mont(&c.f, g.z, one);
    jmul(&c, &a, &g, u1b, c.bytes);
    jmul(&c, &b, &q, u2b, c.bytes);
    jadd(&c, &sum, &a, &b);
    if (jis_inf(&c, &sum)) return -1;
    uint8_t x[48];
    jaffine(&c, x, NULL, &sum);
    uint32_t xv[12];
    bn_load(xv, n, x, c.bytes);
    if (bn_cmp(xv, c.o.m, n) >= 0) bn_sub(xv, xv, c.o.m, n);
    return bn_cmp(xv, rv, n) == 0 ? 0 : -1;
}

int ssl_ec_pub(int curve_id, uint8_t *out, const uint8_t *priv, size_t vl) {
    curve c;
    if (curve_init(&c, curve_id) || vl != c.bytes) return -1;
    jpt g, r;
    memcpy(g.x, c.gx, c.n * 4); memcpy(g.y, c.gy, c.n * 4);
    uint32_t one[12] = {1};
    to_mont(&c.f, g.z, one);
    jmul(&c, &r, &g, priv, vl);
    if (jis_inf(&c, &r)) return -1;
    out[0] = 4;
    jaffine(&c, out + 1, out + 1 + c.bytes, &r);
    return 0;
}
int ssl_ecdh(int curve_id, uint8_t *out, const uint8_t *pub, size_t pl, const uint8_t *priv, size_t vl) {
    curve c;
    if (curve_init(&c, curve_id) || vl != c.bytes) return -1;
    jpt q, r;
    if (jload(&c, &q, pub, pl)) return -1;
    jmul(&c, &r, &q, priv, vl);
    if (jis_inf(&c, &r)) return -1;
    jaffine(&c, out, NULL, &r);
    return 0;
}
