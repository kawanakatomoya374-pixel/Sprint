/* Hardware paths for AES-GCM: AES-NI for the cipher and PCLMULQDQ for GHASH, chosen at run time (CPUID); the portable code in aead.c stays the fallback.
   The GHASH multiplication follows Intel's carry-less multiplication white paper (byte-reflected operands, the reduction by x^128 + x^7 + x^2 + x + 1). */
#include <string.h>
#include "sslcore.h"

#if defined(__x86_64__) && defined(__GNUC__)
#include <immintrin.h>

#define TARGET __attribute__((target("aes,pclmul,sse4.1,ssse3")))

int ssl_accel_aesgcm(void) {
    static int state;
    if (state == 0) {
        __builtin_cpu_init();
        state = (__builtin_cpu_supports("aes") && __builtin_cpu_supports("pclmul") && __builtin_cpu_supports("sse4.1") && __builtin_cpu_supports("ssse3")) ? 1 : 2;
    }
    return state == 1;
}

typedef struct {
    __m128i rk[15];
    int rounds;
} aesni_key;

TARGET static __m128i expand128_step(__m128i k, __m128i gen) {
    gen = _mm_shuffle_epi32(gen, 0xff);
    k = _mm_xor_si128(k, _mm_slli_si128(k, 4));
    k = _mm_xor_si128(k, _mm_slli_si128(k, 4));
    k = _mm_xor_si128(k, _mm_slli_si128(k, 4));
    return _mm_xor_si128(k, gen);
}
TARGET static __m128i expand256_a(__m128i k, __m128i gen) { /* the even round keys */
    gen = _mm_shuffle_epi32(gen, 0xff);
    k = _mm_xor_si128(k, _mm_slli_si128(k, 4));
    k = _mm_xor_si128(k, _mm_slli_si128(k, 4));
    k = _mm_xor_si128(k, _mm_slli_si128(k, 4));
    return _mm_xor_si128(k, gen);
}
TARGET static __m128i expand256_b(__m128i k1, __m128i k2) { /* the odd ones: SubWord of the last word, no rotation */
    __m128i gen = _mm_aeskeygenassist_si128(k1, 0);
    gen = _mm_shuffle_epi32(gen, 0xaa);
    k2 = _mm_xor_si128(k2, _mm_slli_si128(k2, 4));
    k2 = _mm_xor_si128(k2, _mm_slli_si128(k2, 4));
    k2 = _mm_xor_si128(k2, _mm_slli_si128(k2, 4));
    return _mm_xor_si128(k2, gen);
}

TARGET static int aesni_setup(aesni_key *k, const uint8_t *key, size_t kl) {
    if (kl == 16) {
        k->rounds = 10;
        __m128i t = _mm_loadu_si128((const __m128i *)(const void *)key);
        k->rk[0] = t;
#define E128(i, rc) t = expand128_step(t, _mm_aeskeygenassist_si128(t, rc)); k->rk[i] = t;
        E128(1, 0x01) E128(2, 0x02) E128(3, 0x04) E128(4, 0x08) E128(5, 0x10) E128(6, 0x20) E128(7, 0x40) E128(8, 0x80) E128(9, 0x1b) E128(10, 0x36)
#undef E128
        return 0;
    }
    if (kl == 32) {
        k->rounds = 14;
        __m128i a = _mm_loadu_si128((const __m128i *)(const void *)key);
        __m128i b = _mm_loadu_si128((const __m128i *)(const void *)(key + 16));
        k->rk[0] = a; k->rk[1] = b;
#define E256(i, rc) a = expand256_a(a, _mm_aeskeygenassist_si128(b, rc)); k->rk[i] = a; b = expand256_b(a, b); k->rk[i + 1] = b;
        E256(2, 0x01) E256(4, 0x02) E256(6, 0x04) E256(8, 0x08) E256(10, 0x10) E256(12, 0x20)
#undef E256
        a = expand256_a(a, _mm_aeskeygenassist_si128(b, 0x40)); k->rk[14] = a;
        return 0;
    }
    return -1;
}

TARGET static __m128i aes_block(const aesni_key *k, __m128i b) {
    b = _mm_xor_si128(b, k->rk[0]);
    for (int i = 1; i < k->rounds; i++) b = _mm_aesenc_si128(b, k->rk[i]);
    return _mm_aesenclast_si128(b, k->rk[k->rounds]);
}

TARGET static __m128i bswap128(__m128i x) {
    return _mm_shuffle_epi8(x, _mm_set_epi8(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
}

/* a * b in GF(2^128), both byte-reflected */
TARGET static __m128i gfmul(__m128i a, __m128i b) {
    __m128i t3 = _mm_clmulepi64_si128(a, b, 0x00);
    __m128i t4 = _mm_clmulepi64_si128(a, b, 0x10);
    __m128i t5 = _mm_clmulepi64_si128(a, b, 0x01);
    __m128i t6 = _mm_clmulepi64_si128(a, b, 0x11);
    t4 = _mm_xor_si128(t4, t5);
    t5 = _mm_slli_si128(t4, 8);
    t4 = _mm_srli_si128(t4, 8);
    t3 = _mm_xor_si128(t3, t5);
    t6 = _mm_xor_si128(t6, t4);
    __m128i t7 = _mm_srli_epi32(t3, 31), t8 = _mm_srli_epi32(t6, 31);
    t3 = _mm_slli_epi32(t3, 1);
    t6 = _mm_slli_epi32(t6, 1);
    __m128i t9 = _mm_srli_si128(t7, 12);
    t8 = _mm_slli_si128(t8, 4);
    t7 = _mm_slli_si128(t7, 4);
    t3 = _mm_or_si128(t3, t7);
    t6 = _mm_or_si128(t6, t8);
    t6 = _mm_or_si128(t6, t9);
    t7 = _mm_slli_epi32(t3, 31);
    t8 = _mm_slli_epi32(t3, 30);
    t9 = _mm_slli_epi32(t3, 25);
    t7 = _mm_xor_si128(_mm_xor_si128(t7, t8), t9);
    t8 = _mm_srli_si128(t7, 4);
    t7 = _mm_slli_si128(t7, 12);
    t3 = _mm_xor_si128(t3, t7);
    __m128i t2 = _mm_srli_epi32(t3, 1);
    t4 = _mm_srli_epi32(t3, 2);
    t5 = _mm_srli_epi32(t3, 7);
    t2 = _mm_xor_si128(_mm_xor_si128(t2, t4), _mm_xor_si128(t5, t8));
    t3 = _mm_xor_si128(t3, t2);
    return _mm_xor_si128(t6, t3);
}

TARGET static __m128i ghash_run(__m128i y, __m128i h, const uint8_t *p, size_t n) { /* n bytes, a partial last block is zero padded */
    while (n >= 16) {
        y = gfmul(_mm_xor_si128(y, bswap128(_mm_loadu_si128((const __m128i *)(const void *)p))), h);
        p += 16; n -= 16;
    }
    if (n) {
        uint8_t last[16] = {0};
        memcpy(last, p, n);
        y = gfmul(_mm_xor_si128(y, bswap128(_mm_loadu_si128((const __m128i *)(const void *)last))), h);
    }
    return y;
}

TARGET static __m128i counter_block(__m128i base, uint32_t ctr) {
    return _mm_insert_epi32(base, (int)__builtin_bswap32(ctr), 3);
}

/* CTR with the counter starting at 2 (block 1 is the tag mask); four blocks at a time */
TARGET static void ctr_xor(const aesni_key *k, __m128i base, const uint8_t *in, size_t n, uint8_t *out) {
    uint32_t ctr = 2;
    size_t off = 0;
    while (n - off >= 64) {
        __m128i b0 = counter_block(base, ctr), b1 = counter_block(base, ctr + 1), b2 = counter_block(base, ctr + 2), b3 = counter_block(base, ctr + 3);
        ctr += 4;
        __m128i r = k->rk[0];
        b0 = _mm_xor_si128(b0, r); b1 = _mm_xor_si128(b1, r); b2 = _mm_xor_si128(b2, r); b3 = _mm_xor_si128(b3, r);
        for (int i = 1; i < k->rounds; i++) {
            r = k->rk[i];
            b0 = _mm_aesenc_si128(b0, r); b1 = _mm_aesenc_si128(b1, r); b2 = _mm_aesenc_si128(b2, r); b3 = _mm_aesenc_si128(b3, r);
        }
        r = k->rk[k->rounds];
        b0 = _mm_aesenclast_si128(b0, r); b1 = _mm_aesenclast_si128(b1, r); b2 = _mm_aesenclast_si128(b2, r); b3 = _mm_aesenclast_si128(b3, r);
        const __m128i *src = (const __m128i *)(const void *)(in + off);
        __m128i *dst = (__m128i *)(void *)(out + off);
        _mm_storeu_si128(dst, _mm_xor_si128(b0, _mm_loadu_si128(src)));
        _mm_storeu_si128(dst + 1, _mm_xor_si128(b1, _mm_loadu_si128(src + 1)));
        _mm_storeu_si128(dst + 2, _mm_xor_si128(b2, _mm_loadu_si128(src + 2)));
        _mm_storeu_si128(dst + 3, _mm_xor_si128(b3, _mm_loadu_si128(src + 3)));
        off += 64;
    }
    while (off < n) {
        uint8_t ks[16];
        _mm_storeu_si128((__m128i *)(void *)ks, aes_block(k, counter_block(base, ctr++)));
        size_t m = n - off < 16 ? n - off : 16;
        for (size_t i = 0; i < m; i++) out[off + i] = (uint8_t)(in[off + i] ^ ks[i]);
        off += 16;
    }
}


/* ChaCha20, four blocks at a time: each vector holds one state word of four consecutive blocks (SSE2 is part of x86-64, no run-time choice needed).
   Handles whole groups of 256 bytes and returns how many bytes it did. */
#define ROTL(v, c) _mm_or_si128(_mm_slli_epi32(v, c), _mm_srli_epi32(v, 32 - (c)))
#define QR4(a, b, c, d) \
    a = _mm_add_epi32(a, b); d = _mm_xor_si128(d, a); d = ROTL(d, 16); \
    c = _mm_add_epi32(c, d); b = _mm_xor_si128(b, c); b = ROTL(b, 12); \
    a = _mm_add_epi32(a, b); d = _mm_xor_si128(d, a); d = ROTL(d, 8); \
    c = _mm_add_epi32(c, d); b = _mm_xor_si128(b, c); b = ROTL(b, 7)

static uint32_t ld32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; } /* little endian host */

size_t ssl_chacha_xor4(const uint8_t key[32], uint32_t ctr, const uint8_t nonce[12], const uint8_t *in, size_t n, uint8_t *out) {
    size_t done = 0;
    uint32_t base[16] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    for (int i = 0; i < 8; i++) base[4 + i] = ld32(key + 4 * i);
    for (int i = 0; i < 3; i++) base[13 + i] = ld32(nonce + 4 * i);
    while (n - done >= 256) {
        __m128i o[16], x[16];
        for (int i = 0; i < 16; i++) o[i] = _mm_set1_epi32((int)base[i]);
        o[12] = _mm_add_epi32(_mm_set1_epi32((int)ctr), _mm_set_epi32(3, 2, 1, 0));
        for (int i = 0; i < 16; i++) x[i] = o[i];
        for (int r = 0; r < 10; r++) {
            QR4(x[0], x[4], x[8], x[12]); QR4(x[1], x[5], x[9], x[13]); QR4(x[2], x[6], x[10], x[14]); QR4(x[3], x[7], x[11], x[15]);
            QR4(x[0], x[5], x[10], x[15]); QR4(x[1], x[6], x[11], x[12]); QR4(x[2], x[7], x[8], x[13]); QR4(x[3], x[4], x[9], x[14]);
        }
        for (int i = 0; i < 16; i++) x[i] = _mm_add_epi32(x[i], o[i]);
        for (int g = 0; g < 4; g++) {
            __m128i a = x[4 * g], b = x[4 * g + 1], c = x[4 * g + 2], d = x[4 * g + 3];
            __m128i t0 = _mm_unpacklo_epi32(a, b), t1 = _mm_unpackhi_epi32(a, b), t2 = _mm_unpacklo_epi32(c, d), t3 = _mm_unpackhi_epi32(c, d);
            __m128i row[4] = {_mm_unpacklo_epi64(t0, t2), _mm_unpackhi_epi64(t0, t2), _mm_unpacklo_epi64(t1, t3), _mm_unpackhi_epi64(t1, t3)};
            for (int blk = 0; blk < 4; blk++) {
                size_t at = done + (size_t)blk * 64 + (size_t)g * 16;
                __m128i v = _mm_xor_si128(row[blk], _mm_loadu_si128((const __m128i *)(const void *)(in + at)));
                _mm_storeu_si128((__m128i *)(void *)(out + at), v);
            }
        }
        ctr += 4;
        done += 256;
    }
    return done;
}

/* SHA-256 with the SHA extensions (SHA-NI): `blocks` 64-byte blocks into the state */
int ssl_accel_sha256(void) {
    static int state;
    if (state == 0) {
        __builtin_cpu_init();
        state = (__builtin_cpu_supports("sha") && __builtin_cpu_supports("sse4.1") && __builtin_cpu_supports("ssse3")) ? 1 : 2;
    }
    return state == 1;
}

static const uint32_t SHA_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

__attribute__((target("sha,sse4.1,ssse3"))) void ssl_accel_sha256_blocks(uint32_t st[8], const uint8_t *data, size_t blocks) {
    const __m128i mask = _mm_set_epi64x(0x0c0d0e0f08090a0bLL, 0x0405060700010203LL);
    __m128i tmp = _mm_loadu_si128((const __m128i *)(const void *)&st[0]);
    __m128i s1 = _mm_loadu_si128((const __m128i *)(const void *)&st[4]);
    tmp = _mm_shuffle_epi32(tmp, 0xB1);
    s1 = _mm_shuffle_epi32(s1, 0x1B);
    __m128i s0 = _mm_alignr_epi8(tmp, s1, 8);
    s1 = _mm_blend_epi16(s1, tmp, 0xF0);
    while (blocks--) {
        __m128i save0 = s0, save1 = s1, w[16];
        for (int i = 0; i < 4; i++) w[i] = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i *)(const void *)(data + 16 * i)), mask);
        for (int i = 4; i < 16; i++)
            w[i] = _mm_sha256msg2_epu32(_mm_add_epi32(_mm_sha256msg1_epu32(w[i - 4], w[i - 3]), _mm_alignr_epi8(w[i - 1], w[i - 2], 4)), w[i - 1]);
        for (int i = 0; i < 16; i++) {
            __m128i m = _mm_add_epi32(w[i], _mm_loadu_si128((const __m128i *)(const void *)&SHA_K[4 * i]));
            s1 = _mm_sha256rnds2_epu32(s1, s0, m);
            m = _mm_shuffle_epi32(m, 0x0E);
            s0 = _mm_sha256rnds2_epu32(s0, s1, m);
        }
        s0 = _mm_add_epi32(s0, save0);
        s1 = _mm_add_epi32(s1, save1);
        data += 64;
    }
    tmp = _mm_shuffle_epi32(s0, 0x1B);
    s1 = _mm_shuffle_epi32(s1, 0xB1);
    s0 = _mm_blend_epi16(tmp, s1, 0xF0);
    s1 = _mm_alignr_epi8(s1, tmp, 8);
    _mm_storeu_si128((__m128i *)(void *)&st[0], s0);
    _mm_storeu_si128((__m128i *)(void *)&st[4], s1);
}

/* seal != 0: encrypt pt and append the tag; seal == 0: n includes the tag, verify it first (-1 when wrong) */
TARGET int ssl_accel_gcm(int seal, const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *in, size_t n, uint8_t *out) {
    aesni_key k;
    if (aesni_setup(&k, key, kl)) return -1;
    size_t cl = n;
    if (!seal) {
        if (n < 16) return -1;
        cl = n - 16;
    }
    uint8_t jb[16] = {0};
    memcpy(jb, nonce, 12);
    jb[15] = 1;
    __m128i base = _mm_loadu_si128((const __m128i *)(const void *)jb);
    __m128i h = bswap128(aes_block(&k, _mm_setzero_si128()));
    const uint8_t *ct = seal ? out : in;
    if (seal) ctr_xor(&k, base, in, cl, out);
    __m128i y = ghash_run(_mm_setzero_si128(), h, aad, al);
    y = ghash_run(y, h, ct, cl);
    uint8_t lens[16];
    uint64_t ab = (uint64_t)al * 8, cb = (uint64_t)cl * 8;
    for (int i = 0; i < 8; i++) { lens[i] = (uint8_t)(ab >> (56 - 8 * i)); lens[8 + i] = (uint8_t)(cb >> (56 - 8 * i)); }
    y = ghash_run(y, h, lens, 16);
    __m128i tag = _mm_xor_si128(bswap128(y), aes_block(&k, base));
    uint8_t tb[16];
    _mm_storeu_si128((__m128i *)(void *)tb, tag);
    if (seal) {
        memcpy(out + cl, tb, 16);
        return 0;
    }
    uint8_t d = 0;
    for (int i = 0; i < 16; i++) d |= (uint8_t)(tb[i] ^ in[cl + (size_t)i]);
    if (d) return -1;
    ctr_xor(&k, base, in, cl, out);
    return 0;
}

#else
int ssl_accel_aesgcm(void) { return 0; }
int ssl_accel_sha256(void) { return 0; }
void ssl_accel_sha256_blocks(uint32_t st[8], const uint8_t *data, size_t blocks) { (void)st; (void)data; (void)blocks; }
size_t ssl_chacha_xor4(const uint8_t key[32], uint32_t ctr, const uint8_t nonce[12], const uint8_t *in, size_t n, uint8_t *out) {
    (void)key; (void)ctr; (void)nonce; (void)in; (void)n; (void)out;
    return 0;
}
int ssl_accel_gcm(int seal, const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *in, size_t n, uint8_t *out) {
    (void)seal; (void)key; (void)kl; (void)nonce; (void)aad; (void)al; (void)in; (void)n; (void)out;
    return -1;
}
#endif
