/* SHA-256, SHA-384, SHA-512, HMAC and HKDF (RFC 6234, 2104, 5869) */
#include <string.h>
#include "sslcore.h"

static uint32_t ror32(uint32_t x, unsigned n) { return (x >> n) | (x << (32u - n)); }
static uint64_t ror64(uint64_t x, unsigned n) { return (x >> n) | (x << (64u - n)); }

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74,
    0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d,
    0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e,
    0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static void sha256_block(uint32_t h[8], const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) | ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = hh + (ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void ssl_sha256_init(ssl_sha256_ctx *c) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(c->h, iv, sizeof iv);
    c->len = 0;
}
void ssl_sha256_update(ssl_sha256_ctx *c, const uint8_t *p, size_t n) {
    size_t fill = (size_t)(c->len & 63);
    c->len += n;
    if (fill) {
        size_t k = 64 - fill < n ? 64 - fill : n;
        memcpy(c->buf + fill, p, k);
        p += k; n -= k;
        if (fill + k < 64) return;
        sha256_block(c->h, c->buf);
    }
    for (; n >= 64; p += 64, n -= 64) sha256_block(c->h, p);
    if (n) memcpy(c->buf, p, n);
}
void ssl_sha256_final(ssl_sha256_ctx *c, uint8_t out[32]) {
    uint64_t bits = c->len * 8;
    uint8_t pad[72] = {0x80};
    size_t fill = (size_t)(c->len & 63);
    size_t padn = (fill < 56 ? 56 : 120) - fill;
    for (int i = 0; i < 8; i++) pad[padn + (size_t)i] = (uint8_t)(bits >> (56 - 8 * i));
    ssl_sha256_update(c, pad, padn + 8);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(c->h[i] >> 24); out[4 * i + 1] = (uint8_t)(c->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(c->h[i] >> 8); out[4 * i + 3] = (uint8_t)c->h[i];
    }
}

static const uint64_t K512[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL, 0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL, 0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL, 0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL, 0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL, 0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL, 0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL, 0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL, 0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL, 0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL, 0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL};

static void sha512_block(uint64_t h[8], const uint8_t *p) {
    uint64_t w[80];
    for (int i = 0; i < 16; i++) {
        uint64_t v = 0;
        for (int j = 0; j < 8; j++) v = (v << 8) | p[8 * i + j];
        w[i] = v;
    }
    for (int i = 16; i < 80; i++) {
        uint64_t s0 = ror64(w[i - 15], 1) ^ ror64(w[i - 15], 8) ^ (w[i - 15] >> 7);
        uint64_t s1 = ror64(w[i - 2], 19) ^ ror64(w[i - 2], 61) ^ (w[i - 2] >> 6);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint64_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 80; i++) {
        uint64_t t1 = hh + (ror64(e, 14) ^ ror64(e, 18) ^ ror64(e, 41)) + ((e & f) ^ (~e & g)) + K512[i] + w[i];
        uint64_t t2 = (ror64(a, 28) ^ ror64(a, 34) ^ ror64(a, 39)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void ssl_sha512_init(ssl_sha512_ctx *c, int is384) {
    static const uint64_t iv512[8] = {0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
                                      0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
    static const uint64_t iv384[8] = {0xcbbb9d5dc1059ed8ULL, 0x629a292a367cd507ULL, 0x9159015a3070dd17ULL, 0x152fecd8f70e5939ULL,
                                      0x67332667ffc00b31ULL, 0x8eb44a8768581511ULL, 0xdb0c2e0d64f98fa7ULL, 0x47b5481dbefa4fa4ULL};
    memcpy(c->h, is384 ? iv384 : iv512, sizeof c->h);
    c->len = 0;
    c->is384 = is384;
}
void ssl_sha512_update(ssl_sha512_ctx *c, const uint8_t *p, size_t n) {
    size_t fill = (size_t)(c->len & 127);
    c->len += n;
    if (fill) {
        size_t k = 128 - fill < n ? 128 - fill : n;
        memcpy(c->buf + fill, p, k);
        p += k; n -= k;
        if (fill + k < 128) return;
        sha512_block(c->h, c->buf);
    }
    for (; n >= 128; p += 128, n -= 128) sha512_block(c->h, p);
    if (n) memcpy(c->buf, p, n);
}
void ssl_sha512_final(ssl_sha512_ctx *c, uint8_t *out) {
    uint64_t bits = c->len * 8;
    uint8_t pad[144] = {0x80};
    size_t fill = (size_t)(c->len & 127);
    size_t padn = (fill < 112 ? 112 : 240) - fill;
    for (int i = 0; i < 8; i++) pad[padn + 8 + (size_t)i] = (uint8_t)(bits >> (56 - 8 * i));
    ssl_sha512_update(c, pad, padn + 16);
    int words = c->is384 ? 6 : 8;
    for (int i = 0; i < words; i++)
        for (int j = 0; j < 8; j++) out[8 * i + j] = (uint8_t)(c->h[i] >> (56 - 8 * j));
}

int ssl_hash_len(int alg) { return alg == 256 ? 32 : alg == 384 ? 48 : alg == 512 ? 64 : 0; }
int ssl_hash(int alg, const uint8_t *p, size_t n, uint8_t *out) {
    if (alg == 256) {
        ssl_sha256_ctx c;
        ssl_sha256_init(&c); ssl_sha256_update(&c, p, n); ssl_sha256_final(&c, out);
        return 0;
    }
    if (alg == 384 || alg == 512) {
        ssl_sha512_ctx c;
        ssl_sha512_init(&c, alg == 384); ssl_sha512_update(&c, p, n); ssl_sha512_final(&c, out);
        return 0;
    }
    return -1;
}

int ssl_hmac(int alg, const uint8_t *key, size_t kl, const uint8_t *msg, size_t ml, uint8_t *out) {
    int hl = ssl_hash_len(alg);
    if (!hl) return -1;
    size_t bl = alg == 256 ? 64 : 128;
    uint8_t k[128] = {0}, ipad[128 + 1], opad[128 + 64], inner[64];
    if (kl > bl) ssl_hash(alg, key, kl, k);
    else if (kl) memcpy(k, key, kl);
    for (size_t i = 0; i < bl; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    if (alg == 256) {
        ssl_sha256_ctx c;
        ssl_sha256_init(&c); ssl_sha256_update(&c, ipad, bl); ssl_sha256_update(&c, msg, ml); ssl_sha256_final(&c, inner);
    } else {
        ssl_sha512_ctx c;
        ssl_sha512_init(&c, alg == 384); ssl_sha512_update(&c, ipad, bl); ssl_sha512_update(&c, msg, ml); ssl_sha512_final(&c, inner);
    }
    memcpy(opad + bl, inner, (size_t)hl);
    return ssl_hash(alg, opad, bl + (size_t)hl, out);
}

int ssl_hkdf_extract(int alg, const uint8_t *salt, size_t sl, const uint8_t *ikm, size_t il, uint8_t *out) {
    uint8_t zero[64] = {0};
    int hl = ssl_hash_len(alg);
    if (!hl) return -1;
    if (sl == 0) return ssl_hmac(alg, zero, (size_t)hl, ikm, il, out);
    return ssl_hmac(alg, salt, sl, ikm, il, out);
}

int ssl_hkdf_expand(int alg, const uint8_t *prk, size_t pl, const uint8_t *info, size_t nl, uint8_t *out, size_t olen) {
    int hl = ssl_hash_len(alg);
    if (!hl || olen > 255 * (size_t)hl || nl > 1024) return -1;
    uint8_t t[64], buf[64 + 1024 + 1];
    size_t tl = 0;
    for (uint8_t i = 1; olen > 0; i++) {
        memcpy(buf, t, tl);
        memcpy(buf + tl, info, nl);
        buf[tl + nl] = i;
        ssl_hmac(alg, prk, pl, buf, tl + nl + 1, t);
        tl = (size_t)hl;
        size_t k = olen < tl ? olen : tl;
        memcpy(out, t, k);
        out += k; olen -= k;
    }
    return 0;
}
