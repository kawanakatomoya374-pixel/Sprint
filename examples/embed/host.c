/* Embedding Sprint in a C program (SPEC 20).
 *
 * The host registers a native module "host", compiles a script from memory
 * (the loader callback supplies every module), runs it with only the
 * capabilities it chooses to grant, and then calls a Sprint function from C.
 *
 *   make lib && cc -std=c11 -Isrc -o host examples/embed/host.c build/libsprint.a -lm
 */
#include "sprint.h"
#include <stdio.h>
#include <string.h>

static const char *SCRIPT =
    "import host\n"
    "\n"
    "export func area(w, h):\n"
    "    return w * h\n"
    "\n"
    "let words = []\n"
    "for n in host.numbers(4):\n"
    "    words.append(host.describe(n))\n"
    "print(words)\n"
    "print(host.scale(2.5, 4))\n"
    "host.on_done(func(msg): f\"script says: {msg}\")\n"
    "try:\n"
    "    host.describe(\"not a number\")\n"
    "catch e:\n"
    "    print(\"caught\", e.kind, e.message)\n";

static SpStatus load_source(void *ud, const char *name, const char **src, size_t *len, const char **path) {
    (void)ud;
    if (strcmp(name, "main") != 0) return SP_E_IMPORT;
    *src = SCRIPT;
    *len = strlen(SCRIPT);
    *path = "demo.sp";
    return SP_OK;
}

static size_t write_out(void *ud, int stream, const char *data, size_t len) {
    (void)ud;
    return fwrite(data, 1, len, stream == 2 ? stderr : stdout);
}

/* ---- native functions ---- */
static SpStatus h_describe(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_INT) return sp_throw(vm, "TypeError", "describe() expects an int, got %s", sp_type_name(argv[0]));
    char buf[64];
    int n = snprintf(buf, sizeof buf, "#%lld is %s", (long long)argv[0].as.i, argv[0].as.i % 2 ? "odd" : "even");
    return sp_new_string(vm, buf, (size_t)n, ret);
}

static SpStatus h_scale(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    double a = argv[0].type == SP_T_FLOAT ? argv[0].as.f : (double)argv[0].as.i;
    double b = argv[1].type == SP_T_FLOAT ? argv[1].as.f : (double)argv[1].as.i;
    *ret = sp_float(a * b);
    return SP_OK;
}

typedef struct Count { int64_t i, n; } Count;
static SpIterResult count_next(SpVM *vm, void *state, SpValue out[2]) {
    (void)vm;
    Count *c = state;
    if (c->i >= c->n) return SP_ITER_END;
    out[0] = sp_int(c->i++);
    return SP_ITER_ITEM;
}
static const SpIterClass count_class = {SP_ITER_ABI, "numbers", 1, 0, sizeof(Count), count_next, NULL};
static SpStatus h_numbers(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    Count c = {1, argv[0].as.i + 1};
    return sp_new_iterator(vm, &count_class, &c, ret);
}

static SpRef *g_callback; /* a value the host keeps across native calls */
static SpStatus h_on_done(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)ret;
    if (g_callback) sp_unref(vm, g_callback);
    return sp_ref(vm, argv[0], &g_callback);
}

static const SpNativeDesc host_fns[] = {
    {"describe", 1, 1, 0, SP_NATIVE_ALLOCATES, h_describe},
    {"scale", 2, 2, 0, 0, h_scale},
    {"numbers", 1, 1, 0, SP_NATIVE_ALLOCATES, h_numbers},
    {"on_done", 1, 1, 0, 0, h_on_done},
};

int main(void) {
    SpConfig cfg;
    sp_config_init(&cfg);
    cfg.capabilities = SP_CAP_STDIO_WRITE; /* the script may print, nothing else */
    cfg.deterministic = 1;
    cfg.limits.max_heap_bytes = 16u << 20;
    cfg.limits.max_instructions = 10u * 1000 * 1000;
    cfg.write = write_out;
    cfg.loader = load_source;

    SpVM *vm;
    if (sp_vm_new(&cfg, &vm) != SP_OK) return 1;
    if (sp_register_module(vm, "host", host_fns, sizeof host_fns / sizeof host_fns[0]) != SP_OK) return 1;

    SpProgram *prog;
    SpStatus st = sp_compile(vm, "main", &prog);
    if (st != SP_OK) {
        const SpDiagnostic *d = sp_diagnostic(vm, 0);
        (void)fprintf(stderr, "%s:%u: %s: %s\n", d->file, d->line, d->kind, d->message);
        sp_vm_free(vm);
        return 2;
    }
    st = sp_run(vm, prog, 0, NULL);
    if (st != SP_OK) {
        (void)fprintf(stderr, "run failed (%d)\n", (int)st);
        sp_vm_free(vm);
        return 3;
    }

    /* call back into the script from C */
    if (g_callback) {
        SpValue msg, reply;
        if (sp_new_string(vm, "all done", 8, &msg) == SP_OK) {
            SpRef *keep;
            (void)sp_ref(vm, msg, &keep); /* nothing else holds the argument */
            if (sp_call(vm, sp_ref_get(g_callback), 1, &msg, &reply) == SP_OK) {
                size_t n;
                const char *s = sp_string_data(reply, &n);
                (void)printf("host got: %s\n", s);
            }
            sp_unref(vm, keep);
        }
        sp_unref(vm, g_callback);
    }
    sp_vm_free(vm);
    return 0;
}
