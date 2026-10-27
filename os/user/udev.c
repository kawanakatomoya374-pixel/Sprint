/* Module `gdev`: the screen, pointer and input devices as seen from a user process. The kernel maps the
 * framebuffer into the process (system call 1002) and hands out keyboard/mouse events as text lines (1003). */
#define SP_EMBED_INTERNAL 1
#include "sp.h"
#include "sprint.h"
#include "udev.h"
#include <stdint.h>
#include <string.h>

static long sc3(long n, long a, long b, long c) {
    long r;
    __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return r;
}

static struct { uint8_t *addr; uint32_t w, h, pitch; } g_fb;

static SpStatus need_i(SpVM *vm, SpValue v, int64_t *out) {
    if (v.type != SP_T_INT) return sp_throw(vm, "TypeError", "gdev: expected an int, got %s", sp_type_name(v));
    *out = v.as.i;
    return SP_OK;
}

/* ---- the pointer: drawn straight onto the framebuffer, background saved under it ---- */
enum { CUR_MAX = 64, CUR_KEY = 0xFF00FF };
static struct {
    int w, h, hx, hy, x, y, shown, saved_ok;
    uint32_t img[CUR_MAX * CUR_MAX], under[CUR_MAX * CUR_MAX];
} g_cur;

static uint32_t *fb_px(int x, int y) { return (uint32_t *)(void *)(g_fb.addr + (size_t)y * g_fb.pitch) + x; }

static void cur_restore(void) {
    if (!g_cur.saved_ok) return;
    for (int j = 0; j < g_cur.h; j++) {
        int y = g_cur.y - g_cur.hy + j;
        if (y < 0 || y >= (int)g_fb.h) continue;
        for (int i = 0; i < g_cur.w; i++) {
            int x = g_cur.x - g_cur.hx + i;
            if (x >= 0 && x < (int)g_fb.w) *fb_px(x, y) = g_cur.under[j * CUR_MAX + i];
        }
    }
    g_cur.saved_ok = 0;
}
static void cur_draw(void) {
    if (!g_cur.shown || g_cur.w == 0 || !g_fb.addr) return;
    for (int j = 0; j < g_cur.h; j++) {
        int y = g_cur.y - g_cur.hy + j;
        if (y < 0 || y >= (int)g_fb.h) continue;
        for (int i = 0; i < g_cur.w; i++) {
            int x = g_cur.x - g_cur.hx + i;
            if (x < 0 || x >= (int)g_fb.w) continue;
            uint32_t *p = fb_px(x, y);
            g_cur.under[j * CUR_MAX + i] = *p;
            uint32_t c = g_cur.img[j * CUR_MAX + i];
            if (c != CUR_KEY) *p = c;
        }
    }
    g_cur.saved_ok = 1;
}

/* fb_map() -> [width, height], or nil when this process may not (or there is no framebuffer) */
static SpStatus d_fb_map(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    uint64_t out[4] = {0, 0, 0, 0};
    long r = sc3(1002, (long)(uintptr_t)out, 0, 0);
    if (r != 0) {
        *ret = sp_nil();
        return SP_OK;
    }
    g_fb.addr = (uint8_t *)(uintptr_t)out[0];
    g_fb.w = (uint32_t)out[1];
    g_fb.h = (uint32_t)out[2];
    g_fb.pitch = (uint32_t)out[3];
    SpStatus s = sp_new_array(vm, 2, ret);
    if (s != SP_OK) return s;
    (void)sp_array_push(vm, *ret, sp_int((int64_t)g_fb.w));
    (void)sp_array_push(vm, *ret, sp_int((int64_t)g_fb.h));
    return SP_OK;
}

/* present(canvas, x = 0, y = 0, rx = 0, ry = 0, rw = canvas width, rh = canvas height) */
static SpStatus d_present(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    int w, h;
    const uint32_t *px = gfx_canvas_pixels(argv[0], &w, &h);
    if (!px) return sp_throw(vm, "TypeError", "gdev.present: expected a canvas, got %s", sp_type_name(argv[0]));
    if (!g_fb.addr) return sp_throw(vm, "OSError", "gdev.present: the framebuffer is not mapped (call fb_map)");
    int64_t v[6] = {0, 0, 0, 0, w, h};
    for (int i = 1; i < argc && i < 7; i++)
        if (need_i(vm, argv[i], &v[i - 1]) != SP_OK) return SP_E_RUNTIME;
    int64_t ox = v[0], oy = v[1], rx = v[2], ry = v[3], rw = v[4], rh = v[5];
    if (rx < 0) { rw += rx; rx = 0; }
    if (ry < 0) { rh += ry; ry = 0; }
    if (rx + rw > w) rw = w - rx;
    if (ry + rh > h) rh = h - ry;
    int64_t n = 0;
    g_cur.saved_ok = 0;
    for (int64_t y = ry; y < ry + rh; y++) {
        int64_t sy = oy + y;
        if (sy < 0 || sy >= (int64_t)g_fb.h) continue;
        int64_t x0 = rx, x1 = rx + rw;
        if (ox + x0 < 0) x0 = -ox;
        if (ox + x1 > (int64_t)g_fb.w) x1 = (int64_t)g_fb.w - ox;
        if (x1 <= x0) continue;
        memcpy(fb_px((int)(ox + x0), (int)sy), px + y * w + x0, (size_t)(x1 - x0) * 4);
        n += x1 - x0;
    }
    cur_draw();
    *ret = sp_int(n);
    return SP_OK;
}
static SpStatus d_cursor_image(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int w, h;
    const uint32_t *px = gfx_canvas_pixels(argv[0], &w, &h);
    if (!px) return sp_throw(vm, "TypeError", "gdev.cursor_image: expected a canvas");
    int64_t hx, hy;
    if (need_i(vm, argv[1], &hx) != SP_OK || need_i(vm, argv[2], &hy) != SP_OK) return SP_E_RUNTIME;
    if (w > CUR_MAX || h > CUR_MAX) return sp_throw(vm, "ValueError", "gdev.cursor_image: at most %dx%d", CUR_MAX, CUR_MAX);
    cur_restore();
    g_cur.w = w;
    g_cur.h = h;
    g_cur.hx = (int)hx;
    g_cur.hy = (int)hy;
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) g_cur.img[j * CUR_MAX + i] = px[j * w + i];
    g_cur.shown = 1;
    cur_draw();
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus d_cursor_move(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t x, y;
    if (need_i(vm, argv[0], &x) != SP_OK || need_i(vm, argv[1], &y) != SP_OK) return SP_E_RUNTIME;
    cur_restore();
    g_cur.x = (int)x;
    g_cur.y = (int)y;
    cur_draw();
    *ret = sp_nil();
    return SP_OK;
}

/* input() -> the events since the last call, one tab-separated line each ("" when none) */
static SpStatus d_input(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    static char buf[8192];
    long n = sc3(1003, (long)(uintptr_t)buf, (long)sizeof buf, 0);
    if (n < 0) n = 0;
    return sp_new_string(vm, buf, (size_t)n, ret);
}
static SpStatus d_mem_info(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    uint64_t m[2] = {0, 0};
    (void)sc3(1006, (long)(uintptr_t)m, 0, 0);
    SpStatus s = sp_new_array(vm, 2, ret);
    if (s != SP_OK) return s;
    (void)sp_array_push(vm, *ret, sp_int((int64_t)m[0]));
    (void)sp_array_push(vm, *ret, sp_int((int64_t)m[1]));
    return SP_OK;
}
static SpStatus d_rtc(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    uint64_t t[6] = {0};
    (void)sc3(1008, (long)(uintptr_t)t, 0, 0);
    SpStatus s = sp_new_array(vm, 6, ret);
    if (s != SP_OK) return s;
    for (int i = 0; i < 6; i++) (void)sp_array_push(vm, *ret, sp_int((int64_t)t[i]));
    return SP_OK;
}
static SpStatus d_poweroff(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    (void)sc3(1005, 0, 0, 0);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus d_reboot(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    (void)sc3(1009, 0, 0, 0);
    *ret = sp_nil();
    return SP_OK;
}

static const SpNativeDesc gdev_fns[] = {
    {"fb_map", 0, 0, 0, SP_NATIVE_ALLOCATES, d_fb_map}, {"present", 1, 7, 0, 0, d_present},
    {"cursor_image", 3, 3, 0, 0, d_cursor_image}, {"cursor_move", 2, 2, 0, 0, d_cursor_move},
    {"input", 0, 0, 0, SP_NATIVE_ALLOCATES, d_input}, {"mem_info", 0, 0, 0, SP_NATIVE_ALLOCATES, d_mem_info},
    {"rtc", 0, 0, 0, SP_NATIVE_ALLOCATES, d_rtc}, {"poweroff", 0, 0, 0, 0, d_poweroff}, {"reboot", 0, 0, 0, 0, d_reboot},
};

/* ---- module `ipc`: shared memory segments (1010..1012) and messages between processes (1013, 1014) ---- */
enum { MAX_SHM = 32 };
static struct { uint64_t va; uint64_t bytes; } g_shm[MAX_SHM];

static void shm_note(uint64_t va, uint64_t bytes) {
    for (int i = 0; i < MAX_SHM; i++)
        if (g_shm[i].va == 0) { g_shm[i].va = va; g_shm[i].bytes = bytes; return; }
}
static uint8_t *shm_span(SpVM *vm, SpValue va, SpValue off, int64_t n, const char *who) {
    int64_t a, o;
    if (need_i(vm, va, &a) != SP_OK || need_i(vm, off, &o) != SP_OK) return NULL;
    for (int i = 0; i < MAX_SHM; i++)
        if (g_shm[i].va == (uint64_t)a) {
            if (o < 0 || n < 0 || (uint64_t)o + (uint64_t)n > g_shm[i].bytes) {
                (void)sp_throw(vm, "IndexError", "ipc.%s: range outside the segment (%llu bytes)", who, (unsigned long long)g_shm[i].bytes);
                return NULL;
            }
            return (uint8_t *)(uintptr_t)a + o;
        }
    (void)sp_throw(vm, "ValueError", "ipc.%s: not a mapped shared segment", who);
    return NULL;
}
static SpStatus i_shm_create(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t size;
    if (need_i(vm, argv[0], &size) != SP_OK) return SP_E_RUNTIME;
    uint64_t out[3] = {0, 0, 0};
    long r = sc3(1010, (long)size, (long)(uintptr_t)out, 0);
    if (r < 0) return sp_throw(vm, "OSError", "ipc.shm_create: error %ld", r);
    SpStatus st = sp_new_array(vm, 3, ret);
    if (st != SP_OK) return st;
    shm_note(out[1], out[2]);
    for (int i = 0; i < 3; i++) (void)sp_array_push(vm, *ret, sp_int((int64_t)out[i]));
    return SP_OK;
}
static SpStatus i_shm_open(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t id;
    if (need_i(vm, argv[0], &id) != SP_OK) return SP_E_RUNTIME;
    uint64_t bytes = 0;
    long va = sc3(1011, (long)id, (long)(uintptr_t)&bytes, 0);
    if (va < 0) return sp_throw(vm, "OSError", "ipc.shm_open: no such segment");
    shm_note((uint64_t)va, bytes);
    SpStatus st = sp_new_array(vm, 2, ret);
    if (st != SP_OK) return st;
    (void)sp_array_push(vm, *ret, sp_int(va));
    (void)sp_array_push(vm, *ret, sp_int((int64_t)bytes));
    return SP_OK;
}
static SpStatus i_shm_close(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t va;
    if (need_i(vm, argv[0], &va) != SP_OK) return SP_E_RUNTIME;
    for (int i = 0; i < MAX_SHM; i++)
        if (g_shm[i].va == (uint64_t)va) g_shm[i].va = 0;
    *ret = sp_int(sc3(1012, (long)va, 0, 0));
    return SP_OK;
}
static SpStatus i_shm_read(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t n;
    if (need_i(vm, argv[2], &n) != SP_OK) return SP_E_RUNTIME;
    const uint8_t *p = shm_span(vm, argv[0], argv[1], n, "shm_read");
    if (!p) return SP_E_RUNTIME;
    return sp_new_string(vm, (const char *)p, (size_t)n, ret);
}
static SpStatus i_shm_write(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[2].type != SP_T_STRING) return sp_throw(vm, "TypeError", "ipc.shm_write: expected a string");
    size_t n;
    const char *s = sp_string_data(argv[2], &n);
    uint8_t *p = shm_span(vm, argv[0], argv[1], (int64_t)n, "shm_write");
    if (!p) return SP_E_RUNTIME;
    memcpy(p, s, n);
    *ret = sp_int((int64_t)n);
    return SP_OK;
}
static SpStatus i_shm_get(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    const uint8_t *p = shm_span(vm, argv[0], argv[1], 8, "shm_get");
    if (!p) return SP_E_RUNTIME;
    int64_t v;
    memcpy(&v, p, 8);
    *ret = sp_int(v);
    return SP_OK;
}
static SpStatus i_shm_set(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t v;
    if (need_i(vm, argv[2], &v) != SP_OK) return SP_E_RUNTIME;
    uint8_t *p = shm_span(vm, argv[0], argv[1], 8, "shm_set");
    if (!p) return SP_E_RUNTIME;
    memcpy(p, &v, 8);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus i_send(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid;
    if (need_i(vm, argv[0], &pid) != SP_OK) return SP_E_RUNTIME;
    if (argv[1].type != SP_T_STRING) return sp_throw(vm, "TypeError", "ipc.send: expected a string");
    size_t n;
    const char *s = sp_string_data(argv[1], &n);
    *ret = sp_int(sc3(1013, (long)pid, (long)(uintptr_t)s, (long)n));
    return SP_OK;
}
/* recv(block = true): the next message, or nil when none is waiting and block is false */
static SpStatus i_recv(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    static char buf[4096];
    int nb = argc > 0 && argv[0].type == SP_T_BOOL && !argv[0].as.b;
    long n = sc3(1014, (long)(uintptr_t)buf, (long)sizeof buf, nb);
    if (n < 0) {
        *ret = sp_nil();
        return SP_OK;
    }
    return sp_new_string(vm, buf, (size_t)n, ret);
}
static const SpNativeDesc ipc_fns[] = {
    {"shm_create", 1, 1, 0, SP_NATIVE_ALLOCATES, i_shm_create}, {"shm_open", 1, 1, 0, SP_NATIVE_ALLOCATES, i_shm_open},
    {"shm_close", 1, 1, 0, 0, i_shm_close}, {"shm_read", 3, 3, 0, SP_NATIVE_ALLOCATES, i_shm_read},
    {"shm_write", 3, 3, 0, 0, i_shm_write}, {"shm_get", 2, 2, 0, 0, i_shm_get}, {"shm_set", 3, 3, 0, 0, i_shm_set},
    {"send", 2, 2, 0, 0, i_send}, {"recv", 0, 1, 0, SP_NATIVE_ALLOCATES, i_recv},
};

int udev_register(SpVM *vm) {
    (void)sp_register_module(vm, "ipc", ipc_fns, sizeof ipc_fns / sizeof ipc_fns[0]);
    return (int)sp_register_module(vm, "gdev", gdev_fns, sizeof gdev_fns / sizeof gdev_fns[0]);
}
