/* _ffi: foreign function interface primitives (SPEC 15.15).
 *
 * Lets Sprint code call C functions (and C++ functions exported with extern "C") in shared
 * libraries, read and write raw memory, and pass Sprint functions to C as callbacks. The Sprint
 * module `ffi` (stdlib/ffi.sp) builds the friendly API (cdef, structs, arrays) on top of these.
 *
 * Without libffi, calls use the register calling convention of the two supported ABIs
 * (System V x86-64 and AAPCS64): up to 6 integer/pointer and 8 floating-point arguments, which
 * travel in registers independently of each other, so one variadic-prototype cast covers every
 * non-struct signature. Everything here requires the `ffi` capability and is unsafe by nature:
 * a wrong prototype or address crashes the process. It is never available in deterministic mode. */
#define _POSIX_C_SOURCE 200809L
#include "sp.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__x86_64__)
#define FFI_STRUCT_BY_VALUE 1
#else
#define FFI_STRUCT_BY_VALUE 0
#endif
#if defined(__x86_64__) || defined(__aarch64__)
#define FFI_SUPPORTED 1
#else
#define FFI_SUPPORTED 0
#endif

enum { MAX_INT_ARGS = 6, MAX_FP_ARGS = 8, MAX_ARGS = 32 };

/* ---- type codes ------------------------------------------------------------------ */
typedef int CType;
enum { C_VOID, C_I8, C_U8, C_I16, C_U16, C_I32, C_U32, C_I64, C_U64, C_F32, C_F64, C_PTR, C_STR, C_BAD, C_STRUCT };

static CType parse_type(const char *s, size_t n) {
    static const struct { const char *name; CType t; } tab[] = {
        {"v", C_VOID}, {"i8", C_I8}, {"u8", C_U8}, {"i16", C_I16}, {"u16", C_U16}, {"i32", C_I32}, {"u32", C_U32},
        {"i64", C_I64}, {"u64", C_U64}, {"f32", C_F32}, {"f64", C_F64}, {"p", C_PTR}, {"s", C_STR}};
    for (size_t i = 0; i < sizeof tab / sizeof tab[0]; i++)
        if (strlen(tab[i].name) == n && memcmp(tab[i].name, s, n) == 0) return tab[i].t;
    return C_BAD;
}

static int is_fp(CType t) { return t == C_F32 || t == C_F64; }

static size_t type_size(CType t) {
    switch (t) {
    case C_I8: case C_U8: return 1;
    case C_I16: case C_U16: return 2;
    case C_I32: case C_U32: case C_F32: return 4;
    default: return 8;
    }
}

/* A struct passed by value (System V x86-64, at most 16 bytes): "S<size><class>..." with one class
 * letter per eightbyte, I = INTEGER, D = SSE. The argument is the struct's address. */
typedef struct SInfo {
    int size;
    int ncls;
    char cls[2];
} SInfo;

typedef struct Sig {
    CType ret;
    SInfo rinfo;
    CType args[MAX_ARGS];
    SInfo ainfo[MAX_ARGS];
    int nargs;
    int variadic;
} Sig;

static int parse_struct_type(const char *s, size_t n, SInfo *out) {
    if (n < 3 || s[0] != 'S') return 0;
    size_t i = 1;
    int size = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9') { size = size * 10 + (s[i] - '0'); i++; }
    if (size < 1 || size > 16 || i == n) return 0;
    out->size = size;
    out->ncls = 0;
    for (; i < n; i++) {
        if ((s[i] != 'I' && s[i] != 'D') || out->ncls == 2) return 0;
        out->cls[out->ncls++] = s[i];
    }
    return out->ncls == (size + 7) / 8;
}

/* "ret:arg,arg,...": e.g. "f64:f64,f64", "i32:s,...", "v:" */
static int parse_sig(VM *vm, const SString *s, Sig *out) {
    const char *p = s->dp, *end = s->dp + s->len;
    const char *colon = memchr(p, ':', s->len);
    if (!colon) return vm_set_error(vm, E_VALUE, "bad ffi signature '%s' (expected \"ret:arg,arg\")", s->dp);
    out->ret = parse_type(p, (size_t)(colon - p));
    out->nargs = 0;
    out->variadic = 0;
    if (out->ret == C_BAD && parse_struct_type(p, (size_t)(colon - p), &out->rinfo)) out->ret = C_STRUCT;
    if (out->ret == C_BAD) return vm_set_error(vm, E_VALUE, "bad ffi return type in '%s'", s->dp);
    if (out->ret == C_STRUCT && !FFI_STRUCT_BY_VALUE) return vm_set_error(vm, E_RUNTIME, "structs by value need the System V x86-64 ABI");
    p = colon + 1;
    while (p < end) {
        const char *comma = memchr(p, ',', (size_t)(end - p));
        const char *e = comma ? comma : end;
        if (e - p == 3 && memcmp(p, "...", 3) == 0) {
            out->variadic = 1;
        } else {
            CType t = parse_type(p, (size_t)(e - p));
            if (t == C_BAD && out->nargs < MAX_ARGS && parse_struct_type(p, (size_t)(e - p), &out->ainfo[out->nargs])) {
                t = C_STRUCT;
                if (!FFI_STRUCT_BY_VALUE) return vm_set_error(vm, E_RUNTIME, "structs by value need the System V x86-64 ABI");
            }
            if (t == C_BAD || t == C_VOID || out->variadic) return vm_set_error(vm, E_VALUE, "bad ffi argument type in '%s'", s->dp);
            if (out->nargs == MAX_ARGS) return vm_set_error(vm, E_VALUE, "too many ffi parameters");
            out->args[out->nargs++] = t;
        }
        p = comma ? comma + 1 : end;
    }
    return 0;
}

/* ---- capability ------------------------------------------------------------------ */
static int need_cap(VM *vm) {
    if (!FFI_SUPPORTED) return vm_set_error(vm, E_RUNTIME, "ffi is not supported on this platform (x86-64 and AArch64 only)");
    if (!(vm->caps & CAP_FFI) || vm->deterministic)
        return vm_set_error(vm, E_PERM, "ffi is not permitted (run with --allow-ffi; it is never available with --deterministic)");
    return 0;
}

/* ---- buffers --------------------------------------------------------------------- */
typedef struct CBuf {
    size_t n;
    unsigned char b[];
} CBuf;
static const NativeClass cbuf_class;
static const NativeClass clib_class;

static CBuf *self_buf(VM *vm, SpValue v) {
    if (v.type != T_NATIVE || AS_NATIVE(v)->cls != &cbuf_class) {
        (void)vm_set_error(vm, E_TYPE, "expected an ffi buffer, not %s", type_name(v));
        return NULL;
    }
    return (CBuf *)AS_NATIVE(v)->data;
}

static int a_int64(VM *vm, SpValue v, const char *what, int64_t *out) {
    if (v.type != T_INT) return vm_set_error(vm, E_TYPE, "%s must be an int, not %s", what, type_name(v));
    *out = v.as.i;
    return 0;
}

static int a_type(VM *vm, SpValue v, CType *out) {
    if (v.type != T_STRING) return vm_set_error(vm, E_TYPE, "type must be a string like \"i32\", not %s", type_name(v));
    *out = parse_type(AS_STR(v)->dp, AS_STR(v)->len);
    if (*out == C_BAD || *out == C_VOID || *out == C_STR) return vm_set_error(vm, E_VALUE, "bad memory type '%s'", AS_STR(v)->dp);
    return 0;
}

/* load / store a scalar of type t at p (memcpy: any alignment) */
static SpValue load_scalar(CType t, const void *p) {
    switch (t) {
    case C_I8: { int8_t x; memcpy(&x, p, 1); return v_int(x); }
    case C_U8: { uint8_t x; memcpy(&x, p, 1); return v_int(x); }
    case C_I16: { int16_t x; memcpy(&x, p, 2); return v_int(x); }
    case C_U16: { uint16_t x; memcpy(&x, p, 2); return v_int(x); }
    case C_I32: { int32_t x; memcpy(&x, p, 4); return v_int(x); }
    case C_U32: { uint32_t x; memcpy(&x, p, 4); return v_int(x); }
    case C_F32: { float x; memcpy(&x, p, 4); return v_float((double)x); }
    case C_F64: { double x; memcpy(&x, p, 8); return v_float(x); }
    default: { int64_t x; memcpy(&x, p, 8); return v_int(x); }
    }
}

static int store_scalar(VM *vm, CType t, void *p, SpValue v) {
    if (is_fp(t)) {
        double d;
        if (v.type == T_FLOAT) d = v.as.f;
        else if (v.type == T_INT) d = (double)v.as.i;
        else return vm_set_error(vm, E_TYPE, "expected a number, not %s", type_name(v));
        if (t == C_F32) { float f = (float)d; memcpy(p, &f, 4); }
        else memcpy(p, &d, 8);
        return 0;
    }
    int64_t i;
    if (v.type == T_INT) i = v.as.i;
    else if (v.type == T_BOOL) i = v.as.b ? 1 : 0;
    else if (v.type == T_NIL && t == C_PTR) i = 0;
    else return vm_set_error(vm, E_TYPE, "expected an int, not %s", type_name(v));
    switch (type_size(t)) {
    case 1: { uint8_t x = (uint8_t)i; memcpy(p, &x, 1); break; }
    case 2: { uint16_t x = (uint16_t)i; memcpy(p, &x, 2); break; }
    case 4: { uint32_t x = (uint32_t)i; memcpy(p, &x, 4); break; }
    default: memcpy(p, &i, 8); break;
    }
    return 0;
}

static int cb_alloc(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (need_cap(vm)) return 1;
    int64_t n = 0;
    if (a_int64(vm, argv[0], "size", &n)) return 1;
    if (n < 0 || n > ((int64_t)1 << 30)) return vm_set_error(vm, E_VALUE, "buffer size must be 0..2^30");
    SNativeObj *o = vm_new_native_obj(vm, &cbuf_class, sizeof(CBuf) + (size_t)n + 1);
    CBuf *b = (CBuf *)o->data;
    b->n = (size_t)n;
    memset(b->b, 0, (size_t)n + 1);
    *ret = v_obj(T_NATIVE, o);
    return 0;
}

static int bm_ptr(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    CBuf *b = self_buf(vm, argv[0]);
    if (!b) return 1;
    *ret = v_int((int64_t)(uintptr_t)b->b);
    return 0;
}
static int bm_size(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    CBuf *b = self_buf(vm, argv[0]);
    if (!b) return 1;
    *ret = v_int((int64_t)b->n);
    return 0;
}
static int buf_range(VM *vm, CBuf *b, int64_t off, size_t len) {
    if (off < 0 || (uint64_t)off > b->n || len > b->n - (size_t)off)
        return vm_set_error(vm, E_INDEX, "ffi buffer access at %lld (%zu bytes) is outside the %zu-byte buffer", (long long)off, len, b->n);
    return 0;
}
static int bm_get(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    CBuf *b = self_buf(vm, argv[0]);
    CType t;
    int64_t off = 0;
    if (!b || a_type(vm, argv[1], &t) || a_int64(vm, argv[2], "offset", &off) || buf_range(vm, b, off, type_size(t))) return 1;
    *ret = load_scalar(t, b->b + off);
    return 0;
}
static int bm_set(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    CBuf *b = self_buf(vm, argv[0]);
    CType t;
    int64_t off = 0;
    if (!b || a_type(vm, argv[1], &t) || a_int64(vm, argv[2], "offset", &off) || buf_range(vm, b, off, type_size(t))) return 1;
    return store_scalar(vm, t, b->b + off, argv[3]);
}
static int bm_str(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    CBuf *b = self_buf(vm, argv[0]);
    int64_t off = 0, n = -1;
    if (!b) return 1;
    if (argc > 1 && a_int64(vm, argv[1], "offset", &off)) return 1;
    if (argc > 2 && a_int64(vm, argv[2], "length", &n)) return 1;
    if (off < 0 || (uint64_t)off > b->n) return vm_set_error(vm, E_INDEX, "ffi buffer offset out of range");
    size_t avail = b->n - (size_t)off;
    size_t len;
    if (n < 0) { len = 0; while (len < avail && b->b[off + (int64_t)len]) len++; }
    else { if ((uint64_t)n > avail) return vm_set_error(vm, E_INDEX, "ffi buffer read out of range"); len = (size_t)n; }
    *ret = v_obj(T_STRING, vm_new_string(vm, (const char *)b->b + off, len));
    return 0;
}
static int bm_put(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    CBuf *b = self_buf(vm, argv[0]);
    int64_t off = 0;
    if (!b || a_int64(vm, argv[1], "offset", &off)) return 1;
    if (argv[2].type != T_STRING) return vm_set_error(vm, E_TYPE, "put expects a string, not %s", type_name(argv[2]));
    if (buf_range(vm, b, off, AS_STR(argv[2])->len)) return 1;
    memcpy(b->b + off, AS_STR(argv[2])->dp, AS_STR(argv[2])->len);
    return 0;
}
static const NativeDesc cbuf_methods[] = {
    {"ptr", 1, 1, bm_ptr}, {"size", 1, 1, bm_size}, {"get", 3, 3, bm_get}, {"set", 4, 4, bm_set},
    {"str", 1, 3, bm_str}, {"put", 3, 3, bm_put}, {NULL, 0, 0, NULL}};
static const NativeClass cbuf_class = {"ffi_buffer", cbuf_methods, NULL, NULL};

/* ---- raw memory ------------------------------------------------------------------ */
static int a_addr(VM *vm, SpValue v, void **out) {
    int64_t a = 0;
    if (a_int64(vm, v, "address", &a)) return 1;
    if (a == 0) return vm_set_error(vm, E_VALUE, "null pointer");
    *out = (void *)(uintptr_t)a;
    return 0;
}
static int f_peek(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    void *p;
    CType t;
    if (need_cap(vm) || a_addr(vm, argv[0], &p) || a_type(vm, argv[1], &t)) return 1;
    *ret = load_scalar(t, p);
    return 0;
}
static int f_poke(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    void *p;
    CType t;
    if (need_cap(vm) || a_addr(vm, argv[0], &p) || a_type(vm, argv[1], &t)) return 1;
    return store_scalar(vm, t, p, argv[2]);
}
/* string_at(addr, n = -1): n bytes, or up to the NUL terminator */
static int f_string_at(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    void *p;
    int64_t n = -1;
    if (need_cap(vm) || a_addr(vm, argv[0], &p)) return 1;
    if (argc > 1 && a_int64(vm, argv[1], "length", &n)) return 1;
    size_t len = n < 0 ? strlen((const char *)p) : (size_t)n;
    *ret = v_obj(T_STRING, vm_new_string(vm, (const char *)p, len));
    return 0;
}
static int f_copy_in(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    void *p;
    if (need_cap(vm) || a_addr(vm, argv[0], &p)) return 1;
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "copy_in expects a string, not %s", type_name(argv[1]));
    memcpy(p, AS_STR(argv[1])->dp, AS_STR(argv[1])->len);
    return 0;
}

/* ---- libraries and symbols ------------------------------------------------------- */
static int f_open(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (need_cap(vm)) return 1;
    const char *path = NULL;
    if (argv[0].type == T_STRING) path = str_z(vm, AS_STR(argv[0]));
    else if (argv[0].type != T_NIL) return vm_set_error(vm, E_TYPE, "library name must be a string or nil, not %s", type_name(argv[0]));
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char *why = dlerror();
        return vm_set_error(vm, E_IO, "cannot load library '%s': %s", path ? path : "(main program)", why ? why : "unknown error");
    }
    SNativeObj *o = vm_new_native_obj(vm, &clib_class, sizeof h);
    memcpy(o->data, &h, sizeof h);
    *ret = v_obj(T_NATIVE, o);
    return 0;
}
static int f_sym(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (need_cap(vm)) return 1;
    if (argv[0].type != T_NATIVE || AS_NATIVE(argv[0])->cls != &clib_class) return vm_set_error(vm, E_TYPE, "expected a library from ffi.open, not %s", type_name(argv[0]));
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "symbol name must be a string, not %s", type_name(argv[1]));
    void *h;
    memcpy(&h, AS_NATIVE(argv[0])->data, sizeof h);
    void *s = dlsym(h, str_z(vm, AS_STR(argv[1])));
    if (!s) return vm_set_error(vm, E_NAME, "symbol '%s' not found in the library", AS_STR(argv[1])->dp);
    *ret = v_int((int64_t)(uintptr_t)s);
    return 0;
}
static const NativeClass clib_class = {"ffi_library", NULL, NULL, NULL};

/* ---- callbacks (C calls Sprint) -------------------------------------------------- */
enum { NCB = 16 };
typedef struct CbSlot {
    VM *vm;
    SpValue fn;
    Sig sig;
    int used;
} CbSlot;
static CbSlot cb_i[NCB]; /* integer / pointer / void returns */
static CbSlot cb_d[NCB]; /* floating-point returns */
static int g_cb_failed;  /* a callback raised: the error stays pending in the VM until the outer call returns */

static void cb_collect(CbSlot *s, const int64_t *ia, const double *da, SpValue *out, int *nout) {
    int ni = 0, nd = 0, n = 0;
    for (int i = 0; i < s->sig.nargs && n < MAX_ARGS; i++) {
        CType t = s->sig.args[i];
        if (is_fp(t)) {
            double d = nd < MAX_FP_ARGS ? da[nd] : 0;
            nd++;
            if (t == C_F32) { float f; memcpy(&f, &d, 4); out[n++] = v_float((double)f); }
            else out[n++] = v_float(d);
        } else {
            int64_t x = ni < MAX_INT_ARGS ? ia[ni] : 0;
            ni++;
            switch (t) {
            case C_I8: out[n++] = v_int((int8_t)x); break;
            case C_U8: out[n++] = v_int((uint8_t)x); break;
            case C_I16: out[n++] = v_int((int16_t)x); break;
            case C_U16: out[n++] = v_int((uint16_t)x); break;
            case C_I32: out[n++] = v_int((int32_t)x); break;
            case C_U32: out[n++] = v_int((uint32_t)x); break;
            case C_STR: out[n++] = x ? v_obj(T_STRING, vm_new_string(s->vm, (const char *)(uintptr_t)x, strlen((const char *)(uintptr_t)x))) : v_nil(); break;
            default: out[n++] = v_int(x); break;
            }
        }
    }
    *nout = n;
}

static int64_t cb_run_i(CbSlot *s, const int64_t *ia, const double *da) {
    if (!s->used || g_cb_failed) return 0;
    SpValue args[MAX_ARGS], r = v_nil();
    int n = 0;
    cb_collect(s, ia, da, args, &n);
    if (vm_call(s->vm, s->fn, n, args, &r)) { g_cb_failed = 1; return 0; }
    if (s->sig.ret == C_VOID) return 0;
    if (r.type == T_INT) return r.as.i;
    if (r.type == T_BOOL) return r.as.b ? 1 : 0;
    if (r.type == T_NIL) return 0;
    (void)vm_set_error(s->vm, E_TYPE, "ffi callback must return an int, not %s", type_name(r));
    g_cb_failed = 1;
    return 0;
}
static double cb_run_d(CbSlot *s, const int64_t *ia, const double *da) {
    if (!s->used || g_cb_failed) return 0;
    SpValue args[MAX_ARGS], r = v_nil();
    int n = 0;
    cb_collect(s, ia, da, args, &n);
    if (vm_call(s->vm, s->fn, n, args, &r)) { g_cb_failed = 1; return 0; }
    double d = 0;
    if (r.type == T_FLOAT) d = r.as.f;
    else if (r.type == T_INT) d = (double)r.as.i;
    else { (void)vm_set_error(s->vm, E_TYPE, "ffi callback must return a number, not %s", type_name(r)); g_cb_failed = 1; return 0; }
    if (s->sig.ret == C_F32) { float f = (float)d; uint64_t bits = 0; memcpy(&bits, &f, 4); memcpy(&d, &bits, 8); }
    return d;
}

#define TR(K) \
    static int64_t tri##K(int64_t a0, int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5, double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7) { \
        const int64_t ia[6] = {a0, a1, a2, a3, a4, a5}; const double da[8] = {d0, d1, d2, d3, d4, d5, d6, d7}; return cb_run_i(&cb_i[K], ia, da); } \
    static double trd##K(int64_t a0, int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5, double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7) { \
        const int64_t ia[6] = {a0, a1, a2, a3, a4, a5}; const double da[8] = {d0, d1, d2, d3, d4, d5, d6, d7}; return cb_run_d(&cb_d[K], ia, da); }
TR(0) TR(1) TR(2) TR(3) TR(4) TR(5) TR(6) TR(7) TR(8) TR(9) TR(10) TR(11) TR(12) TR(13) TR(14) TR(15)

typedef int64_t (*TrampI)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, double, double, double, double, double, double, double, double);
typedef double (*TrampD)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, double, double, double, double, double, double, double, double);
static const TrampI tramp_i[NCB] = {tri0, tri1, tri2, tri3, tri4, tri5, tri6, tri7, tri8, tri9, tri10, tri11, tri12, tri13, tri14, tri15};
static const TrampD tramp_d[NCB] = {trd0, trd1, trd2, trd3, trd4, trd5, trd6, trd7, trd8, trd9, trd10, trd11, trd12, trd13, trd14, trd15};

/* callback(fn, sig) -> address. The caller keeps `fn` alive (ffi.sp stores it). */
static int f_callback(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (need_cap(vm)) return 1;
    if (argv[0].type != T_FUNCTION) return vm_set_error(vm, E_TYPE, "callback must be a function, not %s", type_name(argv[0]));
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "signature must be a string");
    Sig sig;
    if (parse_sig(vm, AS_STR(argv[1]), &sig)) return 1;
    int ni = 0, nd = 0;
    if (sig.ret == C_STRUCT) return vm_set_error(vm, E_VALUE, "callbacks cannot return structs");
    for (int i = 0; i < sig.nargs; i++) {
        if (sig.args[i] == C_STRUCT) return vm_set_error(vm, E_VALUE, "callbacks cannot take structs by value");
        if (is_fp(sig.args[i])) nd++; else ni++;
    }
    if (sig.variadic || ni > MAX_INT_ARGS || nd > MAX_FP_ARGS) return vm_set_error(vm, E_VALUE, "callback signature too large (max 6 integer and 8 floating-point parameters, no varargs)");
    CbSlot *pool = is_fp(sig.ret) ? cb_d : cb_i;
    for (int k = 0; k < NCB; k++) {
        if (pool[k].used) continue;
        pool[k].vm = vm;
        pool[k].fn = argv[0];
        pool[k].sig = sig;
        pool[k].used = 1;
        uintptr_t a;
        if (is_fp(sig.ret)) { TrampD f = tramp_d[k]; memcpy(&a, &f, sizeof a); }
        else { TrampI f = tramp_i[k]; memcpy(&a, &f, sizeof a); }
        *ret = v_int((int64_t)a);
        return 0;
    }
    return vm_set_error(vm, E_RUNTIME, "no free ffi callback slots (at most %d per return kind; release some)", NCB);
}
static int f_release_callback(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    if (need_cap(vm)) return 1;
    int64_t a = 0;
    if (a_int64(vm, argv[0], "address", &a)) return 1;
    for (int k = 0; k < NCB; k++) {
        uintptr_t x;
        TrampI fi = tramp_i[k];
        TrampD fd = tramp_d[k];
        memcpy(&x, &fi, sizeof x);
        if ((int64_t)x == a) { cb_i[k].used = 0; return 0; }
        memcpy(&x, &fd, sizeof x);
        if ((int64_t)x == a) { cb_d[k].used = 0; return 0; }
    }
    return vm_set_error(vm, E_VALUE, "not an ffi callback address");
}

/* ---- calls ----------------------------------------------------------------------- */
typedef int64_t (*FnI)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, ...);
typedef double (*FnD)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, ...);

/* call(address, sig, args_array) */
static int do_call(VM *vm, int64_t addr, const Sig *psig, const SpValue *items, int64_t nargs, SpValue *ret);

static int f_call(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (need_cap(vm)) return 1;
    int64_t addr = 0;
    if (a_int64(vm, argv[0], "address", &addr)) return 1;
    if (addr == 0) return vm_set_error(vm, E_VALUE, "null function pointer");
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "signature must be a string");
    if (argv[2].type != T_ARRAY) return vm_set_error(vm, E_TYPE, "arguments must be an array");
    Sig sig;
    if (parse_sig(vm, AS_STR(argv[1]), &sig)) return 1;
    array_unpack(vm, AS_ARRAY(argv[2]));   /* the call reads boxed values */
    return do_call(vm, addr, &sig, array_boxed(AS_ARRAY(argv[2])), AS_ARRAY(argv[2])->len, ret);
}

/* The call itself, shared by f_call (signature parsed per call) and prepared functions (parsed once, see prep). */
static int do_call(VM *vm, int64_t addr, const Sig *psig, const SpValue *items, int64_t nargs, SpValue *ret) {
    if (nargs < psig->nargs || (!psig->variadic && nargs > psig->nargs))
        return vm_set_error(vm, E_TYPE, "ffi call expects %s%d argument%s, got %lld", psig->variadic ? "at least " : "", psig->nargs, psig->nargs == 1 ? "" : "s", (long long)nargs);
    if (nargs > MAX_ARGS) return vm_set_error(vm, E_VALUE, "too many ffi arguments");
    int64_t ia[MAX_INT_ARGS] = {0};
    double da[MAX_FP_ARGS] = {0};
    int ni = 0, nd = 0;
    for (int i = 0; i < (int)nargs; i++) {
        SpValue v = items[i];
        CType t;
        if (i < psig->nargs) t = psig->args[i];
        else t = v.type == T_FLOAT ? C_F64 : v.type == T_STRING ? C_STR : C_I64; /* variadic extras: default promotions */
        if (t == C_STRUCT) {
            const SInfo *si = &psig->ainfo[i];
            if (v.type != T_INT || v.as.i == 0) return vm_set_error(vm, E_TYPE, "argument %d: a struct by value needs the address of the struct", i + 1);
            const unsigned char *src = (const unsigned char *)(uintptr_t)v.as.i;
            int need_i = 0, need_d = 0;
            for (int k = 0; k < si->ncls; k++) { if (si->cls[k] == 'D') need_d++; else need_i++; }
            if (ni + need_i > MAX_INT_ARGS || nd + need_d > MAX_FP_ARGS) return vm_set_error(vm, E_VALUE, "struct argument does not fit in the argument registers");
            for (int k = 0; k < si->ncls; k++) {
                size_t chunk = (size_t)(si->size - 8 * k) < 8 ? (size_t)(si->size - 8 * k) : 8;
                uint64_t w = 0;
                memcpy(&w, src + 8 * k, chunk);
                if (si->cls[k] == 'D') memcpy(&da[nd++], &w, 8);
                else ia[ni++] = (int64_t)w;
            }
            continue;
        }
        if (is_fp(t)) {
            if (nd == MAX_FP_ARGS) return vm_set_error(vm, E_VALUE, "too many floating-point ffi arguments (max %d)", MAX_FP_ARGS);
            uint64_t bits = 0;
            if (store_scalar(vm, t, &bits, v)) return 1;
            memcpy(&da[nd++], &bits, 8);
            continue;
        }
        if (ni == MAX_INT_ARGS) return vm_set_error(vm, E_VALUE, "too many integer/pointer ffi arguments (max %d)", MAX_INT_ARGS);
        int64_t x = 0;
        if (t == C_STR || t == C_PTR) {
            if (v.type == T_STRING) { const char *zp = str_z(vm, AS_STR(v)); x = (int64_t)(uintptr_t)zp; }
            else if (v.type == T_NATIVE && AS_NATIVE(v)->cls == &cbuf_class) x = (int64_t)(uintptr_t)((CBuf *)AS_NATIVE(v)->data)->b;
            else if (v.type == T_NIL) x = 0;
            else if (v.type == T_INT) x = v.as.i;
            else return vm_set_error(vm, E_TYPE, "argument %d: expected a pointer (int, string, buffer or nil), not %s", i + 1, type_name(v));
        } else {
            uint64_t bits = 0;
            if (store_scalar(vm, C_I64, &bits, v)) return 1;
            x = (int64_t)bits;
        }
        ia[ni++] = x;
    }
    void *fp = (void *)(uintptr_t)addr;
    int saved = g_cb_failed;
    g_cb_failed = 0;
    int64_t ri = 0;
    double rd = 0;
    unsigned char sret[16] = {0};
    if (psig->ret == C_STRUCT) {
#if FFI_STRUCT_BY_VALUE
        const SInfo *si = &psig->rinfo;
        typedef struct { int64_t a, b; } RII;
        typedef struct { double a, b; } RDD;
        typedef struct { int64_t a; double b; } RID;
        typedef struct { double a; int64_t b; } RDI;
        typedef RII (*FnII)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, ...);
        typedef RDD (*FnDD)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, ...);
        typedef RID (*FnID)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, ...);
        typedef RDI (*FnDI)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, ...);
        if (si->ncls == 1 && si->cls[0] == 'I') {
            FnI f; memcpy(&f, &fp, sizeof f);
            int64_t r = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
            memcpy(sret, &r, 8);
        } else if (si->ncls == 1) {
            FnD f; memcpy(&f, &fp, sizeof f);
            double r = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
            memcpy(sret, &r, 8);
        } else if (si->cls[0] == 'I' && si->cls[1] == 'I') {
            FnII f; memcpy(&f, &fp, sizeof f);
            RII r = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
            memcpy(sret, &r, 16);
        } else if (si->cls[0] == 'D' && si->cls[1] == 'D') {
            FnDD f; memcpy(&f, &fp, sizeof f);
            RDD r = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
            memcpy(sret, &r, 16);
        } else if (si->cls[0] == 'I') {
            FnID f; memcpy(&f, &fp, sizeof f);
            RID r = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
            memcpy(sret, &r, 16);
        } else {
            FnDI f; memcpy(&f, &fp, sizeof f);
            RDI r = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
            memcpy(sret, &r, 16);
        }
#endif
    } else if (is_fp(psig->ret)) {
        FnD f;
        memcpy(&f, &fp, sizeof f);
        rd = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
    } else {
        FnI f;
        memcpy(&f, &fp, sizeof f);
        ri = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]);
    }
    int failed = g_cb_failed;
    g_cb_failed = saved;
    if (failed) return 1; /* the callback's error is already pending */
    switch (psig->ret) {
    case C_STRUCT: *ret = v_obj(T_STRING, vm_new_string(vm, (const char *)sret, (size_t)psig->rinfo.size)); break;
    case C_VOID: *ret = v_nil(); break;
    case C_F32: { uint64_t bits; memcpy(&bits, &rd, 8); uint32_t lo = (uint32_t)bits; float f; memcpy(&f, &lo, 4); *ret = v_float((double)f); break; }
    case C_F64: *ret = v_float(rd); break;
    case C_I8: *ret = v_int((int8_t)ri); break;
    case C_U8: *ret = v_int((uint8_t)ri); break;
    case C_I16: *ret = v_int((int16_t)ri); break;
    case C_U16: *ret = v_int((uint16_t)ri); break;
    case C_I32: *ret = v_int((int32_t)ri); break;
    case C_U32: *ret = v_int((uint32_t)ri); break;
    case C_STR: *ret = ri ? v_obj(T_STRING, vm_new_string(vm, (const char *)(uintptr_t)ri, strlen((const char *)(uintptr_t)ri))) : v_nil(); break;
    default: *ret = v_int(ri); break;
    }
    return 0;
}

static int f_abi(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv;
#if defined(__x86_64__)
    *ret = v_obj(T_STRING, vm_new_string(vm, "x86_64", 6));
#elif defined(__aarch64__)
    *ret = v_obj(T_STRING, vm_new_string(vm, "aarch64", 7));
#else
    *ret = v_obj(T_STRING, vm_new_string(vm, "none", 4));
#endif
    return 0;
}

/* ---- prepared functions ------------------------------------------------------------
 * prep(address, sig) parses the signature once and returns a native function that calls the address directly: no Sprint
 * wrapper, no argument array, no per-call parse. The descriptor is the function's NativeDesc (d is the first member), found
 * again through argv[-1], the callee slot every native call site leaves below its arguments. Descriptors are cached by
 * (address, signature), so repeatedly preparing the same function allocates nothing. */
typedef struct PrepFn {
    NativeDesc d; /* must stay first */
    int64_t addr;
    Sig sig;
    char *key;
    int jit_ok; /* numeric-only signature: see ffi_jit_safe */
} PrepFn;
static PrepFn **g_prep;
static size_t g_nprep, g_capprep;

/* Numeric-only signatures (jit_ok) take this short path: arguments of the expected kind are moved straight into the
 * register arrays; anything unexpected (a wrong count or type, an out-of-range float for an int...) goes to do_call, which
 * reports it with the usual message. */
static int prep_invoke(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    const PrepFn *p = (const PrepFn *)(const void *)AS_FUNC(argv[-1])->nat;
    if (need_cap(vm)) return 1;
    const Sig *sg = &p->sig;
    if (p->jit_ok && argc == sg->nargs) {
        int64_t ia[MAX_INT_ARGS] = {0};
        double da[MAX_FP_ARGS] = {0};
        int ni = 0, nd = 0, ok = 1;
        for (int i = 0; i < argc && ok; i++) {
            const SpValue v = argv[i];
            switch (sg->args[i]) {
            case C_F64:
                if (nd == MAX_FP_ARGS) ok = 0;
                else if (v.type == T_FLOAT) da[nd++] = v.as.f;
                else if (v.type == T_INT) da[nd++] = (double)v.as.i;
                else ok = 0;
                break;
            case C_I64: case C_U64:
                if (ni == MAX_INT_ARGS || v.type != T_INT) ok = 0;
                else ia[ni++] = v.as.i;
                break;
            default: ok = 0; break; /* narrower ints and float: the general converter */
            }
        }
        if (ok) {
            void *fp = (void *)(uintptr_t)p->addr;
            int saved = g_cb_failed;
            g_cb_failed = 0;
            int64_t ri = 0;
            double rd = 0;
            const int fpret = is_fp(sg->ret);
            if (fpret) { FnD f; memcpy(&f, &fp, sizeof f); rd = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]); }
            else { FnI f; memcpy(&f, &fp, sizeof f); ri = f(ia[0], ia[1], ia[2], ia[3], ia[4], ia[5], da[0], da[1], da[2], da[3], da[4], da[5], da[6], da[7]); }
            const int failed = g_cb_failed;
            g_cb_failed = saved;
            if (failed) return 1;
            switch (sg->ret) {
            case C_F64: *ret = v_float(rd); return 0;
            case C_I64: case C_U64: *ret = v_int(ri); return 0;
            case C_I32: *ret = v_int((int32_t)ri); return 0;
            case C_VOID: *ret = v_nil(); return 0;
            default: break;
            }
            /* other return kinds: finish through the shared conversion below */
            switch (sg->ret) {
            case C_F32: { uint64_t bits; memcpy(&bits, &rd, 8); uint32_t lo = (uint32_t)bits; float f; memcpy(&f, &lo, 4); *ret = v_float((double)f); return 0; }
            case C_I8: *ret = v_int((int8_t)ri); return 0;
            case C_U8: *ret = v_int((uint8_t)ri); return 0;
            case C_I16: *ret = v_int((int16_t)ri); return 0;
            case C_U16: *ret = v_int((uint16_t)ri); return 0;
            case C_U32: *ret = v_int((uint32_t)ri); return 0;
            default: *ret = v_int(ri); return 0;
            }
        }
    }
    return do_call(vm, p->addr, sg, argv, argc, ret);
}

/* May compiled code call this native directly? Only for numeric-only signatures: every error is raised while the arguments
 * are converted, before the foreign function runs (so the interpreter can safely repeat the call to report it), nothing
 * is allocated (no GC while the compiled frame is unsynchronised) and C cannot re-enter Sprint (no pointer arguments, so
 * no callback address can be passed). */
int ffi_jit_safe(const NativeDesc *d) {
    return d->fn == prep_invoke && ((const PrepFn *)(const void *)d)->jit_ok;
}

int ffi_jit_info(const NativeDesc *d, FfiJit *out) {
    if (!ffi_jit_safe(d)) return 0;
    const PrepFn *p = (const PrepFn *)(const void *)d;
    int ni = 0, nd = 0;
    for (int i = 0; i < p->sig.nargs; i++) {
        switch (p->sig.args[i]) {
        case C_F64: out->cls[i] = 'd'; nd++; break;
        case C_I64: case C_U64: out->cls[i] = 'i'; ni++; break;
        default: return 0;
        }
    }
    if (ni > MAX_INT_ARGS || nd > MAX_FP_ARGS) return 0;
    switch (p->sig.ret) {
    case C_VOID: out->ret = FFJ_VOID; break;
    case C_F64: out->ret = FFJ_F64; break;
    case C_F32: out->ret = FFJ_F32; break;
    case C_I64: case C_U64: out->ret = FFJ_I64; break;
    case C_I32: out->ret = FFJ_I32; break;
    case C_U32: out->ret = FFJ_U32; break;
    case C_I16: out->ret = FFJ_I16; break;
    case C_U16: out->ret = FFJ_U16; break;
    case C_I8: out->ret = FFJ_I8; break;
    case C_U8: out->ret = FFJ_U8; break;
    default: return 0;
    }
    out->fn = (void *)(uintptr_t)p->addr;
    out->nargs = p->sig.nargs;
    return 1;
}

static int make_prepared(VM *vm, int64_t addr, const SString *sigs, SpValue *ret, int share) {
    Sig sig;
    if (parse_sig(vm, sigs, &sig)) return 1;
    PrepFn *p = NULL;
    if (share)
        for (size_t i = 0; i < g_nprep; i++)
            if (g_prep[i]->addr == addr && strlen(g_prep[i]->key) == sigs->len && memcmp(g_prep[i]->key, sigs->dp, sigs->len) == 0) { p = g_prep[i]; break; }
    if (!p) {
        p = calloc(1, sizeof *p);
        char *key = malloc(sigs->len + 1);
        if (!p || !key) { free(p); free(key); return vm_set_error(vm, E_MEMORY, "out of memory"); }
        memcpy(key, sigs->dp, sigs->len);
        key[sigs->len] = 0;
        /* argument counts are checked by do_call so that the messages stay those of the unprepared path */
        p->d = (NativeDesc){"ffi function", 0, -1, prep_invoke};
        p->addr = addr;
        p->sig = sig;
        p->key = key;
        p->jit_ok = !sig.variadic && sig.ret != C_STRUCT && sig.ret != C_STR;
        for (int i = 0; i < sig.nargs; i++)
            if (sig.args[i] == C_PTR || sig.args[i] == C_STR || sig.args[i] == C_STRUCT) p->jit_ok = 0;
        if (share) {
            if (g_nprep == g_capprep) {
                size_t nc = g_capprep ? g_capprep * 2 : 16;
                PrepFn **np = realloc(g_prep, nc * sizeof *np);
                if (!np) { free(key); free(p); return vm_set_error(vm, E_MEMORY, "out of memory"); }
                g_prep = np;
                g_capprep = nc;
            }
            g_prep[g_nprep++] = p;
        }
    }
    *ret = v_obj(T_FUNCTION, vm_new_native(vm, &p->d));
    return 0;
}

static int f_prep(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (need_cap(vm)) return 1;
    int64_t addr = 0;
    if (a_int64(vm, argv[0], "address", &addr)) return 1;
    if (addr == 0) return vm_set_error(vm, E_VALUE, "null function pointer");
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "signature must be a string");
    return make_prepared(vm, addr, AS_STR(argv[1]), ret, 1);
}

/* asm(code, sig): machine code of the host ISA, run as a C-ABI function. Needs the separate `asm` capability: running
 * arbitrary machine code is a stronger grant than calling symbols that already exist. The code is copied into its own
 * mapping that is writable while it is filled and executable (never both) afterwards; mappings live until the process
 * ends, and the total is capped. */
static size_t g_asm_total;
static int f_asm(VM *vm, int argc, SpValue *argv, SpValue *ret) {
    (void)argc;
    if (!FFI_SUPPORTED) return vm_set_error(vm, E_RUNTIME, "asm is not supported on this platform (x86-64 and AArch64 only)");
    if (!(vm->caps & CAP_ASM) || vm->deterministic)
        return vm_set_error(vm, E_PERM, "asm is not permitted (run with --allow-asm; it is never available with --deterministic)");
    if (argv[1].type != T_STRING) return vm_set_error(vm, E_TYPE, "signature must be a string");
    /* the code is a string of bytes or an array of ints 0..255 */
    size_t len = 0;
    if (argv[0].type == T_STRING) len = AS_STR(argv[0])->len;
    else if (argv[0].type == T_ARRAY) {
        const SArray *ca = AS_ARRAY(argv[0]);
        for (int64_t i = 0; i < ca->len; i++)
            if (array_get(ca, i).type != T_INT || array_get(ca, i).as.i < 0 || array_get(ca, i).as.i > 255)
                return vm_set_error(vm, E_VALUE, "machine code array element %lld is not a byte (0..255)", (long long)i);
        len = (size_t)ca->len;
    } else return vm_set_error(vm, E_TYPE, "machine code must be a string or an array of bytes, not %s", type_name(argv[0]));
    if (len == 0) return vm_set_error(vm, E_VALUE, "machine code is empty");
    size_t page = (size_t)sysconf(_SC_PAGESIZE), size = (len + page - 1) / page * page;
    if (size > ((size_t)1 << 20) || g_asm_total + size > ((size_t)64 << 20)) return vm_set_error(vm, E_VALUE, "too much machine code");
    void *mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) return vm_set_error(vm, E_MEMORY, "cannot map memory for machine code");
    if (argv[0].type == T_STRING) memcpy(mem, AS_STR(argv[0])->dp, len);
    else for (size_t i = 0; i < len; i++) ((unsigned char *)mem)[i] = (unsigned char)array_get(AS_ARRAY(argv[0]), (int64_t)i).as.i;
#if defined(__aarch64__)
    __builtin___clear_cache((char *)mem, (char *)mem + len);
#endif
    if (mprotect(mem, size, PROT_READ | PROT_EXEC) != 0) { munmap(mem, size); return vm_set_error(vm, E_MEMORY, "cannot make machine code executable"); }
    g_asm_total += size;
    return make_prepared(vm, (int64_t)(uintptr_t)mem, AS_STR(argv[1]), ret, 0);
}

const NativeDesc lib_ffi_fns[] = {
    {"open", 1, 1, f_open}, {"sym", 2, 2, f_sym}, {"call", 3, 3, f_call}, {"alloc", 1, 1, cb_alloc},
    {"peek", 2, 2, f_peek}, {"poke", 3, 3, f_poke}, {"string_at", 1, 2, f_string_at}, {"copy_in", 2, 2, f_copy_in},
    {"callback", 2, 2, f_callback}, {"release_callback", 1, 1, f_release_callback}, {"abi", 0, 0, f_abi},
    {"prep", 2, 2, f_prep}, {"asm", 2, 2, f_asm},
    {NULL, 0, 0, NULL}};
