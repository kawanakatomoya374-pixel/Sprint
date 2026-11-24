/* the hardware paths (AES-NI + PCLMULQDQ GCM, SSE2 ChaCha20, SHA-NI SHA-256) against the portable code on random inputs.
   Build: sprintssl/tests/accel_test.sh (compiles aead.c twice, once with SSL_NO_ACCEL and its entry points renamed). */
#include "sslcore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int port_ssl_aes_gcm_seal(const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *pt, size_t n, uint8_t *out);
int port_ssl_aes_gcm_open(const uint8_t *key, size_t kl, const uint8_t *nonce, const uint8_t *aad, size_t al, const uint8_t *ct, size_t n, uint8_t *out);
void port_ssl_chacha_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t al, const uint8_t *pt, size_t n, uint8_t *out);
int port_ssl_hash_sha256(const uint8_t *p, size_t n, uint8_t *out);

int main(void) {
    srand(7);
    int bad = 0, tot = 0;
    for (int it = 0; it < 3000; it++) {
        uint8_t key[32], nonce[12], aad[64], pt[600], o1[640], o2[640], d1[640], d2[640];
        for (int i = 0; i < 32; i++) key[i] = (uint8_t)rand();
        for (int i = 0; i < 12; i++) nonce[i] = (uint8_t)rand();
        size_t al = (size_t)(rand() % 50), n = (size_t)(rand() % 520);
        for (size_t i = 0; i < al; i++) aad[i] = (uint8_t)rand();
        for (size_t i = 0; i < n; i++) pt[i] = (uint8_t)rand();
        size_t kl = (rand() & 1) ? 16 : 32;
        ssl_aes_gcm_seal(key, kl, nonce, aad, al, pt, n, o1);
        port_ssl_aes_gcm_seal(key, kl, nonce, aad, al, pt, n, o2);
        tot++;
        if (memcmp(o1, o2, n + 16)) { bad++; continue; }
        if (ssl_aes_gcm_open(key, kl, nonce, aad, al, o1, n + 16, d1) != 0 || memcmp(d1, pt, n)) bad++;
        if (port_ssl_aes_gcm_open(key, kl, nonce, aad, al, o1, n + 16, d2) != 0 || memcmp(d2, pt, n)) bad++;
        if (n > 0) {
            o1[(size_t)rand() % n] ^= 1;
            if (ssl_aes_gcm_open(key, kl, nonce, aad, al, o1, n + 16, d1) == 0) bad++;   /* a flipped bit must be refused */
        }
    }
    for (int it = 0; it < 2000; it++) {
        uint8_t key[32], nonce[12], aad[64], pt[2000], o1[2016], o2[2016];
        for (int i = 0; i < 32; i++) key[i] = (uint8_t)rand();
        for (int i = 0; i < 12; i++) nonce[i] = (uint8_t)rand();
        size_t al = (size_t)(rand() % 50), n = (size_t)(rand() % 1800);
        for (size_t i = 0; i < al; i++) aad[i] = (uint8_t)rand();
        for (size_t i = 0; i < n; i++) pt[i] = (uint8_t)rand();
        ssl_chacha_seal(key, nonce, aad, al, pt, n, o1);
        port_ssl_chacha_seal(key, nonce, aad, al, pt, n, o2);
        tot++;
        if (memcmp(o1, o2, n + 16)) bad++;
    }
    for (int it = 0; it < 2000; it++) {
        size_t n = (size_t)(rand() % 5000);
        uint8_t *b = malloc(n + 1), o1[32], o2[32];
        for (size_t i = 0; i < n; i++) b[i] = (uint8_t)rand();
        ssl_hash(256, b, n, o1);
        port_ssl_hash_sha256(b, n, o2);
        tot++;
        if (memcmp(o1, o2, 32)) bad++;
        free(b);
    }
    printf("hardware paths vs portable code: %d cases, %d wrong\n", tot, bad);
    return bad != 0;
}
