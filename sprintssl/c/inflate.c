/* zlib / DEFLATE decompression (RFC 1950, 1951), in the manner of zlib's puff.c, with the Adler-32 check. */
#include <stdlib.h>
#include <string.h>
#include "sslcore.h"

typedef struct {
    const uint8_t *in;
    size_t inlen, pos;
    uint32_t bitbuf;
    int bitcnt;
    uint8_t *out;
    size_t outcap, outlen;
    int err;
} st_t;

typedef struct {
    uint16_t count[16];
    uint16_t symbol[320];
} huff;

static int bits(st_t *s, int need) {
    uint32_t v = s->bitbuf;
    while (s->bitcnt < need) {
        if (s->pos >= s->inlen) { s->err = 1; return 0; }
        v |= (uint32_t)s->in[s->pos++] << s->bitcnt;
        s->bitcnt += 8;
    }
    s->bitbuf = v >> need;
    s->bitcnt -= need;
    return (int)(v & ((1u << need) - 1));
}
static int decode(st_t *s, const huff *h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= 15; len++) {
        code |= bits(s, 1);
        if (s->err) return -1;
        int count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    s->err = 1;
    return -1;
}
static int construct(huff *h, const uint16_t *length, int n) {
    int offs[16];
    for (int i = 0; i <= 15; i++) h->count[i] = 0;
    for (int i = 0; i < n; i++) h->count[length[i]]++;
    if (h->count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= 15; len++) {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return left;
    }
    offs[1] = 0;
    for (int len = 1; len < 15; len++) offs[len + 1] = offs[len] + h->count[len];
    for (int i = 0; i < n; i++)
        if (length[i] != 0) h->symbol[offs[length[i]]++] = (uint16_t)i;
    return left;
}
static int put(st_t *s, uint8_t b) {
    if (s->outlen >= s->outcap) {
        size_t nc = s->outcap ? s->outcap * 2 : 65536;
        uint8_t *n = realloc(s->out, nc);
        if (!n) { s->err = 2; return -1; }
        s->out = n;
        s->outcap = nc;
    }
    s->out[s->outlen++] = b;
    return 0;
}
static const uint16_t LBASE[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint16_t LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t DBASE[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
static const uint16_t DEXT[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

static int codes(st_t *s, const huff *lc, const huff *dc) {
    for (;;) {
        int sym = decode(s, lc);
        if (sym < 0) return -1;
        if (sym < 256) {
            if (put(s, (uint8_t)sym)) return -1;
        } else if (sym == 256) {
            return 0;
        } else {
            sym -= 257;
            if (sym >= 29) { s->err = 1; return -1; }
            int len = LBASE[sym] + bits(s, LEXT[sym]);
            int ds = decode(s, dc);
            if (ds < 0 || ds >= 30) { s->err = 1; return -1; }
            size_t dist = (size_t)DBASE[ds] + (size_t)bits(s, DEXT[ds]);
            if (s->err) return -1;
            if (dist > s->outlen) { s->err = 1; return -1; }
            while (len--)
                if (put(s, s->out[s->outlen - dist])) return -1;
        }
    }
}

static int build_fixed(huff *lc, huff *dc) {
    uint16_t l[288];
    int i = 0;
    for (; i < 144; i++) l[i] = 8;
    for (; i < 256; i++) l[i] = 9;
    for (; i < 280; i++) l[i] = 7;
    for (; i < 288; i++) l[i] = 8;
    construct(lc, l, 288);
    for (i = 0; i < 30; i++) l[i] = 5;
    construct(dc, l, 30);
    return 0;
}
static int dynamic(st_t *s) {
    static const uint8_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    uint16_t lengths[320];
    huff lc, dc;
    int nlen = bits(s, 5) + 257, ndist = bits(s, 5) + 1, ncode = bits(s, 4) + 4;
    if (s->err || nlen > 286 || ndist > 30) { s->err = 1; return -1; }
    int i;
    for (i = 0; i < ncode; i++) lengths[order[i]] = (uint16_t)bits(s, 3);
    for (; i < 19; i++) lengths[order[i]] = 0;
    if (construct(&lc, lengths, 19) != 0) { s->err = 1; return -1; }
    int idx = 0;
    while (idx < nlen + ndist) {
        int sym = decode(s, &lc);
        if (sym < 0) return -1;
        if (sym < 16) lengths[idx++] = (uint16_t)sym;
        else {
            int len = 0, rep;
            if (sym == 16) {
                if (idx == 0) { s->err = 1; return -1; }
                len = lengths[idx - 1];
                rep = 3 + bits(s, 2);
            } else if (sym == 17) rep = 3 + bits(s, 3);
            else rep = 11 + bits(s, 7);
            if (idx + rep > nlen + ndist) { s->err = 1; return -1; }
            while (rep--) lengths[idx++] = (uint16_t)len;
        }
    }
    if (lengths[256] == 0) { s->err = 1; return -1; }
    int e = construct(&lc, lengths, nlen);
    if (e < 0 || (e > 0 && nlen - lc.count[0] != 1)) { s->err = 1; return -1; }
    e = construct(&dc, lengths + nlen, ndist);
    if (e < 0 || (e > 0 && ndist - dc.count[0] != 1)) { s->err = 1; return -1; }
    return codes(s, &lc, &dc);
}

/* decompress a zlib stream; on success *out is malloc'ed (free it) and 0 is returned */
int ssl_zlib_inflate(const uint8_t *in, size_t n, uint8_t **out, size_t *outlen, size_t maxout) {
    st_t s;
    memset(&s, 0, sizeof s);
    s.in = in;
    s.inlen = n;
    if (n < 6 || (in[0] & 15) != 8 || ((in[0] << 8) | in[1]) % 31 != 0 || (in[1] & 0x20)) return -1;
    s.pos = 2;
    int last;
    do {
        last = bits(&s, 1);
        int type = bits(&s, 2);
        if (s.err) break;
        if (type == 0) {
            s.bitbuf = 0;
            s.bitcnt = 0;
            if (s.pos + 4 > s.inlen) { s.err = 1; break; }
            unsigned len = (unsigned)(in[s.pos] | (in[s.pos + 1] << 8)), nlen = (unsigned)(in[s.pos + 2] | (in[s.pos + 3] << 8));
            s.pos += 4;
            if (len != (~nlen & 0xffff) || s.pos + len > s.inlen) { s.err = 1; break; }
            while (len--) if (put(&s, in[s.pos++])) break;
        } else if (type == 1) {
            huff lc, dc;
            build_fixed(&lc, &dc);
            codes(&s, &lc, &dc);
        } else if (type == 2) dynamic(&s);
        else s.err = 1;
        if (s.outlen > maxout) s.err = 3;
    } while (!last && !s.err);
    if (!s.err) {
        if (s.pos + 4 > s.inlen) s.err = 1;
        else {
            uint32_t a = 1, b = 0;
            for (size_t i = 0; i < s.outlen; i++) { a = (a + s.out[i]) % 65521; b = (b + a) % 65521; }
            const uint8_t *t = in + s.pos;
            uint32_t want = ((uint32_t)t[0] << 24) | ((uint32_t)t[1] << 16) | ((uint32_t)t[2] << 8) | t[3];
            if (((b << 16) | a) != want) s.err = 1;
        }
    }
    if (s.err) { free(s.out); return -1; }
    *out = s.out ? s.out : malloc(1);
    *outlen = s.outlen;
    return 0;
}
