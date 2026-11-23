/* The random number generator: a ChaCha20 keystream whose key is re-derived (SHA-256) from itself, the platform's entropy and whatever the caller adds
 * with ssl_random_seed(). On Linux the entropy is getrandom(); on x86 without an operating system underneath (SprintOS) it is RDRAND when the CPU has it,
 * plus the time stamp counter. Where there is no hardware source (QEMU's default CPU has no RDRAND) the output is only as unpredictable as the seeds the
 * caller supplied: SprintOS feeds it clock readings, the network card's MAC address and interrupt timing, which is NOT enough for production use. */
#include <string.h>
#include "sslcore.h"
#if !defined(SP_OS) && defined(__linux__)
#include <sys/random.h>
#endif

static uint8_t pool[32];
static uint64_t counter;

#if defined(__x86_64__)
static uint64_t tsc(void) {
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}
static int have_rdrand(void) {
    uint32_t a = 1, b, c = 0, d;
    __asm__ volatile("cpuid" : "+a"(a), "=b"(b), "+c"(c), "=d"(d));
    return (c >> 30) & 1;
}
static int rdrand64(uint64_t *v) {
    unsigned char ok;
    for (int i = 0; i < 10; i++) {
        __asm__ volatile("rdrand %0; setc %1" : "=r"(*v), "=qm"(ok));
        if (ok) return 1;
    }
    return 0;
}
#endif

static void mix(const uint8_t *p, size_t n) {
    uint8_t buf[32 + 256 + 8];
    if (n > 256) n = 256;
    memcpy(buf, pool, 32);
    memcpy(buf + 32, p, n);
    counter++;
    for (int i = 0; i < 8; i++) buf[32 + n + (size_t)i] = (uint8_t)(counter >> (8 * i));
    ssl_hash(256, buf, 32 + n + 8, pool);
}

void ssl_random_seed(const uint8_t *p, size_t n) {
    while (n > 0) {
        size_t k = n < 256 ? n : 256;
        mix(p, k);
        p += k; n -= k;
    }
}

void ssl_random(uint8_t *out, size_t n) {
    uint8_t e[64];
    size_t el = 0;
#if !defined(SP_OS) && defined(__linux__)
    ssize_t got = getrandom(e, 32, 0);
    if (got > 0) el = (size_t)got;
#endif
#if defined(__x86_64__)
    uint64_t t = tsc();
    memcpy(e + el, &t, 8);
    el += 8;
    if (have_rdrand()) {
        uint64_t r;
        for (int i = 0; i < 2; i++)
            if (rdrand64(&r)) { memcpy(e + el, &r, 8); el += 8; }
    }
#endif
    mix(e, el);
    static const uint8_t nonce[12] = {0};
    static const uint8_t zeros[64] = {0};
    uint8_t ct[64 + 16];
    for (size_t off = 0; off < n; off += 32) {
        ssl_chacha_seal(pool, nonce, NULL, 0, zeros, 64, ct);   /* the keystream of the pool as a key: XOR with zeros */
        size_t k = n - off < 32 ? n - off : 32;
        memcpy(out + off, ct, k);
        mix(ct + 32, 32);                                       /* the pool moves on using bytes that were not output */
    }
}
