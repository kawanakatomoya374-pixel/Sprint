/* Sprint OS user process (ring 3): the Sprint interpreter as a static-PIE program. argv[1] names the Sprint
 * module to run (default "init"); module sources are compiled in (os/user and the stdlib). */
#define SP_EMBED_INTERNAL 1
#include "sp.h"
#include "sprint.h"
#include "udev.h"
#include <stdio.h>
#include <string.h>

static SpStatus load_source(void *ud, const char *name, const char **src, size_t *len, const char **path) {
    (void)ud;
    const BundledMod *b = bundled_find(name, strlen(name));
    if (!b) return SP_E_IMPORT;
    *src = b->src;
    *len = b->len;
    *path = b->name;
    return SP_OK;
}

static long sc3(long n, long a, long b, long c) {
    long r;
    __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return r;
}

/* console output goes straight to the kernel (no stdio buffering), so what processes print interleaves in order */
static size_t write_out(void *ud, int stream, const char *data, size_t len) {
    (void)ud;
    size_t done = 0;
    while (done < len) {
        long r = sc3(1, stream == 2 ? 2 : 1, (long)(uintptr_t)(data + done), (long)(len - done));
        if (r <= 0) break;
        done += (size_t)r;
    }
    return done;
}

/* module `sys`: the system calls a Sprint program can make */
static SpStatus need_i(SpVM *vm, SpValue v, int64_t *out) {
    if (v.type != SP_T_INT) return sp_throw(vm, "TypeError", "sys: expected an int, got %s", sp_type_name(v));
    *out = v.as.i;
    return SP_OK;
}
static SpStatus s_spawn(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_STRING) return sp_throw(vm, "TypeError", "sys.spawn: expected a module name");
    size_t n;
    const char *s = sp_string_data(argv[0], &n);
    *ret = sp_int(sc3(1000, (long)(uintptr_t)s, (long)n, 0));
    return SP_OK;
}
static SpStatus s_wait(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid;
    SpStatus st = need_i(vm, argv[0], &pid);
    if (st != SP_OK) return st;
    *ret = sp_int(sc3(1001, (long)pid, 0, 0));
    return SP_OK;
}
static SpStatus s_sleep_ms(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t ms;
    SpStatus st = need_i(vm, argv[0], &ms);
    if (st != SP_OK) return st;
    long ts[2] = {(long)(ms / 1000), (long)(ms % 1000) * 1000000L};
    (void)sc3(35, (long)(uintptr_t)ts, 0, 0);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus s_yield(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    (void)sc3(24, 0, 0, 0);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus s_pid(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    *ret = sp_int(sc3(39, 0, 0, 0));
    return SP_OK;
}
static SpStatus s_ms(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    long ts[2] = {0, 0};
    (void)sc3(228, 1, (long)(uintptr_t)ts, 0);
    *ret = sp_int((int64_t)ts[0] * 1000 + (int64_t)ts[1] / 1000000);
    return SP_OK;
}
static SpStatus s_exit(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t c;
    SpStatus st = need_i(vm, argv[0], &c);
    if (st != SP_OK) return st;
    (void)sc3(231, (long)c, 0, 0);
    *ret = sp_nil();
    return SP_OK;
}
static const SpNativeDesc sys_fns[] = {
    {"exit", 1, 1, 0, 0, s_exit},
    {"spawn", 1, 1, 0, 0, s_spawn}, {"wait", 1, 1, 0, 0, s_wait}, {"sleep_ms", 1, 1, 0, 0, s_sleep_ms},
    {"yield", 0, 0, 0, 0, s_yield}, {"pid", 0, 0, 0, 0, s_pid}, {"ms", 0, 0, 0, 0, s_ms},
};

int main(int argc, char **argv) {
    SpConfig cfg;
    sp_config_init(&cfg);
    cfg.capabilities = SP_CAP_STDIO_WRITE | SP_CAP_CLOCK;
    cfg.limits.max_heap_bytes = 64u << 20;
    cfg.write = write_out;
    cfg.loader = load_source;
    SpVM *vm;
    if (sp_vm_new(&cfg, &vm) != SP_OK) return 100;
    (void)udev_register(vm);
    (void)sp_register_module(vm, "sysraw", sys_fns, sizeof sys_fns / sizeof sys_fns[0]);
    SpProgram *prog;
    const char *entry = argc > 1 ? argv[1] : "init";
    SpStatus st = sp_compile(vm, entry, &prog);
    if (st != SP_OK) {
        for (size_t i = 0; i < sp_diagnostic_count(vm); i++) {
            const SpDiagnostic *d = sp_diagnostic(vm, i);
            (void)fprintf(stderr, "%s:%u: %s: %s\n", d->file, d->line, d->kind, d->message);
        }
        return 101;
    }
    st = sp_run(vm, prog, argc > 1 ? argc - 1 : 0, argc > 1 ? (const char *const *)argv + 1 : NULL);
    (void)fflush(stdout);
    return st == SP_OK ? 0 : 1;
}
