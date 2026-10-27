/* The `hw` module: raw hardware access for Sprint programs running as the operating system.
 * Everything here is unchecked on purpose - the OS written in Sprint is the only thing in the machine. */
#define SP_EMBED_INTERNAL 1
#include "sp.h"
#include "sprint.h"
#include "kernel.h"
#include "cpu.h"
#include "smp.h"
#include <stdlib.h>
#include <string.h>


static SpStatus need_int(SpVM *vm, SpValue v, int64_t *out) {
    if (v.type != SP_T_INT) return sp_throw(vm, "TypeError", "hw: expected an int, got %s", sp_type_name(v));
    *out = v.as.i;
    return SP_OK;
}
#define ARG_INT(i, var)                                  \
    int64_t var;                                         \
    do {                                                 \
        SpStatus s_ = need_int(vm, argv[i], &var);       \
        if (s_ != SP_OK) return s_;                      \
    } while (0)

static SpStatus h_inb(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, p);
    *ret = sp_int(inb((uint16_t)p));
    return SP_OK;
}
static SpStatus h_inw(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, p);
    *ret = sp_int(inw((uint16_t)p));
    return SP_OK;
}
static SpStatus h_inl(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, p);
    *ret = sp_int(inl((uint16_t)p));
    return SP_OK;
}
static SpStatus h_outb(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, p);
    ARG_INT(1, v);
    outb((uint16_t)p, (uint8_t)v);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_outw(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, p);
    ARG_INT(1, v);
    outw((uint16_t)p, (uint16_t)v);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_outl(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, p);
    ARG_INT(1, v);
    outl((uint16_t)p, (uint32_t)v);
    *ret = sp_nil();
    return SP_OK;
}

#define PEEK(NAME, T)                                                                          \
    static SpStatus NAME(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {              \
        (void)argc;                                                                            \
        ARG_INT(0, a);                                                                         \
        T v;                                                                                   \
        memcpy(&v, (const void *)(uintptr_t)a, sizeof v);                                      \
        *ret = sp_int((int64_t)v);                                                             \
        return SP_OK;                                                                          \
    }
#define POKE(NAME, T)                                                                          \
    static SpStatus NAME(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {              \
        (void)argc;                                                                            \
        ARG_INT(0, a);                                                                         \
        ARG_INT(1, x);                                                                         \
        T v = (T)x;                                                                            \
        memcpy((void *)(uintptr_t)a, &v, sizeof v);                                            \
        *ret = sp_nil();                                                                       \
        return SP_OK;                                                                          \
    }
PEEK(h_peek8, uint8_t)
PEEK(h_peek16, uint16_t)
PEEK(h_peek32, uint32_t)
PEEK(h_peek64, int64_t)
POKE(h_poke8, uint8_t)
POKE(h_poke16, uint16_t)
POKE(h_poke32, uint32_t)
POKE(h_poke64, int64_t)

static SpStatus h_fb_info(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    if (!g_fb.present) {
        *ret = sp_nil();
        return SP_OK;
    }
    SpStatus s = sp_new_array(vm, 5, ret);
    if (s != SP_OK) return s;
    (void)sp_array_push(vm, *ret, sp_int(g_fb.width));
    (void)sp_array_push(vm, *ret, sp_int(g_fb.height));
    (void)sp_array_push(vm, *ret, sp_int(g_fb.pitch));
    (void)sp_array_push(vm, *ret, sp_int(g_fb.bpp));
    (void)sp_array_push(vm, *ret, sp_int((int64_t)g_fb.addr));
    return SP_OK;
}

/* ---- the hardware-style mouse pointer: drawn straight onto the framebuffer, background saved under it ---- */
enum { CUR_MAX = 64, CUR_KEY = 0xFF00FF };
static struct {
    int w, h, hx, hy, x, y, shown, saved_ok;
    uint32_t img[CUR_MAX * CUR_MAX], under[CUR_MAX * CUR_MAX];
} g_cur;

static uint32_t *fb_px(int x, int y) { return (uint32_t *)(uintptr_t)(g_fb.addr + (uint64_t)y * g_fb.pitch) + x; }

static void cur_restore(void) {
    if (!g_cur.saved_ok) return;
    for (int j = 0; j < g_cur.h; j++) {
        int y = g_cur.y - g_cur.hy + j;
        if (y < 0 || y >= (int)g_fb.height) continue;
        for (int i = 0; i < g_cur.w; i++) {
            int x = g_cur.x - g_cur.hx + i;
            if (x >= 0 && x < (int)g_fb.width) *fb_px(x, y) = g_cur.under[j * CUR_MAX + i];
        }
    }
    g_cur.saved_ok = 0;
}
static void cur_draw(void) {
    if (!g_cur.shown || g_cur.w == 0 || !g_fb.present) return;
    for (int j = 0; j < g_cur.h; j++) {
        int y = g_cur.y - g_cur.hy + j;
        if (y < 0 || y >= (int)g_fb.height) continue;
        for (int i = 0; i < g_cur.w; i++) {
            int x = g_cur.x - g_cur.hx + i;
            if (x < 0 || x >= (int)g_fb.width) continue;
            uint32_t *p = fb_px(x, y);
            g_cur.under[j * CUR_MAX + i] = *p;
            uint32_t c = g_cur.img[j * CUR_MAX + i];
            if (c != CUR_KEY) *p = c;
        }
    }
    g_cur.saved_ok = 1;
}

/* cursor_image(canvas, hot_x, hot_y): pixels equal to 0xFF00FF are transparent; the pointer is shown */
static SpStatus h_cursor_image(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    int w, h;
    const uint32_t *px = gfx_canvas_pixels(argv[0], &w, &h);
    if (!px) return sp_throw(vm, "TypeError", "hw.cursor_image: expected a canvas");
    ARG_INT(1, hx);
    ARG_INT(2, hy);
    if (w > CUR_MAX || h > CUR_MAX) return sp_throw(vm, "ValueError", "hw.cursor_image: at most %dx%d", CUR_MAX, CUR_MAX);
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
static SpStatus h_cursor_move(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, x);
    ARG_INT(1, y);
    cur_restore();
    g_cur.x = (int)x;
    g_cur.y = (int)y;
    cur_draw();
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_cursor_show(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    cur_restore();
    g_cur.shown = sp_truthy(argv[0]);
    cur_draw();
    *ret = sp_nil();
    return SP_OK;
}

/* present(canvas, x = 0, y = 0, rx = 0, ry = 0, rw = canvas width, rh = canvas height): copy the canvas
 * rectangle (rx, ry, rw, rh) to the screen at (x + rx, y + ry); the pointer is redrawn on top */
static SpStatus h_present(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    int w, h;
    const uint32_t *px = gfx_canvas_pixels(argv[0], &w, &h);
    if (!px) return sp_throw(vm, "TypeError", "hw.present: expected a canvas, got %s", sp_type_name(argv[0]));
    int64_t v[6] = {0, 0, 0, 0, w, h};
    for (int i = 1; i < argc && i < 7; i++)
        if (need_int(vm, argv[i], &v[i - 1]) != SP_OK) return SP_E_RUNTIME;
    int64_t ox = v[0], oy = v[1], rx = v[2], ry = v[3], rw = v[4], rh = v[5];
    if (!g_fb.present) return sp_throw(vm, "OSError", "hw.present: there is no framebuffer");
    if (rx < 0) { rw += rx; rx = 0; }
    if (ry < 0) { rh += ry; ry = 0; }
    if (rx + rw > w) rw = w - rx;
    if (ry + rh > h) rh = h - ry;
    int64_t n = 0;
    g_cur.saved_ok = 0; /* the pixels under the pointer are about to be overwritten */
    for (int64_t y = ry; y < ry + rh; y++) {
        int64_t sy = oy + y;
        if (sy < 0 || sy >= (int64_t)g_fb.height) continue;
        int64_t x0 = rx, x1 = rx + rw;
        if (ox + x0 < 0) x0 = -ox;
        if (ox + x1 > (int64_t)g_fb.width) x1 = (int64_t)g_fb.width - ox;
        if (x1 <= x0) continue;
        memcpy(fb_px((int)(ox + x0), (int)sy), px + y * w + x0, (size_t)(x1 - x0) * 4);
        n += x1 - x0;
    }
    cur_draw();
    *ret = sp_int(n);
    return SP_OK;
}

static SpStatus h_ticks_ms(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    *ret = sp_int((int64_t)uptime_ms());
    return SP_OK;
}
static SpStatus h_ticks_us(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    *ret = sp_int((int64_t)uptime_us());
    return SP_OK;
}
static SpStatus h_pause(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    __asm__ volatile("pause");
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_mem_info(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    SpStatus s = sp_new_array(vm, 2, ret);
    if (s != SP_OK) return s;
    (void)sp_array_push(vm, *ret, sp_int((int64_t)g_mem_total));
    (void)sp_array_push(vm, *ret, sp_int((int64_t)(g_mem_free_pages * 4096)));
    return SP_OK;
}
static SpStatus h_serial(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_STRING) return sp_throw(vm, "TypeError", "hw.serial: expected a string");
    size_t n;
    const char *s = sp_string_data(argv[0], &n);
    serial_write(s, n);
    *ret = sp_nil();
    return SP_OK;
}
/* log_read(cursor) -> [text, new_cursor]: console output since `cursor` */
static SpStatus h_log_read(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, cur);
    char buf[4096];
    size_t c = (size_t)cur;
    size_t n = log_read(buf, sizeof buf, &c);
    SpValue s;
    SpStatus st = sp_new_string(vm, buf, n, &s);
    if (st != SP_OK) return st;
    st = sp_new_array(vm, 2, ret);
    if (st != SP_OK) return st;
    (void)sp_array_push(vm, *ret, s);
    (void)sp_array_push(vm, *ret, sp_int((int64_t)c));
    return SP_OK;
}
static SpStatus h_cmdline(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    return sp_new_string(vm, g_cmdline, strlen(g_cmdline), ret);
}
static SpStatus h_poweroff(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    (void)ret;
    power_off();
}
static SpStatus h_reboot(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    (void)ret;
    reboot();
}


/* ---- ring 3 support ---------------------------------------------------------------------------- */
extern char pml4[]; /* boot.S: the kernel's page tables (identity map of the first 4 GiB) */

/* ctx_new() -> address of a zeroed thread context (CTX_SIZE bytes, 64-byte aligned) */
static SpStatus h_ctx_new(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    (void)vm;
    void *p = aligned_alloc(64, CTX_SIZE);
    if (!p) return sp_throw(vm, "MemoryError", "hw.ctx_new: out of memory");
    memset(p, 0, CTX_SIZE);
    *ret = sp_int((int64_t)(uintptr_t)p);
    return SP_OK;
}
static SpStatus h_ctx_free(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, a);
    free((void *)(uintptr_t)a);
    *ret = sp_nil();
    return SP_OK;
}
/* enter(ctx) -> vector: run the thread in ring 3 until its next trap (256 = SYSCALL) */
static SpStatus h_enter(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, a);
    *ret = sp_int(enter_user((void *)(uintptr_t)a));
    return SP_OK;
}
static SpStatus h_kernel_cr3(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    *ret = sp_int((int64_t)(uintptr_t)pml4);
    return SP_OK;
}
static SpStatus h_cpu_id(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    uint64_t id;
    __asm__ volatile("movq %%gs:%c1, %0" : "=r"(id) : "i"(PC_ID));
    *ret = sp_int((int64_t)id);
    return SP_OK;
}
static SpStatus h_invlpg(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, a);
    __asm__ volatile("invlpg (%0)" : : "r"((void *)(uintptr_t)a) : "memory");
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_idle(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    __asm__ volatile("sti; hlt; cli");
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_irq_count(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, v);
    *ret = sp_int((int64_t)g_irq_count[v & 255]);
    return SP_OK;
}
static SpStatus h_set_lapic(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    lapic_present = sp_truthy(argv[0]);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_memset(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, a);
    ARG_INT(1, v);
    ARG_INT(2, n);
    memset((void *)(uintptr_t)a, (int)v, (size_t)n);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_memcpy(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, d);
    ARG_INT(1, src);
    ARG_INT(2, n);
    memmove((void *)(uintptr_t)d, (const void *)(uintptr_t)src, (size_t)n);
    *ret = sp_nil();
    return SP_OK;
}
/* str_at(addr, len) -> string with the bytes at addr (raw; not validated as UTF-8 by the caller's text) */
static SpStatus h_str_at(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, a);
    ARG_INT(1, n);
    return sp_new_string(vm, (const char *)(uintptr_t)a, (size_t)n, ret);
}
/* poke_str(addr, s): copy the bytes of s to addr */
static SpStatus h_poke_str(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, a);
    if (argv[1].type != SP_T_STRING) return sp_throw(vm, "TypeError", "hw.poke_str: expected a string");
    size_t n;
    const char *s = sp_string_data(argv[1], &n);
    memcpy((void *)(uintptr_t)a, s, n);
    *ret = sp_int((int64_t)n);
    return SP_OK;
}
static SpStatus h_user_mem(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    SpStatus st = sp_new_array(vm, (size_t)g_nuser_mem, ret);
    if (st != SP_OK) return st;
    for (int i = 0; i < g_nuser_mem; i++) {
        SpValue r;
        st = sp_new_array(vm, 2, &r);
        if (st != SP_OK) return st;
        (void)sp_array_push(vm, r, sp_int((int64_t)g_user_mem[i].start));
        (void)sp_array_push(vm, r, sp_int((int64_t)g_user_mem[i].len));
        (void)sp_array_push(vm, *ret, r);
    }
    return SP_OK;
}

extern const unsigned char initrd_userland_start[];
extern const unsigned char initrd_userland_end[];
/* initrd() -> [address, length] of the embedded user program image */
static SpStatus h_initrd(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    (void)argv;
    SpStatus st = sp_new_array(vm, 2, ret);
    if (st != SP_OK) return st;
    (void)sp_array_push(vm, *ret, sp_int((int64_t)(uintptr_t)initrd_userland_start));
    (void)sp_array_push(vm, *ret, sp_int((int64_t)(initrd_userland_end - initrd_userland_start)));
    return SP_OK;
}

static SpStatus h_rdmsr(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, m);
    uint32_t lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"((uint32_t)m));
    *ret = sp_int((int64_t)(((uint64_t)hi << 32) | lo));
    return SP_OK;
}
static SpStatus h_wrmsr(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, m);
    ARG_INT(1, v);
    __asm__ volatile("wrmsr" : : "c"((uint32_t)m), "a"((uint32_t)(uint64_t)v), "d"((uint32_t)((uint64_t)v >> 32)));
    *ret = sp_nil();
    return SP_OK;
}

extern uint64_t g_rsdp;
static SpStatus h_rsdp(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    *ret = sp_int((int64_t)g_rsdp);
    return SP_OK;
}
/* set_hooks(pick, trap): the Sprint functions every CPU's scheduler loop calls (see smp.c) */
static SpStatus h_set_hooks(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    SpRef *a, *b;
    SpStatus st = sp_ref(vm, argv[0], &a);
    if (st != SP_OK) return st;
    st = sp_ref(vm, argv[1], &b);
    if (st != SP_OK) return st;
    smp_set_hooks(vm, a, b);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_set_timer(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, n);
    smp_set_timer((uint32_t)n);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus h_ap_start(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG_INT(0, apic);
    ARG_INT(1, idx);
    *ret = sp_bool(smp_start_ap((uint32_t)apic, (int)idx));
    return SP_OK;
}
static SpStatus h_kick(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm;
    (void)argc;
    (void)argv;
    smp_kick();
    *ret = sp_nil();
    return SP_OK;
}

static const SpNativeDesc hw_fns[] = {
    {"rsdp", 0, 0, 0, 0, h_rsdp}, {"set_hooks", 2, 2, 0, 0, h_set_hooks}, {"set_timer", 1, 1, 0, 0, h_set_timer},
    {"ap_start", 2, 2, 0, 0, h_ap_start}, {"kick", 0, 0, 0, 0, h_kick},
    {"rdmsr", 1, 1, 0, 0, h_rdmsr}, {"wrmsr", 2, 2, 0, 0, h_wrmsr},
    {"initrd", 0, 0, 0, SP_NATIVE_ALLOCATES, h_initrd},
    {"inb", 1, 1, 0, 0, h_inb}, {"inw", 1, 1, 0, 0, h_inw}, {"inl", 1, 1, 0, 0, h_inl},
    {"outb", 2, 2, 0, 0, h_outb}, {"outw", 2, 2, 0, 0, h_outw}, {"outl", 2, 2, 0, 0, h_outl},
    {"peek8", 1, 1, 0, 0, h_peek8}, {"peek16", 1, 1, 0, 0, h_peek16}, {"peek32", 1, 1, 0, 0, h_peek32},
    {"peek64", 1, 1, 0, 0, h_peek64}, {"poke8", 2, 2, 0, 0, h_poke8}, {"poke16", 2, 2, 0, 0, h_poke16},
    {"poke32", 2, 2, 0, 0, h_poke32}, {"poke64", 2, 2, 0, 0, h_poke64},
    {"fb_info", 0, 0, 0, SP_NATIVE_ALLOCATES, h_fb_info}, {"present", 1, 7, 0, 0, h_present}, {"cursor_image", 3, 3, 0, 0, h_cursor_image},
    {"cursor_move", 2, 2, 0, 0, h_cursor_move}, {"cursor_show", 1, 1, 0, 0, h_cursor_show},
    {"ticks_ms", 0, 0, 0, 0, h_ticks_ms}, {"ticks_us", 0, 0, 0, 0, h_ticks_us}, {"pause", 0, 0, 0, 0, h_pause},
    {"mem_info", 0, 0, 0, SP_NATIVE_ALLOCATES, h_mem_info}, {"serial", 1, 1, 0, 0, h_serial},
    {"log_read", 1, 1, 0, SP_NATIVE_ALLOCATES, h_log_read}, {"cmdline", 0, 0, 0, SP_NATIVE_ALLOCATES, h_cmdline},
    {"ctx_new", 0, 0, 0, 0, h_ctx_new}, {"ctx_free", 1, 1, 0, 0, h_ctx_free}, {"enter", 1, 1, 0, 0, h_enter},
    {"kernel_cr3", 0, 0, 0, 0, h_kernel_cr3}, {"cpu_id", 0, 0, 0, 0, h_cpu_id}, {"invlpg", 1, 1, 0, 0, h_invlpg},
    {"idle", 0, 0, 0, 0, h_idle}, {"irq_count", 1, 1, 0, 0, h_irq_count}, {"set_lapic", 1, 1, 0, 0, h_set_lapic},
    {"memset", 3, 3, 0, 0, h_memset}, {"memcpy", 3, 3, 0, 0, h_memcpy}, {"str_at", 2, 2, 0, SP_NATIVE_ALLOCATES, h_str_at},
    {"poke_str", 2, 2, 0, 0, h_poke_str}, {"user_mem", 0, 0, 0, SP_NATIVE_ALLOCATES, h_user_mem},
    {"poweroff", 0, 0, 0, 0, h_poweroff}, {"reboot", 0, 0, 0, 0, h_reboot},
};

int hw_register(SpVM *vm) { return (int)sp_register_module(vm, "hw", hw_fns, sizeof hw_fns / sizeof hw_fns[0]); }
