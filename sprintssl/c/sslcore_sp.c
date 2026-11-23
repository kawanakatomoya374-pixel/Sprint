/* sslcore_sp.c: the Sprint module `sslcore` over the primitives in this folder. Byte strings are typed.u8 values (an array of ints 0..255 is accepted as
 * input too). Needs the Sprint source tree's headers (-I<Sprint>/src). */
#include <stdlib.h>
#include <string.h>
#include "lib/lib_int.h"
#include "sslcore.h"

typedef struct {
    const unsigned char *p;
    size_t n;
    unsigned char *tmp;      /* owned copy when the argument was an array */
} bytes_arg;

static int get_bytes(VM *vm, SpValue v, const char *what, bytes_arg *b) {
    b->tmp = NULL;
    const unsigned char *d = typed_u8_data(v);
    if (d) {
        b->p = d;
        b->n = (size_t)typed_len(v);
        return 0;
    }
    if (v.type == T_ARRAY) {
        size_t n = (size_t)AS_ARRAY(v)->len;
        unsigned char *t = malloc(n ? n : 1);
        if (!t) return vm_set_error(vm, E_MEMORY, "out of memory");
        for (size_t i = 0; i < n; i++) {
            SpValue e = array_get(AS_ARRAY(v), (int64_t)i);
            if (e.type != T_INT || e.as.i < 0 || e.as.i > 255) {
                free(t);
                return vm_set_error(vm, E_VALUE, "%s: element %zu is not a byte", what, i);
            }
            t[i] = (unsigned char)e.as.i;
        }
        b->tmp = t;
        b->p = t;
        b->n = n;
        return 0;
    }
    return vm_set_error(vm, E_TYPE, "%s must be bytes (typed.u8), not %s", what, type_name(v));
}
static void put_bytes(bytes_arg *b) { free(b->tmp); b->tmp = NULL; }

#define NEED(var, idx, what) bytes_arg var; if (get_bytes(vm, argv[idx], what, &var)) return 1
#define DONE(var) put_bytes(&var)

static int sc_hash(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t alg;
    if (need_int(vm, argv[0], "alg", &alg)) return 1;
    int hl = ssl_hash_len((int)alg);
    if (!hl) return vm_set_error(vm, E_VALUE, "sslcore.hash: alg must be 256, 384 or 512");
    NEED(d, 1, "data");
    uint8_t out[64];
    ssl_hash((int)alg, d.p, d.n, out);
    DONE(d);
    *ret = typed_u8_from(vm, out, (size_t)hl);
    return 0;
}
static int sc_hmac(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t alg;
    if (need_int(vm, argv[0], "alg", &alg)) return 1;
    int hl = ssl_hash_len((int)alg);
    if (!hl) return vm_set_error(vm, E_VALUE, "sslcore.hmac: alg must be 256, 384 or 512");
    NEED(k, 1, "key");
    bytes_arg d;
    if (get_bytes(vm, argv[2], "data", &d)) { DONE(k); return 1; }
    uint8_t out[64];
    ssl_hmac((int)alg, k.p, k.n, d.p, d.n, out);
    DONE(k); DONE(d);
    *ret = typed_u8_from(vm, out, (size_t)hl);
    return 0;
}
static int sc_hkdf_extract(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t alg;
    if (need_int(vm, argv[0], "alg", &alg)) return 1;
    int hl = ssl_hash_len((int)alg);
    if (!hl) return vm_set_error(vm, E_VALUE, "sslcore.hkdf_extract: bad alg");
    NEED(s, 1, "salt");
    bytes_arg k;
    if (get_bytes(vm, argv[2], "ikm", &k)) { DONE(s); return 1; }
    uint8_t out[64];
    ssl_hkdf_extract((int)alg, s.p, s.n, k.p, k.n, out);
    DONE(s); DONE(k);
    *ret = typed_u8_from(vm, out, (size_t)hl);
    return 0;
}
static int sc_hkdf_expand(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t alg, len;
    if (need_int(vm, argv[0], "alg", &alg) || need_int(vm, argv[3], "length", &len)) return 1;
    int hl = ssl_hash_len((int)alg);
    if (!hl || len < 0 || len > 255 * hl) return vm_set_error(vm, E_VALUE, "sslcore.hkdf_expand: bad alg or length");
    NEED(prk, 1, "prk");
    bytes_arg info;
    if (get_bytes(vm, argv[2], "info", &info)) { DONE(prk); return 1; }
    unsigned char *out = malloc((size_t)len + 1);
    if (!out) { DONE(prk); DONE(info); return vm_set_error(vm, E_MEMORY, "out of memory"); }
    int r = ssl_hkdf_expand((int)alg, prk.p, prk.n, info.p, info.n, out, (size_t)len);
    DONE(prk); DONE(info);
    if (r) { free(out); return vm_set_error(vm, E_VALUE, "sslcore.hkdf_expand: info too long"); }
    *ret = typed_u8_from(vm, out, (size_t)len);
    free(out);
    return 0;
}

/* aead(kind, key, nonce, aad, data): kind 0 AES-GCM seal, 1 AES-GCM open, 2 ChaCha20-Poly1305 seal, 3 open; open gives nil when the tag is wrong */
static int aead_common(VM *vm, SpValue *argv, SpValue *ret, int chacha, int open) {
    NEED(key, 0, "key");
    bytes_arg nonce, aad, data;
    if (get_bytes(vm, argv[1], "nonce", &nonce)) { DONE(key); return 1; }
    if (get_bytes(vm, argv[2], "aad", &aad)) { DONE(key); DONE(nonce); return 1; }
    if (get_bytes(vm, argv[3], "data", &data)) { DONE(key); DONE(nonce); DONE(aad); return 1; }
    int err = 0;
    if (nonce.n != 12) err = vm_set_error(vm, E_VALUE, "nonce must be 12 bytes");
    else if (chacha && key.n != 32) err = vm_set_error(vm, E_VALUE, "ChaCha20 key must be 32 bytes");
    else if (!chacha && key.n != 16 && key.n != 32) err = vm_set_error(vm, E_VALUE, "AES key must be 16 or 32 bytes");
    else if (open && data.n < 16) { *ret = v_nil(); goto done; }
    if (!err) {
        size_t outn = open ? data.n - 16 : data.n + 16;
        unsigned char *out = malloc(outn + 1);
        if (!out) err = vm_set_error(vm, E_MEMORY, "out of memory");
        else {
            int r = 0;
            if (chacha && !open) ssl_chacha_seal(key.p, nonce.p, aad.p, aad.n, data.p, data.n, out);
            else if (chacha) r = ssl_chacha_open(key.p, nonce.p, aad.p, aad.n, data.p, data.n, out);
            else if (!open) r = ssl_aes_gcm_seal(key.p, key.n, nonce.p, aad.p, aad.n, data.p, data.n, out);
            else r = ssl_aes_gcm_open(key.p, key.n, nonce.p, aad.p, aad.n, data.p, data.n, out);
            *ret = r ? v_nil() : typed_u8_from(vm, out, outn);
            free(out);
        }
    }
done:
    DONE(key); DONE(nonce); DONE(aad); DONE(data);
    return err;
}
static int sc_gcm_seal(VM *vm, int argc, SpValue *argv, SpValue *ret) { (void)argc; return aead_common(vm, argv, ret, 0, 0); }
static int sc_gcm_open(VM *vm, int argc, SpValue *argv, SpValue *ret) { (void)argc; return aead_common(vm, argv, ret, 0, 1); }
static int sc_chacha_seal(VM *vm, int argc, SpValue *argv, SpValue *ret) { (void)argc; return aead_common(vm, argv, ret, 1, 0); }
static int sc_chacha_open(VM *vm, int argc, SpValue *argv, SpValue *ret) { (void)argc; return aead_common(vm, argv, ret, 1, 1); }

static int sc_x25519(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(k, 0, "scalar");
    bytes_arg p;
    if (get_bytes(vm, argv[1], "point", &p)) { DONE(k); return 1; }
    if (k.n != 32 || p.n != 32) { DONE(k); DONE(p); return vm_set_error(vm, E_VALUE, "x25519 takes 32-byte values"); }
    uint8_t out[32];
    ssl_x25519(out, k.p, p.p);
    DONE(k); DONE(p);
    uint8_t z = 0;
    for (int i = 0; i < 32; i++) z |= out[i];
    *ret = z ? typed_u8_from(vm, out, 32) : v_nil();       /* nil: a low-order point gave the all-zero result */
    return 0;
}
static int sc_x25519_base(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(k, 0, "scalar");
    if (k.n != 32) { DONE(k); return vm_set_error(vm, E_VALUE, "x25519 takes a 32-byte scalar"); }
    uint8_t out[32];
    ssl_x25519_base(out, k.p);
    DONE(k);
    *ret = typed_u8_from(vm, out, 32);
    return 0;
}
static int sc_ed_pub(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(k, 0, "seed");
    if (k.n != 32) { DONE(k); return vm_set_error(vm, E_VALUE, "an Ed25519 seed is 32 bytes"); }
    uint8_t out[32];
    ssl_ed25519_pub(out, k.p);
    DONE(k);
    *ret = typed_u8_from(vm, out, 32);
    return 0;
}
static int sc_ed_sign(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(k, 0, "seed");
    bytes_arg m;
    if (get_bytes(vm, argv[1], "message", &m)) { DONE(k); return 1; }
    if (k.n != 32) { DONE(k); DONE(m); return vm_set_error(vm, E_VALUE, "an Ed25519 seed is 32 bytes"); }
    uint8_t out[64];
    ssl_ed25519_sign(out, m.p, m.n, k.p);
    DONE(k); DONE(m);
    *ret = typed_u8_from(vm, out, 64);
    return 0;
}
static int sc_ed_verify(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(sig, 0, "signature");
    bytes_arg m, pub;
    if (get_bytes(vm, argv[1], "message", &m)) { DONE(sig); return 1; }
    if (get_bytes(vm, argv[2], "public key", &pub)) { DONE(sig); DONE(m); return 1; }
    *ret = v_bool(sig.n == 64 && pub.n == 32 && ssl_ed25519_verify(sig.p, m.p, m.n, pub.p) == 0);
    DONE(sig); DONE(m); DONE(pub);
    return 0;
}
static int sc_rsa_public(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(n, 0, "modulus");
    bytes_arg e, s;
    if (get_bytes(vm, argv[1], "exponent", &e)) { DONE(n); return 1; }
    if (get_bytes(vm, argv[2], "signature", &s)) { DONE(n); DONE(e); return 1; }
    size_t nl = n.n;
    while (nl > 0 && n.p[n.n - nl] == 0) nl--;
    const unsigned char *np = n.p + (n.n - nl);
    unsigned char *out = malloc(nl + 1);
    if (!out) { DONE(n); DONE(e); DONE(s); return vm_set_error(vm, E_MEMORY, "out of memory"); }
    int r = nl >= 64 && nl <= 512 ? ssl_rsa_public(np, nl, e.p, e.n, s.p, s.n, out) : -1;
    DONE(n); DONE(e); DONE(s);
    *ret = r ? v_nil() : typed_u8_from(vm, out, nl);
    free(out);
    return 0;
}
static int sc_ecdsa_verify(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t curve;
    if (need_int(vm, argv[0], "curve", &curve)) return 1;
    NEED(pub, 1, "public key");
    bytes_arg h, r, s;
    if (get_bytes(vm, argv[2], "hash", &h)) { DONE(pub); return 1; }
    if (get_bytes(vm, argv[3], "r", &r)) { DONE(pub); DONE(h); return 1; }
    if (get_bytes(vm, argv[4], "s", &s)) { DONE(pub); DONE(h); DONE(r); return 1; }
    *ret = v_bool(ssl_ecdsa_verify((int)curve, pub.p, pub.n, h.p, h.n, r.p, r.n, s.p, s.n) == 0);
    DONE(pub); DONE(h); DONE(r); DONE(s);
    return 0;
}
static int sc_ecdh(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t curve;
    if (need_int(vm, argv[0], "curve", &curve)) return 1;
    NEED(pub, 1, "public key");
    bytes_arg priv;
    if (get_bytes(vm, argv[2], "private key", &priv)) { DONE(pub); return 1; }
    uint8_t out[48];
    int r = ssl_ecdh((int)curve, out, pub.p, pub.n, priv.p, priv.n);
    DONE(pub); DONE(priv);
    *ret = r ? v_nil() : typed_u8_from(vm, out, curve == 256 ? 32 : 48);
    return 0;
}
static int sc_ec_pub(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t curve;
    if (need_int(vm, argv[0], "curve", &curve)) return 1;
    NEED(priv, 1, "private key");
    uint8_t out[97];
    int r = ssl_ec_pub((int)curve, out, priv.p, priv.n);
    DONE(priv);
    *ret = r ? v_nil() : typed_u8_from(vm, out, curve == 256 ? 65 : 97);
    return 0;
}
static int sc_random(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t n;
    if (need_int(vm, argv[0], "n", &n)) return 1;
    if (n < 0 || n > (1 << 20)) return vm_set_error(vm, E_VALUE, "sslcore.random: n out of range");
    unsigned char *b = malloc((size_t)n + 1);
    if (!b) return vm_set_error(vm, E_MEMORY, "out of memory");
    ssl_random(b, (size_t)n);
    *ret = typed_u8_from(vm, b, (size_t)n);
    free(b);
    return 0;
}
static int sc_seed(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(d, 0, "seed");
    ssl_random_seed(d.p, d.n);
    DONE(d);
    *ret = v_nil();
    return 0;
}

/* ---- byte string helpers ---- */
static int sc_concat(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != T_ARRAY) return vm_set_error(vm, E_TYPE, "sslcore.concat takes an array of byte strings");
    const SArray *a = AS_ARRAY(argv[0]);
    size_t total = 0;
    for (int64_t i = 0; i < a->len; i++) {
        SpValue e = array_get(a, i);
        if (!typed_u8_data(e) && e.type != T_ARRAY) return vm_set_error(vm, E_TYPE, "sslcore.concat: element %lld is not bytes", (long long)i);
        total += e.type == T_ARRAY ? (size_t)AS_ARRAY(e)->len : (size_t)typed_len(e);
    }
    unsigned char *out = malloc(total + 1);
    if (!out) return vm_set_error(vm, E_MEMORY, "out of memory");
    size_t off = 0;
    for (int64_t i = 0; i < a->len; i++) {
        bytes_arg b;
        if (get_bytes(vm, array_get(a, i), "element", &b)) { free(out); return 1; }
        memcpy(out + off, b.p, b.n);
        off += b.n;
        DONE(b);
    }
    *ret = typed_u8_from(vm, out, total);
    free(out);
    return 0;
}
static int sc_eq(VM *vm, int argc, SpValue *argv, SpValue *ret) {   /* constant-time comparison */
    (void)argc;
    NEED(a, 0, "a");
    bytes_arg b;
    if (get_bytes(vm, argv[1], "b", &b)) { DONE(a); return 1; }
    unsigned char d = a.n != b.n;
    for (size_t i = 0; i < a.n && i < b.n; i++) d |= (unsigned char)(a.p[i] ^ b.p[i]);
    *ret = v_bool(d == 0);
    DONE(a); DONE(b);
    return 0;
}
static int sc_hex(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    NEED(a, 0, "bytes");
    char *s = malloc(a.n * 2 + 1);
    if (!s) { DONE(a); return vm_set_error(vm, E_MEMORY, "out of memory"); }
    for (size_t i = 0; i < a.n; i++) {
        s[2 * i] = "0123456789abcdef"[a.p[i] >> 4];
        s[2 * i + 1] = "0123456789abcdef"[a.p[i] & 15];
    }
    *ret = vstr(vm, s, a.n * 2);
    free(s);
    DONE(a);
    return 0;
}
static int sc_unhex(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (need_str(vm, argv[0], "hex")) return 1;
    size_t n = (size_t)AS_STR(argv[0])->len;
    const char *h = AS_STR(argv[0])->dp;
    if (n % 2) return vm_set_error(vm, E_VALUE, "sslcore.unhex: odd length");
    unsigned char *b = malloc(n / 2 + 1);
    if (!b) return vm_set_error(vm, E_MEMORY, "out of memory");
    for (size_t i = 0; i < n; i++) {
        char c = h[i];
        int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
        if (v < 0) { free(b); return vm_set_error(vm, E_VALUE, "sslcore.unhex: bad digit"); }
        if (i % 2 == 0) b[i / 2] = (unsigned char)(v << 4); else b[i / 2] = (unsigned char)(b[i / 2] | v);
    }
    *ret = typed_u8_from(vm, b, n / 2);
    free(b);
    return 0;
}
static int sc_from_str(VM *vm, int argc, SpValue *argv, SpValue *ret) {   /* the UTF-8 bytes of a string */
    (void)argc;
    if (need_str(vm, argv[0], "s")) return 1;
    *ret = typed_u8_from(vm, (const unsigned char *)AS_STR(argv[0])->dp, (size_t)AS_STR(argv[0])->len);
    return 0;
}
static int sc_to_str(VM *vm, int argc, SpValue *argv, SpValue *ret) {     /* bytes -> string; bytes that are not UTF-8 are replaced by '?' */
    (void)argc;
    NEED(a, 0, "bytes");
    char *s = malloc(a.n + 1);
    if (!s) { DONE(a); return vm_set_error(vm, E_MEMORY, "out of memory"); }
    for (size_t i = 0; i < a.n; i++) s[i] = a.p[i] >= 0x80 ? '?' : (char)a.p[i];
    *ret = vstr(vm, s, a.n);
    free(s);
    DONE(a);
    return 0;
}

static int sc_inflate(VM *vm, int argc, SpValue *argv, SpValue *ret) {   /* zlib stream -> bytes; nil when the data is broken */
    NEED(d, 0, "data");
    int64_t max = 1 << 30;
    if (argc > 1 && need_int(vm, argv[1], "max", &max)) { DONE(d); return 1; }
    uint8_t *out = NULL;
    size_t n = 0;
    int r = ssl_zlib_inflate(d.p, d.n, &out, &n, (size_t)max);
    DONE(d);
    if (r) { *ret = v_nil(); return 0; }
    *ret = typed_u8_from(vm, out, n);
    free(out);
    return 0;
}

const NativeDesc lib_sslcore_fns[] = {
    {"inflate", 1, 2, sc_inflate},
    {"hash", 2, 2, sc_hash}, {"hmac", 3, 3, sc_hmac}, {"hkdf_extract", 3, 3, sc_hkdf_extract}, {"hkdf_expand", 4, 4, sc_hkdf_expand},
    {"gcm_seal", 4, 4, sc_gcm_seal}, {"gcm_open", 4, 4, sc_gcm_open}, {"chacha_seal", 4, 4, sc_chacha_seal}, {"chacha_open", 4, 4, sc_chacha_open},
    {"x25519", 2, 2, sc_x25519}, {"x25519_base", 1, 1, sc_x25519_base},
    {"ed25519_pub", 1, 1, sc_ed_pub}, {"ed25519_sign", 2, 2, sc_ed_sign}, {"ed25519_verify", 3, 3, sc_ed_verify},
    {"rsa_public", 3, 3, sc_rsa_public}, {"ecdsa_verify", 5, 5, sc_ecdsa_verify}, {"ecdh", 3, 3, sc_ecdh}, {"ec_pub", 2, 2, sc_ec_pub},
    {"random", 1, 1, sc_random}, {"seed", 1, 1, sc_seed},
    {"concat", 1, 1, sc_concat}, {"eq", 2, 2, sc_eq}, {"hex", 1, 1, sc_hex}, {"unhex", 1, 1, sc_unhex}, {"from_str", 1, 1, sc_from_str}, {"to_str", 1, 1, sc_to_str},
    {NULL, 0, 0, NULL}};
