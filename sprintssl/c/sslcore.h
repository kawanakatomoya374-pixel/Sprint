/* sslcore: the C primitives of SprintSSL. Plain C11 with no dependencies beyond <stdint.h> and <string.h>; sslcore_sp.c binds them to Sprint. */
#ifndef SSLCORE_H
#define SSLCORE_H
#include <stddef.h>
#include <stdint.h>

/* ---- hashes (alg: 256, 384 or 512) ---- */
typedef struct {
    uint32_t h[8];
    uint64_t len;
    uint8_t buf[64];
} ssl_sha256_ctx;
typedef struct {
    uint64_t h[8];
    uint64_t len;
    uint8_t buf[128];
    int is384;
} ssl_sha512_ctx;
void ssl_sha256_init(ssl_sha256_ctx *c);
void ssl_sha256_update(ssl_sha256_ctx *c, const uint8_t *p, size_t n);
void ssl_sha256_final(ssl_sha256_ctx *c, uint8_t out[32]);
void ssl_sha512_init(ssl_sha512_ctx *c, int is384);
void ssl_sha512_update(ssl_sha512_ctx *c, const uint8_t *p, size_t n);
void ssl_sha512_final(ssl_sha512_ctx *c, uint8_t *out); /* 64 bytes (48 for SHA-384) */
int ssl_hash_len(int alg);                               /* 0 for an unknown alg */
int ssl_hash(int alg, const uint8_t *p, size_t n, uint8_t *out);
int ssl_hmac(int alg, const uint8_t *key, size_t kl, const uint8_t *msg, size_t ml, uint8_t *out);
int ssl_hkdf_extract(int alg, const uint8_t *salt, size_t sl, const uint8_t *ikm, size_t il, uint8_t *out);
int ssl_hkdf_expand(int alg, const uint8_t *prk, size_t pl, const uint8_t *info, size_t nl, uint8_t *out, size_t olen);

/* ---- AEAD: AES-GCM (key 16 or 32 bytes, nonce 12) and ChaCha20-Poly1305. seal writes n + 16 bytes; open returns 0 when the tag is right ---- */
int ssl_aes_gcm_seal(const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *pt, size_t n, uint8_t *out);
int ssl_aes_gcm_open(const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *ct, size_t n, uint8_t *out); /* n includes the tag */
int ssl_accel_aesgcm(void);   /* 1 when this CPU has AES-NI and PCLMULQDQ */
int ssl_accel_gcm(int seal, const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *in, size_t n, uint8_t *out);
size_t ssl_chacha_xor4(const uint8_t key[32], uint32_t ctr, const uint8_t nonce[12], const uint8_t *in, size_t n, uint8_t *out); /* whole 256-byte groups; returns the bytes done */
int ssl_accel_sha256(void);   /* 1 when this CPU has the SHA extensions */
void ssl_accel_sha256_blocks(uint32_t st[8], const uint8_t *data, size_t blocks);
void ssl_chacha_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t al, const uint8_t *pt, size_t n, uint8_t *out);
int ssl_chacha_open(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t al, const uint8_t *ct, size_t n, uint8_t *out);

/* ---- Curve25519 ---- */
void ssl_x25519(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]);
void ssl_x25519_base(uint8_t out[32], const uint8_t scalar[32]);
void ssl_ed25519_pub(uint8_t pub[32], const uint8_t seed[32]);
void ssl_ed25519_sign(uint8_t sig[64], const uint8_t *msg, size_t n, const uint8_t seed[32]);
int ssl_ed25519_verify(const uint8_t sig[64], const uint8_t *msg, size_t n, const uint8_t pub[32]); /* 0 when valid */

/* ---- big-number public-key operations (verification only) ---- */
int ssl_rsa_public(const uint8_t *n, size_t nl, const uint8_t *e, size_t el, const uint8_t *in, size_t il, uint8_t *out); /* out has nl bytes; 0 on success */
int ssl_ecdsa_verify(int curve, const uint8_t *pub, size_t pl, const uint8_t *hash, size_t hl, const uint8_t *r, size_t rl, const uint8_t *s, size_t sl); /* curve 256 or 384; pub is 04||X||Y; 0 when valid */
int ssl_ecdh(int curve, uint8_t *out, const uint8_t *pub, size_t pl, const uint8_t *priv, size_t vl);   /* out: the X coordinate; 0 on success */
int ssl_ec_pub(int curve, uint8_t *out, const uint8_t *priv, size_t vl);                                /* out: 04||X||Y */

/* ---- random numbers ---- */
void ssl_random(uint8_t *out, size_t n);
void ssl_random_seed(const uint8_t *p, size_t n);

/* ---- zlib ---- */
int ssl_zlib_inflate(const uint8_t *in, size_t n, uint8_t **out, size_t *outlen, size_t maxout); /* 0 on success; free(*out) */
#endif
