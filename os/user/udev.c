/* Module `gdev`: the screen, pointer and input devices as seen from a user process. The kernel maps the
 * framebuffer into the process (system call 1002) and hands out keyboard/mouse events as text lines (1003). */
#define SP_EMBED_INTERNAL 1
#include "sp.h"
#include "sprint.h"
#include "udev.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static long sc3(long n, long a, long b, long c) {
    long r;
    __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return r;
}

static long sc4(long n, long a, long b, long c, long d) {
    long r;
    register long r10 __asm__("r10") = d;
    __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory");
    return r;
}

static long sc5(long n, long a, long b, long c, long d, long e) {
    long r;
    register long r10 __asm__("r10") = d;
    register long r8 __asm__("r8") = e;
    __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
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

/* fb_use(address, width, height, pitch): draw into memory the caller already has (the GPU server's shared pixel segment) instead of the kernel's framebuffer */
static SpStatus d_fb_use(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t a, w, h, pitch;
    if (need_i(vm, argv[0], &a) != SP_OK || need_i(vm, argv[1], &w) != SP_OK || need_i(vm, argv[2], &h) != SP_OK || need_i(vm, argv[3], &pitch) != SP_OK)
        return SP_E_RUNTIME;
    g_fb.addr = (uint8_t *)(uintptr_t)a;
    g_fb.w = (uint32_t)w;
    g_fb.h = (uint32_t)h;
    g_fb.pitch = (uint32_t)pitch;
    *ret = sp_nil();
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
    {"fb_map", 0, 0, 0, SP_NATIVE_ALLOCATES, d_fb_map}, {"fb_use", 4, 4, 0, 0, d_fb_use}, {"present", 1, 7, 0, 0, d_present},
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
/* shm_bytes(va, off, n): n bytes of a segment as a typed.u8 (binary safe); shm_put(va, off, bytes): store a typed.u8 or an array of bytes */
static SpStatus i_shm_bytes(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t n;
    if (need_i(vm, argv[2], &n) != SP_OK) return SP_E_RUNTIME;
    const uint8_t *p = shm_span(vm, argv[0], argv[1], n, "shm_bytes");
    if (!p) return SP_E_RUNTIME;
    *ret = typed_u8_from(vm, p, (size_t)n);
    return SP_OK;
}
static SpStatus i_shm_put(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    unsigned char *d = typed_u8_data(argv[2]);
    if (!d) return sp_throw(vm, "TypeError", "ipc.shm_put: expected a typed.u8");
    size_t n = (size_t)typed_len(argv[2]);
    uint8_t *p = shm_span(vm, argv[0], argv[1], (int64_t)n, "shm_put");
    if (!p) return SP_E_RUNTIME;
    memcpy(p, d, n);
    *ret = sp_nil();
    return SP_OK;
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
    long n = sc4(1014, (long)(uintptr_t)buf, (long)sizeof buf, nb, 0);
    if (n < 0) {
        *ret = sp_nil();
        return SP_OK;
    }
    return sp_new_string(vm, buf, (size_t)n, ret);
}
/* shm_to_canvas(va, canvas) / canvas_to_shm(canvas, va): copy a window's pixels (0xRRGGBB words, row after row) between a shared segment and a canvas */
static SpStatus i_shm_to_canvas(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int w, h;
    const uint32_t *px = gfx_canvas_pixels(argv[1], &w, &h);
    if (!px) return sp_throw(vm, "TypeError", "ipc.shm_to_canvas: expected a canvas");
    const uint8_t *src = shm_span(vm, argv[0], sp_int(0), (int64_t)w * h * 4, "shm_to_canvas");
    if (!src) return SP_E_RUNTIME;
    memcpy((uint32_t *)(uintptr_t)px, src, (size_t)w * (size_t)h * 4);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus i_canvas_to_shm(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int w, h;
    const uint32_t *px = gfx_canvas_pixels(argv[0], &w, &h);
    if (!px) return sp_throw(vm, "TypeError", "ipc.canvas_to_shm: expected a canvas");
    uint8_t *dst = shm_span(vm, argv[1], sp_int(0), (int64_t)w * h * 4, "canvas_to_shm");
    if (!dst) return SP_E_RUNTIME;
    memcpy(dst, px, (size_t)w * (size_t)h * 4);
    *ret = sp_nil();
    return SP_OK;
}
/* recv_from(block = true, timeout_ms = 0): [sender pid, message], or nil when none is waiting and block is false, or when the timeout (blocking, > 0) ran out. The sender
 * is the kernel's word, not the message's; interrupts arrive from sender 0 as "irq<TAB>n". */
static SpStatus i_recv_from(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    static char buf[4096];
    int nb = argc > 0 && argv[0].type == SP_T_BOOL && !argv[0].as.b;
    int64_t from = 0;
    int64_t tmo = 0;
    if (argc > 1 && argv[1].type == SP_T_INT) tmo = argv[1].as.i;
    long n = sc5(1014, (long)(uintptr_t)buf, (long)sizeof buf, nb, (long)(uintptr_t)&from, (long)(tmo * 1000));
    if (n < 0) {
        *ret = sp_nil();
        return SP_OK;
    }
    SpValue msg;
    SpStatus st = sp_new_string(vm, buf, (size_t)n, &msg);
    if (st != SP_OK) return st;
    st = sp_new_array(vm, 2, ret);
    if (st != SP_OK) return st;
    (void)sp_array_push(vm, *ret, sp_int(from));
    (void)sp_array_push(vm, *ret, msg);
    return SP_OK;
}
/* irq_register(irq, pci): take interrupt irq (an ISA irq; with pci true a global system interrupt) -> the global interrupt number; irq_ack(n) after serving the device */
static SpStatus i_irq_register(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t irq;
    if (need_i(vm, argv[0], &irq) != SP_OK) return SP_E_RUNTIME;
    int pci = argv[1].type == SP_T_BOOL && argv[1].as.b;
    long r = sc3(1030, (long)irq, pci, 0);
    if (r < 0) return sp_throw(vm, "OSError", "ipc.irq_register: error %ld", r);
    *ret = sp_int(r);
    return SP_OK;
}
static SpStatus i_irq_ack(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t gsi;
    if (need_i(vm, argv[0], &gsi) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1031, (long)gsi, 0, 0));
    return SP_OK;
}
/* register(name): this process serves `name`; lookup(name): the pid serving it, or nil */
static SpStatus i_register(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_STRING) return sp_throw(vm, "TypeError", "ipc.register: expected a name");
    size_t n;
    const char *s = sp_string_data(argv[0], &n);
    long r = sc3(1015, (long)(uintptr_t)s, (long)n, 0);
    if (r < 0) return sp_throw(vm, "OSError", "ipc.register: error %ld", r);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus i_lookup(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_STRING) return sp_throw(vm, "TypeError", "ipc.lookup: expected a name");
    size_t n;
    const char *s = sp_string_data(argv[0], &n);
    long r = sc3(1016, (long)(uintptr_t)s, (long)n, 0);
    *ret = r < 0 ? sp_nil() : sp_int(r);
    return SP_OK;
}
static const SpNativeDesc ipc_fns[] = {
    {"shm_to_canvas", 2, 2, 0, 0, i_shm_to_canvas}, {"canvas_to_shm", 2, 2, 0, 0, i_canvas_to_shm},
    {"recv_from", 0, 2, 0, SP_NATIVE_ALLOCATES, i_recv_from}, {"irq_register", 2, 2, 0, 0, i_irq_register}, {"irq_ack", 1, 1, 0, 0, i_irq_ack}, {"register", 1, 1, 0, 0, i_register}, {"lookup", 1, 1, 0, 0, i_lookup},
    {"shm_create", 1, 1, 0, SP_NATIVE_ALLOCATES, i_shm_create}, {"shm_open", 1, 1, 0, SP_NATIVE_ALLOCATES, i_shm_open},
    {"shm_close", 1, 1, 0, 0, i_shm_close}, {"shm_read", 3, 3, 0, SP_NATIVE_ALLOCATES, i_shm_read},
    {"shm_write", 3, 3, 0, 0, i_shm_write}, {"shm_bytes", 3, 3, 0, SP_NATIVE_ALLOCATES, i_shm_bytes}, {"shm_put", 3, 3, 0, 0, i_shm_put}, {"shm_get", 2, 2, 0, 0, i_shm_get}, {"shm_set", 3, 3, 0, 0, i_shm_set},
    {"send", 2, 2, 0, 0, i_send}, {"recv", 0, 1, 0, SP_NATIVE_ALLOCATES, i_recv},
};


/* ---- module `lx`: what the personality server linuxd uses to create and drive Linux programs (system calls 1040..1049; the kernel only lets linuxd use them) ---- */
static SpStatus lx_int(SpVM *vm, const SpValue *argv, int i, int64_t *out) { return need_i(vm, argv[i], out); }
static SpStatus l_create(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    *ret = sp_int(sc3(1040, 0, 0, 0));
    return SP_OK;
}
static SpStatus l_map3(SpVM *vm, const SpValue *argv, long nr, SpValue *ret) {
    int64_t pid, a, n, prot = 0;
    if (lx_int(vm, argv, 0, &pid) != SP_OK || lx_int(vm, argv, 1, &a) != SP_OK || lx_int(vm, argv, 2, &n) != SP_OK) return SP_E_RUNTIME;
    if (nr != 1042 && lx_int(vm, argv, 3, &prot) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc4(nr, (long)pid, (long)a, (long)n, (long)prot));
    return SP_OK;
}
static SpStatus l_map(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_map3(vm, argv, 1041, ret); }
static SpStatus l_unmap(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_map3(vm, argv, 1042, ret); }
static SpStatus l_protect(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_map3(vm, argv, 1043, ret); }
/* write(pid, addr, bytes [, off [, n]]): copy bytes[off .. off+n) into the program at addr */
static SpStatus l_write(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    int64_t pid, a, off = 0, n = -1;
    if (lx_int(vm, argv, 0, &pid) != SP_OK || lx_int(vm, argv, 1, &a) != SP_OK) return SP_E_RUNTIME;
    unsigned char *d = typed_u8_data(argv[2]);
    if (!d) return sp_throw(vm, "TypeError", "lx.write: expected a typed.u8");
    int64_t len = typed_len(argv[2]);
    if (argc > 3 && lx_int(vm, argv, 3, &off) != SP_OK) return SP_E_RUNTIME;
    if (argc > 4 && lx_int(vm, argv, 4, &n) != SP_OK) return SP_E_RUNTIME;
    if (n < 0) n = len - off;
    if (off < 0 || n < 0 || off + n > len) return sp_throw(vm, "IndexError", "lx.write: range outside the buffer");
    *ret = sp_int(sc4(1044, (long)pid, (long)a, (long)(uintptr_t)(d + off), (long)n));
    return SP_OK;
}
static SpStatus l_read(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid, a, n;
    if (lx_int(vm, argv, 0, &pid) != SP_OK || lx_int(vm, argv, 1, &a) != SP_OK || lx_int(vm, argv, 2, &n) != SP_OK) return SP_E_RUNTIME;
    if (n < 0 || n > (64 << 20)) return sp_throw(vm, "ValueError", "lx.read: bad length");
    unsigned char *tmp = (unsigned char *)malloc((size_t)n + 1);
    if (!tmp) return sp_throw(vm, "MemoryError", "lx.read: out of memory");
    long r = sc4(1045, (long)pid, (long)a, (long)(uintptr_t)tmp, (long)n);
    *ret = r == 0 ? typed_u8_from(vm, tmp, (size_t)n) : sp_nil();
    free(tmp);
    return SP_OK;
}
static SpStatus l_call3(SpVM *vm, const SpValue *argv, long nr, SpValue *ret) {
    int64_t a, b, c = 0;
    if (lx_int(vm, argv, 0, &a) != SP_OK || lx_int(vm, argv, 1, &b) != SP_OK) return SP_E_RUNTIME;
    if (nr == 1046 && lx_int(vm, argv, 2, &c) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(nr, (long)a, (long)b, (long)c));
    return SP_OK;
}
static SpStatus l_fork(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid;
    if (lx_int(vm, argv, 0, &pid) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1050, (long)pid, 0, 0));
    return SP_OK;
}
static SpStatus l_reset(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid;
    if (lx_int(vm, argv, 0, &pid) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1051, (long)pid, 0, 0));
    return SP_OK;
}
static SpStatus l_clone(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_call3(vm, argv, 1052, ret); }
static SpStatus l_resume(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid;
    if (lx_int(vm, argv, 0, &pid) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1053, (long)pid, 0, 0));
    return SP_OK;
}
static SpStatus l_setsp(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_call3(vm, argv, 1054, ret); }
/* getctx(pid) -> typed.u8 of 83 words (see sched.sp, lx_getctx); setctx(pid, bytes); sigpend(pid, on) */
static SpStatus l_getctx(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid;
    if (lx_int(vm, argv, 0, &pid) != SP_OK) return SP_E_RUNTIME;
    uint64_t tmp[83];
    long r = sc3(1055, (long)pid, (long)(uintptr_t)tmp, 0);
    *ret = r == 0 ? typed_u8_from(vm, (const unsigned char *)tmp, sizeof tmp) : sp_nil();
    return SP_OK;
}
static SpStatus l_setctx(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid;
    if (lx_int(vm, argv, 0, &pid) != SP_OK) return SP_E_RUNTIME;
    unsigned char *d = typed_u8_data(argv[1]);
    if (!d || typed_len(argv[1]) != 83 * 8) return sp_throw(vm, "ValueError", "lx.setctx: expected 664 bytes");
    uint64_t tmp[83];
    memcpy(tmp, d, sizeof tmp);
    *ret = sp_int(sc3(1056, (long)pid, (long)(uintptr_t)tmp, 0));
    return SP_OK;
}
static SpStatus l_sigpend(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid, on;
    if (lx_int(vm, argv, 0, &pid) != SP_OK || lx_int(vm, argv, 1, &on) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1057, (long)pid, (long)on, 0));
    return SP_OK;
}
static SpStatus l_shm_attach(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid, addr, id;
    if (lx_int(vm, argv, 0, &pid) != SP_OK || lx_int(vm, argv, 1, &addr) != SP_OK || lx_int(vm, argv, 2, &id) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1058, (long)pid, (long)addr, (long)id));
    return SP_OK;
}
static SpStatus l_shm_detach(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t pid, addr;
    if (lx_int(vm, argv, 0, &pid) != SP_OK || lx_int(vm, argv, 1, &addr) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1059, (long)pid, (long)addr, 0));
    return SP_OK;
}
static SpStatus l_shm_new(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t n;
    if (lx_int(vm, argv, 0, &n) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1060, (long)n, 0, 0));
    return SP_OK;
}
static SpStatus l_shm_drop(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t id;
    if (lx_int(vm, argv, 0, &id) != SP_OK) return SP_E_RUNTIME;
    *ret = sp_int(sc3(1061, (long)id, 0, 0));
    return SP_OK;
}
static SpStatus l_start(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_call3(vm, argv, 1046, ret); }
static SpStatus l_reply(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_call3(vm, argv, 1047, ret); }
static SpStatus l_kill(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_call3(vm, argv, 1048, ret); }
static SpStatus l_setfs(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) { (void)argc; return l_call3(vm, argv, 1049, ret); }
static const SpNativeDesc lx_fns[] = {
    {"create", 0, 0, 0, 0, l_create}, {"map", 4, 4, 0, 0, l_map}, {"unmap", 3, 3, 0, 0, l_unmap}, {"protect", 4, 4, 0, 0, l_protect},
    {"write", 3, 5, 0, 0, l_write}, {"read", 3, 3, 0, SP_NATIVE_ALLOCATES, l_read}, {"start", 3, 3, 0, 0, l_start},
    {"reply", 2, 2, 0, 0, l_reply}, {"fork", 1, 1, 0, 0, l_fork}, {"shm_attach", 3, 3, 0, 0, l_shm_attach}, {"shm_new", 1, 1, 0, 0, l_shm_new}, {"shm_drop", 1, 1, 0, 0, l_shm_drop}, {"shm_detach", 2, 2, 0, 0, l_shm_detach}, {"getctx", 1, 1, 0, SP_NATIVE_ALLOCATES, l_getctx}, {"setctx", 2, 2, 0, 0, l_setctx}, {"sigpend", 2, 2, 0, 0, l_sigpend}, {"clone", 2, 2, 0, 0, l_clone}, {"resume", 1, 1, 0, 0, l_resume}, {"setsp", 2, 2, 0, 0, l_setsp}, {"reset", 1, 1, 0, 0, l_reset}, {"kill", 2, 2, 0, 0, l_kill}, {"setfs", 2, 2, 0, 0, l_setfs},
};


/* ---- ATA PIO in C: whole sectors with rep insw / outsw (the ports must be open to this process: fsd) ---- */
static int ata_wait(uint16_t base, uint8_t mask, uint8_t want) {
    for (long i = 0; i < 5000000; i++) {
        uint8_t st;
        __asm__ volatile("inb %1, %0" : "=a"(st) : "Nd"((uint16_t)(base + 7)));
        if ((st & mask) == want) return 0;
        if (st & 0x01) return -1;                /* ERR */
    }
    return -2;
}
static void ata_select(uint16_t base, int slave, uint64_t lba, int count) {
    __asm__ volatile("outb %0, %1" : : "a"((uint8_t)(0xE0u | ((unsigned)slave << 4) | (unsigned)((lba >> 24) & 15))), "Nd"((uint16_t)(base + 6)));
    __asm__ volatile("outb %0, %1" : : "a"((uint8_t)count), "Nd"((uint16_t)(base + 2)));
    __asm__ volatile("outb %0, %1" : : "a"((uint8_t)lba), "Nd"((uint16_t)(base + 3)));
    __asm__ volatile("outb %0, %1" : : "a"((uint8_t)(lba >> 8)), "Nd"((uint16_t)(base + 4)));
    __asm__ volatile("outb %0, %1" : : "a"((uint8_t)(lba >> 16)), "Nd"((uint16_t)(base + 5)));
}
static void ata_settle(uint16_t ctl) {
    for (int i = 0; i < 4; i++) { uint8_t x; __asm__ volatile("inb %1, %0" : "=a"(x) : "Nd"(ctl)); (void)x; }
}
/* ata_read(base, ctl, slave, lba, count) -> typed.u8 of count * 512 bytes, or an error number (negative) */
static SpStatus u_ata_read(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t base, ctl, slave, lba, count;
    if (need_i(vm, argv[0], &base) != SP_OK || need_i(vm, argv[1], &ctl) != SP_OK || need_i(vm, argv[2], &slave) != SP_OK ||
        need_i(vm, argv[3], &lba) != SP_OK || need_i(vm, argv[4], &count) != SP_OK) return SP_E_RUNTIME;
    if (count < 1 || count > 4096) return sp_throw(vm, "ValueError", "uio.ata_read: bad sector count");
    uint8_t *buf = (uint8_t *)malloc((size_t)count * 512);
    if (!buf) return sp_throw(vm, "MemoryError", "uio.ata_read: out of memory");
    int64_t done = 0;
    int err = 0;
    while (done < count && !err) {
        int n = (int)((count - done) > 128 ? 128 : (count - done));
        if (ata_wait((uint16_t)base, 0x80, 0)) { err = -1; break; }
        ata_select((uint16_t)base, (int)slave, (uint64_t)(lba + done), n);
        __asm__ volatile("outb %0, %1" : : "a"((uint8_t)0x20), "Nd"((uint16_t)(base + 7)));
        ata_settle((uint16_t)ctl);
        for (int s = 0; s < n; s++) {
            if (ata_wait((uint16_t)base, 0x88, 0x08)) { err = -2; break; }
            void *dst = buf + (size_t)(done + s) * 512;
            __asm__ volatile("rep insw" : "+D"(dst), "+c"((long){256}) : "d"((uint16_t)base) : "memory");
        }
        done += n;
    }
    if (err) { free(buf); *ret = sp_int(err); return SP_OK; }
    *ret = typed_u8_from(vm, buf, (size_t)count * 512);
    free(buf);
    return SP_OK;
}
/* ata_write(base, ctl, slave, lba, bytes) -> 0 or a negative error; bytes is a typed.u8 whose length is a multiple of 512 */
static SpStatus u_ata_write(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t base, ctl, slave, lba;
    if (need_i(vm, argv[0], &base) != SP_OK || need_i(vm, argv[1], &ctl) != SP_OK || need_i(vm, argv[2], &slave) != SP_OK || need_i(vm, argv[3], &lba) != SP_OK) return SP_E_RUNTIME;
    unsigned char *d = typed_u8_data(argv[4]);
    int64_t len = typed_len(argv[4]);
    if (!d || len < 512 || (len % 512) != 0) return sp_throw(vm, "ValueError", "uio.ata_write: expected a typed.u8 of whole sectors");
    int64_t count = len / 512, done = 0;
    int err = 0;
    while (done < count && !err) {
        int n = (int)((count - done) > 128 ? 128 : (count - done));
        if (ata_wait((uint16_t)base, 0x80, 0)) { err = -1; break; }
        ata_select((uint16_t)base, (int)slave, (uint64_t)(lba + done), n);
        __asm__ volatile("outb %0, %1" : : "a"((uint8_t)0x30), "Nd"((uint16_t)(base + 7)));
        ata_settle((uint16_t)ctl);
        for (int s = 0; s < n; s++) {
            if (ata_wait((uint16_t)base, 0x88, 0x08)) { err = -2; break; }
            const void *src = d + (size_t)(done + s) * 512;
            __asm__ volatile("rep outsw" : "+S"(src), "+c"((long){256}) : "d"((uint16_t)base) : "memory");
        }
        done += n;
    }
    if (!err && ata_wait((uint16_t)base, 0x80, 0)) err = -3;
    *ret = sp_int(err);
    return SP_OK;
}

/* ---- module `uio`: port I/O for a driver process (the kernel opens the ports in its I/O permission bitmap; anything else faults) ---- */
static SpStatus u_inb(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t p;
    if (need_i(vm, argv[0], &p) != SP_OK) return SP_E_RUNTIME;
    uint8_t v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"((uint16_t)p));
    *ret = sp_int(v);
    return SP_OK;
}
static SpStatus u_inw(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t p;
    if (need_i(vm, argv[0], &p) != SP_OK) return SP_E_RUNTIME;
    uint16_t v;
    __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"((uint16_t)p));
    *ret = sp_int(v);
    return SP_OK;
}
static SpStatus u_outb(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t p, v;
    if (need_i(vm, argv[0], &p) != SP_OK || need_i(vm, argv[1], &v) != SP_OK) return SP_E_RUNTIME;
    __asm__ volatile("outb %0, %1" : : "a"((uint8_t)v), "Nd"((uint16_t)p));
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus u_outw(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t p, v;
    if (need_i(vm, argv[0], &p) != SP_OK || need_i(vm, argv[1], &v) != SP_OK) return SP_E_RUNTIME;
    __asm__ volatile("outw %0, %1" : : "a"((uint16_t)v), "Nd"((uint16_t)p));
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus u_inl(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t p;
    if (need_i(vm, argv[0], &p) != SP_OK) return SP_E_RUNTIME;
    uint32_t v;
    __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"((uint16_t)p));
    *ret = sp_int(v);
    return SP_OK;
}
static SpStatus u_outl(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t p, v;
    if (need_i(vm, argv[0], &p) != SP_OK || need_i(vm, argv[1], &v) != SP_OK) return SP_E_RUNTIME;
    __asm__ volatile("outl %0, %1" : : "a"((uint32_t)v), "Nd"((uint16_t)p));
    *ret = sp_nil();
    return SP_OK;
}
/* mmio_map(phys, bytes) -> address (device registers, uncached; drivers only) */
static SpStatus u_mmio_map(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t p, n;
    if (need_i(vm, argv[0], &p) != SP_OK || need_i(vm, argv[1], &n) != SP_OK) return SP_E_RUNTIME;
    long r = sc3(1020, (long)p, (long)n, 0);
    if (r < 0) return sp_throw(vm, "OSError", "uio.mmio_map: error %ld", r);
    *ret = sp_int(r);
    return SP_OK;
}
/* dma_alloc(bytes) -> [segment id, address, physical address, bytes] (physically contiguous; drivers only) */
static SpStatus u_dma_alloc(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t n;
    if (need_i(vm, argv[0], &n) != SP_OK) return SP_E_RUNTIME;
    uint64_t out[4] = {0, 0, 0, 0};
    long r = sc3(1021, (long)n, (long)(uintptr_t)out, 0);
    if (r < 0) return sp_throw(vm, "OSError", "uio.dma_alloc: error %ld", r);
    shm_note(out[1], out[3]);
    SpStatus st = sp_new_array(vm, 4, ret);
    if (st != SP_OK) return st;
    for (int i = 0; i < 4; i++) (void)sp_array_push(vm, *ret, sp_int((int64_t)out[i]));
    return SP_OK;
}
/* raw memory of this process (mapped device registers, DMA memory): peek8..peek64(address), poke8..poke64(address, value) */
#define MEMOP(N, T)                                                                                                         \
    static SpStatus u_peek##N(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {                                      \
        (void)argc;                                                                                                         \
        int64_t a;                                                                                                          \
        if (need_i(vm, argv[0], &a) != SP_OK) return SP_E_RUNTIME;                                                          \
        *ret = sp_int((int64_t)*(volatile T *)(uintptr_t)a);                                                                \
        return SP_OK;                                                                                                       \
    }                                                                                                                       \
    static SpStatus u_poke##N(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {                                      \
        (void)argc;                                                                                                         \
        int64_t a, v;                                                                                                       \
        if (need_i(vm, argv[0], &a) != SP_OK || need_i(vm, argv[1], &v) != SP_OK) return SP_E_RUNTIME;                      \
        *(volatile T *)(uintptr_t)a = (T)v;                                                                                 \
        *ret = sp_nil();                                                                                                    \
        return SP_OK;                                                                                                       \
    }
MEMOP(8, uint8_t)
MEMOP(16, uint16_t)
MEMOP(32, uint32_t)
MEMOP(64, uint64_t)
static SpStatus u_peek_str(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t a, n;
    if (need_i(vm, argv[0], &a) != SP_OK || need_i(vm, argv[1], &n) != SP_OK) return SP_E_RUNTIME;
    return sp_new_string(vm, (const char *)(uintptr_t)a, (size_t)n, ret);
}
static SpStatus u_poke_str(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t a;
    if (need_i(vm, argv[0], &a) != SP_OK) return SP_E_RUNTIME;
    if (argv[1].type != SP_T_STRING) return sp_throw(vm, "TypeError", "uio.poke_str: expected a string");
    size_t n;
    const char *s = sp_string_data(argv[1], &n);
    memcpy((void *)(uintptr_t)a, s, n);
    *ret = sp_nil();
    return SP_OK;
}
/* mem_get(address, n) -> typed.u8 copy of n bytes of this process's memory (DMA buffers); mem_put(address, typed.u8) copies the other way */
static SpStatus u_mem_get(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t a, n;
    if (need_i(vm, argv[0], &a) != SP_OK || need_i(vm, argv[1], &n) != SP_OK) return SP_E_RUNTIME;
    if (n < 0 || n > (64 << 20)) return sp_throw(vm, "ValueError", "uio.mem_get: bad length");
    *ret = typed_u8_from(vm, (const uint8_t *)(uintptr_t)a, (size_t)n);
    return SP_OK;
}
static SpStatus u_mem_put(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int64_t a;
    if (need_i(vm, argv[0], &a) != SP_OK) return SP_E_RUNTIME;
    unsigned char *d = typed_u8_data(argv[1]);
    int64_t len = typed_len(argv[1]);
    if (!d || len < 0) return sp_throw(vm, "TypeError", "uio.mem_put: expected a typed.u8");
    memcpy((void *)(uintptr_t)a, d, (size_t)len);
    *ret = sp_nil();
    return SP_OK;
}
static const SpNativeDesc uio_fns[] = {
    {"mem_get", 2, 2, 0, SP_NATIVE_ALLOCATES, u_mem_get}, {"mem_put", 2, 2, 0, 0, u_mem_put},
    {"ata_read", 5, 5, 0, SP_NATIVE_ALLOCATES, u_ata_read}, {"ata_write", 5, 5, 0, 0, u_ata_write}, {"inb", 1, 1, 0, 0, u_inb}, {"inw", 1, 1, 0, 0, u_inw}, {"outb", 2, 2, 0, 0, u_outb}, {"outw", 2, 2, 0, 0, u_outw},
    {"inl", 1, 1, 0, 0, u_inl}, {"outl", 2, 2, 0, 0, u_outl}, {"mmio_map", 2, 2, 0, 0, u_mmio_map},
    {"dma_alloc", 1, 1, 0, SP_NATIVE_ALLOCATES, u_dma_alloc},
    {"peek8", 1, 1, 0, 0, u_peek8}, {"peek16", 1, 1, 0, 0, u_peek16}, {"peek32", 1, 1, 0, 0, u_peek32}, {"peek64", 1, 1, 0, 0, u_peek64},
    {"poke8", 2, 2, 0, 0, u_poke8}, {"poke16", 2, 2, 0, 0, u_poke16}, {"poke32", 2, 2, 0, 0, u_poke32}, {"poke64", 2, 2, 0, 0, u_poke64},
    {"peek_str", 2, 2, 0, SP_NATIVE_ALLOCATES, u_peek_str}, {"poke_str", 2, 2, 0, 0, u_poke_str},
};

int udev_register(SpVM *vm) {
    (void)sp_register_module(vm, "uio", uio_fns, sizeof uio_fns / sizeof uio_fns[0]);
    (void)sp_register_module(vm, "ipc", ipc_fns, sizeof ipc_fns / sizeof ipc_fns[0]);
    (void)sp_register_module(vm, "lx", lx_fns, sizeof lx_fns / sizeof lx_fns[0]);
    return (int)sp_register_module(vm, "gdev", gdev_fns, sizeof gdev_fns / sizeof gdev_fns[0]);
}
