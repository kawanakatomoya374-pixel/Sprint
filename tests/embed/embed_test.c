/* Tests for the C embedding API (SPEC 20). Built against libsprint.a. */
#include "sprint.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail, g_total;
#define CHECK(cond)                                                              \
    do {                                                                         \
        g_total++;                                                               \
        if (!(cond)) {                                                           \
            g_fail++;                                                            \
            (void)fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                        \
    } while (0)

/* ---- in-memory module loader and captured stdout ---- */
typedef struct Src {
    const char *name, *text;
} Src;
typedef struct Host {
    const Src *srcs;
    size_t nsrcs;
    char out[8192], err[1024];
    size_t outn, errn;
} Host;

static SpStatus ld(void *ud, const char *name, const char **src, size_t *len, const char **disp) {
    const Host *h = ud;
    for (size_t i = 0; i < h->nsrcs; i++)
        if (strcmp(h->srcs[i].name, name) == 0) {
            *src = h->srcs[i].text;
            *len = strlen(h->srcs[i].text);
            *disp = h->srcs[i].name;
            return SP_OK;
        }
    return SP_E_IMPORT;
}
static size_t wr(void *ud, int stream, const char *d, size_t n) {
    Host *h = ud;
    char *buf = stream == 1 ? h->out : h->err;
    size_t *cnt = stream == 1 ? &h->outn : &h->errn;
    size_t cap = stream == 1 ? sizeof h->out : sizeof h->err;
    size_t k = n < cap - 1 - *cnt ? n : cap - 1 - *cnt;
    memcpy(buf + *cnt, d, k);
    *cnt += k;
    buf[*cnt] = 0;
    return n;
}
static const char *g_stdin = "line one\nline two\n";
static size_t g_stdin_pos;
static ptrdiff_t rd(void *ud, char *buf, size_t cap) {
    (void)ud;
    size_t left = strlen(g_stdin) - g_stdin_pos;
    size_t k = cap < left ? cap : left;
    memcpy(buf, g_stdin + g_stdin_pos, k);
    g_stdin_pos += k;
    return (ptrdiff_t)k;
}

/* ---- native module "host" ---- */
static SpStatus h_add(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_INT || argv[1].type != SP_T_INT) return sp_throw(vm, "TypeError", "add expects ints");
    *ret = sp_int(argv[0].as.i + argv[1].as.i);
    return SP_OK;
}
static SpStatus h_greet(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    size_t n;
    const char *s = sp_string_data(argv[0], &n);
    if (!s) return sp_throw(vm, "TypeError", "greet expects a string");
    char buf[128];
    int k = snprintf(buf, sizeof buf, "hello, %s!", s);
    return sp_new_string(vm, buf, (size_t)k, ret);
}
static SpStatus h_apply(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    SpValue a = argv[1];
    return sp_call(vm, argv[0], 1, &a, ret);
}
static SpStatus h_apply_nocb(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    SpValue a = argv[1];
    return sp_call(vm, argv[0], 1, &a, ret);
}
static SpStatus h_fail(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv; (void)ret;
    return sp_throw(vm, "ValueError", "host says no (%d)", 42);
}
static SpStatus h_custom(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv; (void)ret;
    return sp_throw(vm, "HostError", "custom kind");
}
static SpStatus h_panic(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv; (void)ret;
    return sp_panic(vm, "host panic");
}
static SpStatus h_secret(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    *ret = sp_int(1234);
    return SP_OK;
}
static SpStatus h_alloc_nolicense(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv;
    return sp_new_array(vm, 4, ret);
}
static SpStatus h_interrupt(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv; (void)ret;
    sp_interrupt(vm);
    return SP_OK;
}
static SpStatus h_table(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv;
    SpValue t, arr, k, v;
    SpStatus st = sp_new_table(vm, 4, &t);
    if (st) return st;
    if ((st = sp_new_array(vm, 0, &arr))) return st;
    for (int i = 0; i < 5; i++)
        if ((st = sp_array_push(vm, arr, sp_int(i * i)))) return st;
    if ((st = sp_new_string(vm, "squares", 7, &k))) return st;
    if ((st = sp_table_set(vm, t, k, arr))) return st;
    if ((st = sp_new_string(vm, "pi", 2, &k))) return st;
    if ((st = sp_table_set(vm, t, k, sp_float(3.5)))) return st;
    (void)v;
    *ret = t;
    return SP_OK;
}
static SpStatus h_sum(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_ARRAY) return sp_throw(vm, "TypeError", "array expected");
    int64_t s = 0;
    for (size_t i = 0; i < sp_array_len(argv[0]); i++) {
        SpValue e;
        SpStatus st = sp_array_get(vm, argv[0], (int64_t)i, &e);
        if (st) return st;
        if (e.type == SP_T_INT) s += e.as.i;
    }
    *ret = sp_int(s);
    return SP_OK;
}

/* native object: a counter */
typedef struct Counter { int64_t n; SpValue held; } Counter;
static int g_released;
static void counter_trace(void *self, SpTracer *t) { sp_trace_value(t, ((Counter *)self)->held); }
static void counter_release(void *self) { (void)self; g_released++; }
static const SpNativeClass counter_class = {SP_NATIVE_ABI, "Counter", sizeof(Counter), counter_trace, counter_release};
static SpStatus h_counter_new(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    void *self;
    SpStatus st = sp_new_native(vm, &counter_class, ret, &self);
    if (st) return st;
    Counter *c = self;
    c->n = argv[0].as.i;
    c->held = argv[1];
    return SP_OK;
}
static SpStatus h_counter_inc(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    Counter *c = sp_native_data(argv[0], &counter_class);
    if (!c) return sp_throw(vm, "TypeError", "Counter expected");
    *ret = sp_int(++c->n);
    return SP_OK;
}
static SpStatus h_counter_held(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    Counter *c = sp_native_data(argv[0], &counter_class);
    if (!c) return sp_throw(vm, "TypeError", "Counter expected");
    *ret = c->held;
    return SP_OK;
}

/* native iterator: counts from 0 to n-1 */
typedef struct CountState { int64_t i, n; } CountState;
static SpIterResult count_next(SpVM *vm, void *state, SpValue out[2]) {
    (void)vm;
    CountState *s = state;
    if (s->i >= s->n) return SP_ITER_END;
    out[0] = sp_int(s->i++);
    return SP_ITER_ITEM;
}
static const SpIterClass count_class = {SP_ITER_ABI, "count", 1, 0, sizeof(CountState), count_next, NULL};
static SpStatus h_count(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    CountState s = {0, argv[0].as.i};
    return sp_new_iterator(vm, &count_class, &s, ret);
}

static SpRef *g_kept;
static SpStatus h_keep(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)ret;
    if (g_kept) sp_unref(vm, g_kept);
    return sp_ref(vm, argv[0], &g_kept);
}

static SpStatus h2_seven(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    *ret = sp_int(7);
    return SP_OK;
}
static const SpNativeDesc host2_fns[] = {{"seven", 0, 0, 0, 0, h2_seven}};
static const SpNativeDesc host3_fns[] = {{"seven", 0, 0, 0, 0, h2_seven}};

static const SpNativeDesc host_fns[] = {
    {"keep", 1, 1, 0, 0, h_keep},
    {"add", 2, 2, 0, 0, h_add},
    {"greet", 1, 1, 0, SP_NATIVE_ALLOCATES, h_greet},
    {"apply", 2, 2, 0, SP_NATIVE_CALLS_BACK, h_apply},
    {"apply_nocb", 2, 2, 0, 0, h_apply_nocb},
    {"fail", 0, 0, 0, 0, h_fail},
    {"custom", 0, 0, 0, 0, h_custom},
    {"panic", 0, 0, 0, 0, h_panic},
    {"secret", 0, 0, SP_CAP_CLOCK, 0, h_secret},
    {"alloc_nolicense", 0, 0, 0, 0, h_alloc_nolicense},
    {"interrupt", 0, 0, 0, 0, h_interrupt},
    {"table", 0, 0, 0, SP_NATIVE_ALLOCATES, h_table},
    {"sum", 1, 1, 0, 0, h_sum},
    {"counter_new", 2, 2, 0, SP_NATIVE_ALLOCATES, h_counter_new},
    {"counter_inc", 1, 1, 0, 0, h_counter_inc},
    {"counter_held", 1, 1, 0, 0, h_counter_held},
    {"count", 1, 1, 0, SP_NATIVE_ALLOCATES, h_count},
};

static void *fake_alloc(void *ud, void *ptr, size_t o, size_t n) {
    (void)ud; (void)ptr; (void)o; (void)n;
    return NULL;
}

static SpVM *mkvm(Host *h, uint32_t caps, void (*tweak)(SpConfig *)) {
    SpConfig cfg;
    sp_config_init(&cfg);
    cfg.capabilities = caps;
    cfg.deterministic = 1;
    cfg.write = wr;
    cfg.read = rd;
    cfg.io_ud = h;
    cfg.loader = ld;
    cfg.loader_ud = h;
    if (tweak) tweak(&cfg);
    SpVM *vm = NULL;
    SpStatus st = sp_vm_new(&cfg, &vm);
    CHECK(st == SP_OK);
    if (st != SP_OK) return NULL;
    CHECK(sp_register_module(vm, "host", host_fns, sizeof host_fns / sizeof host_fns[0]) == SP_OK);
    /* several modules: registering more must not disturb the earlier ones (their descriptors stay put) */
    CHECK(sp_register_module(vm, "host2", host2_fns, 1) == SP_OK);
    CHECK(sp_register_module(vm, "host3", host3_fns, 1) == SP_OK);
    return vm;
}

/* compile + run one main module; returns the run status (or compile status) */
static SpStatus run_src(Host *h, uint32_t caps, void (*tweak)(SpConfig *), const char *main_src, SpVM **keep) {
    static Src srcs[3];
    srcs[0].name = "main"; srcs[0].text = main_src;
    srcs[1].name = "util"; srcs[1].text = "export func twice(x):\n    return x * 2\nexport let TAG = \"util\"\n";
    srcs[2].name = "pkg.deep"; srcs[2].text = "import util\nexport func four():\n    return util.twice(2)\n";
    memset(h, 0, sizeof *h);
    h->srcs = srcs; h->nsrcs = 3;
    g_stdin_pos = 0;
    SpVM *vm = mkvm(h, caps, tweak);
    if (!vm) return SP_E_CONFIG;
    SpProgram *p = NULL;
    SpStatus st = sp_compile(vm, "main", &p);
    if (st == SP_OK) st = sp_run(vm, p, 0, NULL);
    if (getenv("SP_TEST_VERBOSE")) {
        (void)fprintf(stderr, "[run_src] status=%d out=%s err=%s\n", (int)st, h->out, h->err);
        SpValue e = sp_last_error(vm), m;
        if (e.type == SP_T_ERROR && sp_get_member(vm, e, "message", &m) == SP_OK) {
            size_t n;
            (void)fprintf(stderr, "          error: %s\n", sp_string_data(m, &n));
        }
        for (size_t i = 0; i < sp_diagnostic_count(vm); i++)
            (void)fprintf(stderr, "          diag: %s:%u:%u %s %s\n", sp_diagnostic(vm, i)->file, sp_diagnostic(vm, i)->line, sp_diagnostic(vm, i)->column, sp_diagnostic(vm, i)->kind, sp_diagnostic(vm, i)->message);
    }
    if (keep) *keep = vm; else sp_vm_free(vm);
    return st;
}

static void tweak_heap(SpConfig *c) { c->limits.max_heap_bytes = 4u << 20; }
static void tweak_instr(SpConfig *c) { c->limits.max_instructions = 100000; }
static void tweak_roots(SpConfig *c) { c->limits.max_native_roots = 8; }
static void tweak_reentry(SpConfig *c) { c->limits.max_native_reentry = 2; }

static int contains(const char *hay, const char *needle) { return strstr(hay, needle) != NULL; }

int main(void) {
    Host h;
    SpStatus st;

    /* 1. basic run, stdout capture, modules from the loader */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import util\nimport pkg.deep\nprint(util.twice(21), util.TAG, deep.four())\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "42 util 4\n") == 0);

    /* 2. capabilities: print without stdio_write is a PermissionError */
    st = run_src(&h, 0, NULL, "print(1)\n", NULL);
    CHECK(st == SP_E_PERMISSION);

    /* 3. stdin through the read callback */
    st = run_src(&h, SP_CAP_STDIO_WRITE | SP_CAP_STDIO_READ, NULL,
                 "import io\nprint(io.read_line())\nprint(io.read_line())\nprint(io.read_line())\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "line one\nline two\nnil\n") == 0);

    /* 4. native functions: arguments, strings, tables, arrays */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\nprint(host.add(40, 2))\nprint(host.greet(\"sprint\"))\n"
                 "let t = host.table()\nprint(t[\"squares\"], t[\"pi\"])\nprint(host.sum([1, 2, 3, 4]))\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "42\nhello, sprint!\n[0, 1, 4, 9, 16] 3.5\n10\n") == 0);

    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL, "import host\nimport host2\nimport host3\nprint(host.add(1, 2), host2.seven(), host3.seven())\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "3 7 7\n") == 0);

    /* 5. arity is checked before the native is called */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\ntry:\n    host.add(1)\ncatch e:\n    print(e.kind)\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "TypeError\n") == 0);

    /* 6. errors thrown by natives are ordinary catchable errors */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\ntry:\n    host.fail()\ncatch e:\n    print(e.kind, e.message)\n"
                 "try:\n    host.custom()\ncatch e:\n    print(e.kind, e.message)\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "ValueError host says no (42)\nHostError custom kind\n") == 0);

    /* 7. uncaught native error: SP_E_RUNTIME and sp_last_error */
    {
        SpVM *vm;
        st = run_src(&h, SP_CAP_STDIO_WRITE, NULL, "import host\nhost.fail()\n", &vm);
        CHECK(st == SP_E_RUNTIME);
        SpValue e = sp_last_error(vm), k, m;
        CHECK(e.type == SP_T_ERROR);
        CHECK(sp_get_member(vm, e, "kind", &k) == SP_OK);
        CHECK(sp_get_member(vm, e, "message", &m) == SP_OK);
        size_t n;
        CHECK(strcmp(sp_string_data(k, &n), "ValueError") == 0);
        CHECK(strcmp(sp_string_data(m, &n), "host says no (42)") == 0);
        sp_vm_free(vm);
    }

    /* 8. sp_panic cannot be caught */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\ntry:\n    host.panic()\ncatch e:\n    print(\"caught\")\n", NULL);
    CHECK(st == SP_E_PANIC);
    CHECK(!contains(h.out, "caught"));

    /* 9. native capability requirement */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL, "import host\nprint(host.secret())\n", NULL);
    CHECK(st == SP_E_PERMISSION);
    st = run_src(&h, SP_CAP_STDIO_WRITE | SP_CAP_CLOCK, NULL, "import host\nprint(host.secret())\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "1234\n") == 0);

    /* 10. sp_call back into Sprint; the flag is enforced */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\nprint(host.apply(func(x): x + 1, 41))\n"
                 "try:\n    host.apply_nocb(func(x): x, 1)\ncatch e:\n    print(e.kind)\n"
                 "func bad(x):\n    throw error(\"MyErr\", \"boom\")\ntry:\n    host.apply(bad, 1)\ncatch e:\n    print(e.message)\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "42\nRuntimeError\nboom\n") == 0);

    /* 11. allocation without SP_NATIVE_ALLOCATES is refused */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\ntry:\n    host.alloc_nolicense()\ncatch e:\n    print(e.kind)\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "RuntimeError\n") == 0);

    /* 12. native objects: identity, tracing across GC, release on VM destruction */
    g_released = 0;
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\nimport gc\nlet c = host.counter_new(10, [1, 2, 3])\n"
                 "let i = 0\nwhile i < 3:\n    host.counter_inc(c)\n    i += 1\n"
                 "let junk = []\nfor k in range(20000):\n    junk.append([k])\njunk = nil\ngc.collect()\n"
                 "print(host.counter_inc(c), host.counter_held(c))\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "14 [1, 2, 3]\n") == 0);
    CHECK(g_released == 1);
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\ntry:\n    host.counter_inc(5)\ncatch e:\n    print(e.kind)\n", NULL);
    CHECK(st == SP_OK && strcmp(h.out, "TypeError\n") == 0);

    /* 13. native iterators drive for-loops */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                 "import host\nlet s = 0\nfor x in host.count(5):\n    s += x\nprint(s)\n"
                 "for x in host.count(0):\n    print(\"never\")\n", NULL);
    CHECK(st == SP_OK);
    CHECK(strcmp(h.out, "10\n") == 0);

    /* 14. compile errors give diagnostics */
    {
        SpVM *vm;
        st = run_src(&h, SP_CAP_STDIO_WRITE, NULL, "let x = \nprint(x)\n", &vm);
        CHECK(st == SP_E_COMPILE);
        CHECK(sp_diagnostic_count(vm) == 1);
        const SpDiagnostic *d = sp_diagnostic(vm, 0);
        CHECK(d && d->line >= 1 && strcmp(d->file, "main") == 0 && d->kind);
        sp_vm_free(vm);
        st = run_src(&h, SP_CAP_STDIO_WRITE, NULL, "import nosuchmodule\n", &vm);
        CHECK(st == SP_E_IMPORT);
        sp_vm_free(vm);
    }

    /* 15. limits: heap, instructions, native roots, re-entry */
    st = run_src(&h, SP_CAP_STDIO_WRITE, tweak_heap, "let a = []\nwhile true:\n    a.append([1, 2, 3, 4])\n", NULL);
    CHECK(st == SP_E_MEMORY);
    st = run_src(&h, SP_CAP_STDIO_WRITE, tweak_instr, "while true:\n    pass\n", NULL);
    CHECK(st == SP_E_TIMEOUT);
    st = run_src(&h, SP_CAP_STDIO_WRITE, tweak_roots,
                 "import host\nfor i in range(20):\n    host.table()\nprint(\"done\")\n", NULL);
    CHECK(st == SP_OK); /* roots are released after each native call */
    st = run_src(&h, SP_CAP_STDIO_WRITE, tweak_reentry,
                 "import host\nfunc deep(n):\n    if n == 0:\n        return 0\n    return host.apply(deep, n - 1)\ndeep(10)\n", NULL);
    CHECK(st == SP_E_MEMORY);

    /* 16. sp_interrupt stops a running program */
    st = run_src(&h, SP_CAP_STDIO_WRITE, NULL, "import host\nhost.interrupt()\nwhile true:\n    pass\n", NULL);
    CHECK(st == SP_E_INTERRUPT);

    /* 17. sys.exit */
    {
        SpVM *vm;
        st = run_src(&h, SP_CAP_STDIO_WRITE, NULL, "import sys\nsys.exit(7)\n", &vm);
        CHECK(st == SP_EXIT);
        CHECK(sp_exit_code(vm) == 7);
        sp_vm_free(vm);
    }

    /* 18. refs keep values alive; top-level sp_call after the run */
    {
        SpVM *vm;
        g_kept = NULL;
        st = run_src(&h, SP_CAP_STDIO_WRITE, NULL,
                     "import host\nimport gc\nlet base = [10, 20]\n"
                     "func add(x):\n    return x + base[1]\nfunc boom(x):\n    throw error(\"MyErr\", \"top-level boom\")\n"
                     "host.keep([add, boom, \"kept\"])\n"
                     "let junk = []\nfor k in range(20000):\n    junk.append([k])\njunk = nil\ngc.collect()\n", &vm);
        CHECK(st == SP_OK);
        CHECK(g_kept != NULL);
        if (g_kept) {
            SpValue arr = sp_ref_get(g_kept), f, r;
            CHECK(sp_array_len(arr) == 3);
            CHECK(sp_array_get(vm, arr, 0, &f) == SP_OK);
            SpValue arg = sp_int(5);
            CHECK(sp_call(vm, f, 1, &arg, &r) == SP_OK);
            CHECK(r.type == SP_T_INT && r.as.i == 25);
            CHECK(sp_array_get(vm, arr, 1, &f) == SP_OK);
            CHECK(sp_call(vm, f, 1, &arg, &r) == SP_E_RUNTIME);
            SpValue e = sp_last_error(vm), m;
            size_t n;
            CHECK(e.type == SP_T_ERROR && sp_get_member(vm, e, "message", &m) == SP_OK);
            CHECK(strcmp(sp_string_data(m, &n), "top-level boom") == 0);
            CHECK(sp_call(vm, f, 1, &arg, &r) == SP_E_RUNTIME); /* still usable after a failure */
            CHECK(sp_array_get(vm, arr, 0, &f) == SP_OK);
            CHECK(sp_call(vm, f, 1, &arg, &r) == SP_OK && r.as.i == 25);
            sp_unref(vm, g_kept);
            g_kept = NULL;
        }
        sp_vm_free(vm);
    }

    /* 18b. wall-clock limit */
    {
        Src one[] = {{"main", "while true:\n    pass\n"}};
        memset(&h, 0, sizeof h);
        h.srcs = one; h.nsrcs = 1;
        SpConfig cfg;
        sp_config_init(&cfg);
        cfg.limits.max_runtime_ms = 50;
        cfg.loader = ld; cfg.loader_ud = &h;
        SpVM *vm = NULL;
        SpProgram *p = NULL;
        CHECK(sp_vm_new(&cfg, &vm) == SP_OK);
        CHECK(sp_compile(vm, "main", &p) == SP_OK);
        CHECK(sp_run(vm, p, 0, NULL) == SP_E_TIMEOUT);
        sp_vm_free(vm);
    }

    /* 19. images round trip through the API */
    {
        Src one[] = {{"main", "print(6 * 7)\n"}};
        memset(&h, 0, sizeof h);
        h.srcs = one; h.nsrcs = 1;
        SpVM *vm = mkvm(&h, SP_CAP_STDIO_WRITE, NULL);
        SpProgram *p = NULL, *p2 = NULL;
        uint8_t *img = NULL;
        size_t n = 0;
        CHECK(sp_compile(vm, "main", &p) == SP_OK);
        CHECK(sp_save_image(vm, p, 1, &img, &n) == SP_OK && n > 16);
        sp_program_free(vm, p);
        sp_vm_free(vm);

        memset(&h, 0, sizeof h);
        vm = mkvm(&h, SP_CAP_STDIO_WRITE, NULL);
        CHECK(sp_load_image(vm, img, n, &p2) == SP_OK);
        CHECK(sp_run(vm, p2, 0, NULL) == SP_OK);
        CHECK(strcmp(h.out, "42\n") == 0);
        CHECK(sp_run(vm, p2, 0, NULL) == SP_E_CONFIG); /* one program per VM */
        sp_program_free(vm, p2);
        sp_vm_free(vm);
        /* a corrupted image is rejected */
        img[n / 2] ^= 0x5A;
        vm = mkvm(&h, SP_CAP_STDIO_WRITE, NULL);
        SpProgram *bad = NULL;
        CHECK(sp_load_image(vm, img, n, &bad) == SP_E_LOAD);
        sp_vm_free(vm);
        sp_free_buffer(NULL, img);
    }

    /* 20. configuration errors */
    {
        SpConfig cfg;
        SpVM *vm = NULL;
        sp_config_init(&cfg);
        cfg.api_major = 1;
        CHECK(sp_vm_new(&cfg, &vm) == SP_E_CONFIG);
        sp_config_init(&cfg);
        cfg.limits.max_call_depth = 0;
        CHECK(sp_vm_new(&cfg, &vm) == SP_E_CONFIG);
        sp_config_init(&cfg);
        cfg.alloc = fake_alloc;
        CHECK(sp_vm_new(&cfg, &vm) == SP_E_CONFIG);
        sp_config_init(&cfg);
        CHECK(sp_vm_new(&cfg, &vm) == SP_OK);
        SpNativeDesc dup[] = {{"a", 0, 0, 0, 0, h_fail}, {"a", 0, 0, 0, 0, h_fail}};
        CHECK(sp_register_module(vm, "bad", dup, 2) == SP_E_CONFIG);
        CHECK(sp_register_module(vm, "math", dup, 1) == SP_E_CONFIG); /* shadows a builtin */
        CHECK(sp_register_module(vm, "Bad Name", dup, 1) == SP_E_CONFIG);
        SpProgram *p = NULL;
        CHECK(sp_compile(vm, "main", &p) == SP_E_CONFIG); /* no loader */
        SpValue s;
        CHECK(sp_new_string(vm, "\xff\xfe", 2, &s) == SP_E_RUNTIME);
        CHECK(sp_new_string(vm, "ok", 2, &s) == SP_OK);
        CHECK(strcmp(sp_type_name(s), "string") == 0);
        sp_vm_free(vm);
    }

    (void)fprintf(stderr, "embed tests: %d checks, %d failed\n", g_total, g_fail);
    return g_fail ? 1 : 0;
}
