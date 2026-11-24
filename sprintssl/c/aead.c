/* AES-128/256 (encryption only), GCM (SP 800-38D), ChaCha20 and Poly1305 (RFC 8439) */
#include <string.h>
#include "sslcore.h"

/* ---- AES ---- */
static uint8_t SBOX[256];
static int sbox_ready;
static uint8_t xtime(uint8_t x) { return (uint8_t)((x << 1) ^ ((x >> 7) * 0x1b)); }
static void sbox_init(void) {
    uint8_t p = 1, q = 1;
    do {
        p = (uint8_t)(p ^ (uint8_t)(p << 1) ^ ((p & 0x80) ? 0x1b : 0)); /* p * 3 */
        q = (uint8_t)(q ^ (q << 1)); q = (uint8_t)(q ^ (q << 2)); q = (uint8_t)(q ^ (q << 4));
        if (q & 0x80) q ^= 0x09;                                          /* q / 3 */
        uint8_t x = (uint8_t)(q ^ (uint8_t)((q << 1) | (q >> 7)) ^ (uint8_t)((q << 2) | (q >> 6)) ^ (uint8_t)((q << 3) | (q >> 5)) ^ (uint8_t)((q << 4) | (q >> 4)));
        SBOX[p] = (uint8_t)(x ^ 0x63);
    } while (p != 1);
    SBOX[0] = 0x63;
    sbox_ready = 1;
}

typedef struct {
    uint8_t rk[15][16];
    int rounds;
} aes_key;

static int aes_setup(aes_key *k, const uint8_t *key, size_t kl) {
    if (kl != 16 && kl != 32) return -1;
    if (!sbox_ready) sbox_init();
    int nk = (int)(kl / 4);
    k->rounds = nk + 6;
    uint8_t w[60][4];
    memcpy(w, key, kl);
    uint8_t rcon = 1;
    for (int i = nk; i < 4 * (k->rounds + 1); i++) {
        uint8_t t[4];
        memcpy(t, w[i - 1], 4);
        if (i % nk == 0) {
            uint8_t a = t[0];
            t[0] = (uint8_t)(SBOX[t[1]] ^ rcon); t[1] = SBOX[t[2]]; t[2] = SBOX[t[3]]; t[3] = SBOX[a];
            rcon = xtime(rcon);
        } else if (nk > 6 && i % nk == 4) {
            for (int j = 0; j < 4; j++) t[j] = SBOX[t[j]];
        }
        for (int j = 0; j < 4; j++) w[i][j] = (uint8_t)(w[i - nk][j] ^ t[j]);
    }
    memcpy(k->rk, w, sizeof k->rk);
    return 0;
}

static void aes_encrypt(const aes_key *k, const uint8_t in[16], uint8_t out[16]) {
    uint8_t s[16];
    for (int i = 0; i < 16; i++) s[i] = (uint8_t)(in[i] ^ k->rk[0][i]);
    for (int r = 1; r <= k->rounds; r++) {
        uint8_t t[16];
        for (int c = 0; c < 4; c++)
            for (int rw = 0; rw < 4; rw++) t[4 * c + rw] = SBOX[s[4 * ((c + rw) & 3) + rw]];   /* SubBytes + ShiftRows */
        if (r != k->rounds) {
            for (int c = 0; c < 4; c++) {
                uint8_t *a = t + 4 * c;
                uint8_t x = (uint8_t)(a[0] ^ a[1] ^ a[2] ^ a[3]), a0 = a[0];
                a[0] = (uint8_t)(a[0] ^ x ^ xtime((uint8_t)(a[0] ^ a[1])));
                a[1] = (uint8_t)(a[1] ^ x ^ xtime((uint8_t)(a[1] ^ a[2])));
                a[2] = (uint8_t)(a[2] ^ x ^ xtime((uint8_t)(a[2] ^ a[3])));
                a[3] = (uint8_t)(a[3] ^ x ^ xtime((uint8_t)(a[3] ^ a0)));
            }
        }
        for (int i = 0; i < 16; i++) s[i] = (uint8_t)(t[i] ^ k->rk[r][i]);
    }
    memcpy(out, s, 16);
}

/* ---- GCM ---- */
typedef struct {
    uint64_t hi, lo;
} u128;

static u128 gmul(u128 x, u128 h) { /* bitwise multiplication in GF(2^128), x and h as big-endian bit strings */
    u128 z = {0, 0}, v = h;
    for (int i = 0; i < 128; i++) {
        uint64_t bit = i < 64 ? (x.hi >> (63 - i)) & 1 : (x.lo >> (127 - i)) & 1;
        uint64_t m = (uint64_t)0 - bit;
        z.hi ^= v.hi & m; z.lo ^= v.lo & m;
        uint64_t lsb = v.lo & 1;
        v.lo = (v.lo >> 1) | (v.hi << 63);
        v.hi = (v.hi >> 1) ^ (((uint64_t)0 - lsb) & 0xe100000000000000ULL);
    }
    return z;
}
static u128 load128(const uint8_t *p) {
    u128 r = {0, 0};
    for (int i = 0; i < 8; i++) { r.hi = (r.hi << 8) | p[i]; r.lo = (r.lo << 8) | p[8 + i]; }
    return r;
}
static void store128(u128 v, uint8_t *p) {
    for (int i = 0; i < 8; i++) { p[i] = (uint8_t)(v.hi >> (56 - 8 * i)); p[8 + i] = (uint8_t)(v.lo >> (56 - 8 * i)); }
}

static void ghash_update(u128 *y, u128 h, const uint8_t *p, size_t n) {
    while (n > 0) {
        uint8_t b[16] = {0};
        size_t k = n < 16 ? n : 16;
        memcpy(b, p, k);
        u128 x = load128(b);
        y->hi ^= x.hi; y->lo ^= x.lo;
        *y = gmul(*y, h);
        p += k; n -= k;
    }
}

static void gcm_ctr(const aes_key *k, const uint8_t j0[16], const uint8_t *in, size_t n, uint8_t *out) {
    uint8_t ctr[16], ks[16];
    memcpy(ctr, j0, 16);
    for (size_t off = 0; off < n; off += 16) {
        for (int i = 15; i >= 12; i--)
            if (++ctr[i]) break;
        aes_encrypt(k, ctr, ks);
        size_t m = n - off < 16 ? n - off : 16;
        for (size_t i = 0; i < m; i++) out[off + i] = (uint8_t)(in[off + i] ^ ks[i]);
    }
}

static void gcm_tag(const aes_key *k, const uint8_t j0[16], u128 h, const uint8_t *aad, size_t al, const uint8_t *ct, size_t n, uint8_t tag[16]) {
    u128 y = {0, 0};
    ghash_update(&y, h, aad, al);
    ghash_update(&y, h, ct, n);
    uint8_t lens[16];
    uint64_t ab = (uint64_t)al * 8, cb = (uint64_t)n * 8;
    for (int i = 0; i < 8; i++) { lens[i] = (uint8_t)(ab >> (56 - 8 * i)); lens[8 + i] = (uint8_t)(cb >> (56 - 8 * i)); }
    ghash_update(&y, h, lens, 16);
    uint8_t s[16], e[16];
    store128(y, s);
    aes_encrypt(k, j0, e);
    for (int i = 0; i < 16; i++) tag[i] = (uint8_t)(s[i] ^ e[i]);
}

int ssl_aes_gcm_seal(const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *pt, size_t n, uint8_t *out) {
#ifndef SSL_NO_ACCEL
    if (ssl_accel_aesgcm()) return ssl_accel_gcm(1, key, kl, nonce, aad, al, pt, n, out);
#endif
    aes_key k;
    if (aes_setup(&k, key, kl)) return -1;
    uint8_t zero[16] = {0}, hb[16], j0[16];
    aes_encrypt(&k, zero, hb);
    memcpy(j0, nonce, 12);
    j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
    gcm_ctr(&k, j0, pt, n, out);
    gcm_tag(&k, j0, load128(hb), aad, al, out, n, out + n);
    return 0;
}

int ssl_aes_gcm_open(const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *ct, size_t n, uint8_t *out) {
#ifndef SSL_NO_ACCEL
    if (ssl_accel_aesgcm()) return ssl_accel_gcm(0, key, kl, nonce, aad, al, ct, n, out);
#endif
    aes_key k;
    if (n < 16 || aes_setup(&k, key, kl)) return -1;
    n -= 16;
    uint8_t zero[16] = {0}, hb[16], j0[16], tag[16];
    aes_encrypt(&k, zero, hb);
    memcpy(j0, nonce, 12);
    j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
    gcm_tag(&k, j0, load128(hb), aad, al, ct, n, tag);
    uint8_t d = 0;
    for (int i = 0; i < 16; i++) d |= (uint8_t)(tag[i] ^ ct[n + (size_t)i]);
    if (d) return -1;
    gcm_ctr(&k, j0, ct, n, out);
    return 0;
}

/* ---- ChaCha20 ---- */
static uint32_t rol32(uint32_t x, unsigned n) { return (x << n) | (x >> (32u - n)); }
static uint32_t ld32le(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static void st32le(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

#define QR(a, b, c, d) a += b; d ^= a; d = rol32(d, 16); c += d; b ^= c; b = rol32(b, 12); a += b; d ^= a; d = rol32(d, 8); c += d; b ^= c; b = rol32(b, 7)
static void chacha_block(const uint8_t key[32], uint32_t ctr, const uint8_t nonce[12], uint8_t out[64]) {
    uint32_t s[16] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574}, x[16];
    for (int i = 0; i < 8; i++) s[4 + i] = ld32le(key + 4 * i);
    s[12] = ctr;
    for (int i = 0; i < 3; i++) s[13 + i] = ld32le(nonce + 4 * i);
    memcpy(x, s, sizeof x);
    for (int i = 0; i < 10; i++) {
        QR(x[0], x[4], x[8], x[12]); QR(x[1], x[5], x[9], x[13]); QR(x[2], x[6], x[10], x[14]); QR(x[3], x[7], x[11], x[15]);
        QR(x[0], x[5], x[10], x[15]); QR(x[1], x[6], x[11], x[12]); QR(x[2], x[7], x[8], x[13]); QR(x[3], x[4], x[9], x[14]);
    }
    for (int i = 0; i < 16; i++) st32le(out + 4 * i, x[i] + s[i]);
}
static void chacha_xor(const uint8_t key[32], uint32_t ctr, const uint8_t nonce[12], const uint8_t *in, size_t n, uint8_t *out) {
    uint8_t b[64];
    size_t off = 0;
#ifndef SSL_NO_ACCEL
    off = ssl_chacha_xor4(key, ctr, nonce, in, n, out);
    ctr += (uint32_t)(off / 64);
#endif
    for (; off < n; off += 64, ctr++) {
        chacha_block(key, ctr, nonce, b);
        size_t m = n - off < 64 ? n - off : 64;
        for (size_t i = 0; i < m; i++) out[off + i] = (uint8_t)(in[off + i] ^ b[i]);
    }
}

/* ---- Poly1305 (26-bit limbs) ---- */
static void poly1305(const uint8_t key[32], const uint8_t *aad, size_t al, const uint8_t *ct, size_t cl, uint8_t tag[16]) {
    uint32_t r0 = ld32le(key) & 0x3ffffff, r1 = (ld32le(key + 3) >> 2) & 0x3ffff03, r2 = (ld32le(key + 6) >> 4) & 0x3ffc0ff;
    uint32_t r3 = (ld32le(key + 9) >> 6) & 0x3f03fff, r4 = (ld32le(key + 12) >> 8) & 0x00fffff;
    uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
    uint32_t h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;
    for (int part = 0; part < 3; part++) {
        const uint8_t *p = part == 0 ? aad : ct;
        size_t n = part == 0 ? al : cl;
        uint8_t lenblk[16];
        if (part == 2) {
            uint64_t a = al, c = cl;
            for (int i = 0; i < 8; i++) { lenblk[i] = (uint8_t)(a >> (8 * i)); lenblk[8 + i] = (uint8_t)(c >> (8 * i)); }
            p = lenblk; n = 16;
        }
        while (n > 0) {
            uint8_t blk[17] = {0};
            size_t k = n < 16 ? n : 16;
            memcpy(blk, p, k);
            blk[16] = 1;                  /* the AEAD construction zero-pads both parts to 16 bytes, so every block is a full one */
            h0 += ld32le(blk) & 0x3ffffff;
            h1 += (ld32le(blk + 3) >> 2) & 0x3ffffff;
            h2 += (ld32le(blk + 6) >> 4) & 0x3ffffff;
            h3 += (ld32le(blk + 9) >> 6) & 0x3ffffff;
            h4 += (ld32le(blk + 12) >> 8) | ((uint32_t)blk[16] << 24);
            uint64_t d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3 + (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
            uint64_t d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4 + (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
            uint64_t d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0 + (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
            uint64_t d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1 + (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
            uint64_t d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2 + (uint64_t)h3 * r1 + (uint64_t)h4 * r0;
            uint32_t c = (uint32_t)(d0 >> 26); h0 = (uint32_t)d0 & 0x3ffffff;
            d1 += c; c = (uint32_t)(d1 >> 26); h1 = (uint32_t)d1 & 0x3ffffff;
            d2 += c; c = (uint32_t)(d2 >> 26); h2 = (uint32_t)d2 & 0x3ffffff;
            d3 += c; c = (uint32_t)(d3 >> 26); h3 = (uint32_t)d3 & 0x3ffffff;
            d4 += c; c = (uint32_t)(d4 >> 26); h4 = (uint32_t)d4 & 0x3ffffff;
            h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff; h1 += c;
            p += k; n -= k;
        }
    }
    uint32_t c = h1 >> 26; h1 &= 0x3ffffff; h2 += c; c = h2 >> 26; h2 &= 0x3ffffff; h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
    h4 += c; c = h4 >> 26; h4 &= 0x3ffffff; h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff; h1 += c;
    uint32_t g0 = h0 + 5, g1, g2, g3, g4;
    c = g0 >> 26; g0 &= 0x3ffffff;
    g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
    g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
    g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
    g4 = h4 + c - (1u << 26);
    uint32_t mask = (g4 >> 31) - 1;     /* all ones when h >= p */
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2; h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4;
    uint64_t f0 = (uint64_t)(h0 | (h1 << 26)) + ld32le(key + 16);
    uint64_t f1 = (uint64_t)((h1 >> 6) | (h2 << 20)) + ld32le(key + 20) + (f0 >> 32);
    uint64_t f2 = (uint64_t)((h2 >> 12) | (h3 << 14)) + ld32le(key + 24) + (f1 >> 32);
    uint64_t f3 = (uint64_t)((h3 >> 18) | (h4 << 8)) + ld32le(key + 28) + (f2 >> 32);
    st32le(tag, (uint32_t)f0); st32le(tag + 4, (uint32_t)f1); st32le(tag + 8, (uint32_t)f2); st32le(tag + 12, (uint32_t)f3);
}

static void poly_padded_tag(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t al, const uint8_t *ct, size_t n, uint8_t tag[16]) {
    uint8_t otk[64];
    chacha_block(key, 0, nonce, otk);
    poly1305(otk, aad, al, ct, n, tag);
}

void ssl_chacha_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t al, const uint8_t *pt, size_t n, uint8_t *out) {
    chacha_xor(key, 1, nonce, pt, n, out);
    poly_padded_tag(key, nonce, aad, al, out, n, out + n);
}

int ssl_chacha_open(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t al, const uint8_t *ct, size_t n, uint8_t *out) {
    if (n < 16) return -1;
    n -= 16;
    uint8_t tag[16], d = 0;
    poly_padded_tag(key, nonce, aad, al, ct, n, tag);
    for (int i = 0; i < 16; i++) d |= (uint8_t)(tag[i] ^ ct[n + (size_t)i]);
    if (d) return -1;
    chacha_xor(key, 1, nonce, ct, n, out);
    return 0;
}
