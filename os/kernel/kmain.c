/* Sprint OS: kernel entry, memory, console, clock and the Linux-syscall emulation musl needs. */
#define SP_EMBED_INTERNAL 1
#include "sp.h"
#include "sprint.h"
#include "kernel.h"
#include "cpu.h"
#include "smp.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>

extern char _end[];
extern uint64_t mbi_ptr;
extern int __libc_start_main(int (*)(int, char **, char **), int, char **, void (*)(void), void (*)(void), void (*)(void));

Framebuffer g_fb;
const char *g_cmdline = "";
uint64_t g_mem_total, g_mem_free_pages;

/* ------------------------------------------------------------------ */
/* port I/O helpers, serial                                            */
/* ------------------------------------------------------------------ */
static void wrmsr(uint32_t msr, uint64_t v) {
    __asm__ volatile("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}

static void serial_init(void) {
    outb(0x3F9, 0);
    outb(0x3FB, 0x80);
    outb(0x3F8, 1); /* 115200 baud */
    outb(0x3F9, 0);
    outb(0x3FB, 3);
    outb(0x3FA, 0xC7);
    outb(0x3FC, 0x0B);
}

/* a ring buffer keeps what was printed so that Sprint code can show a console */
enum { LOG_SIZE = 64 * 1024 };
static char g_log[LOG_SIZE];
static uint64_t g_log_end;

void serial_write(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        g_log[g_log_end++ % LOG_SIZE] = s[i];
        for (int spin = 0; spin < 100000 && !(inb(0x3FD) & 0x20); spin++) {}
        outb(0x3F8, (uint8_t)s[i]);
    }
}
void serial_puts(const char *s) { serial_write(s, strlen(s)); }

/* copy log text from *cursor (a monotonically growing offset) into out; returns the byte count */
size_t log_read(char *out, size_t max, size_t *cursor) {
    uint64_t from = *cursor;
    if (g_log_end > LOG_SIZE && from < g_log_end - LOG_SIZE) from = g_log_end - LOG_SIZE;
    size_t n = 0;
    while (from < g_log_end && n < max) out[n++] = g_log[from++ % LOG_SIZE];
    *cursor = (size_t)from;
    return n;
}

static void put_hex(uint64_t v) {
    char b[19] = "0x";
    for (int i = 0; i < 16; i++) b[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 15];
    b[18] = 0;
    serial_puts(b);
}

void exception_report(uint64_t vec, uint64_t err, uint64_t rip, uint64_t cr2) {
    serial_puts("\n*** CPU exception ");
    put_hex(vec);
    serial_puts(" err=");
    put_hex(err);
    serial_puts(" rip=");
    put_hex(rip);
    serial_puts(" cr2=");
    put_hex(cr2);
    serial_puts("\n");
    for (;;) __asm__ volatile("cli; hlt");
}

void kpanic(const char *msg) {
    serial_puts("\nkernel panic: ");
    serial_puts(msg);
    serial_puts("\n");
    for (;;) __asm__ volatile("cli; hlt");
}

void power_off(void) {
    outw(0x604, 0x2000); /* QEMU / ACPI */
    outw(0xB004, 0x2000); /* Bochs */
    outw(0x4004, 0x3400); /* VirtualBox */
    outb(0xF4, 0);        /* QEMU isa-debug-exit, when the device is present */
    kpanic("power off is not supported here");
}

void reboot(void) {
    for (int i = 0; i < 100000 && (inb(0x64) & 2); i++) {}
    outb(0x64, 0xFE); /* pulse the CPU reset line through the keyboard controller */
    kpanic("reboot failed");
}

/* ------------------------------------------------------------------ */
/* clock: the TSC, calibrated against the PIT                          */
/* ------------------------------------------------------------------ */
static uint64_t g_tsc_hz = 2000000000ull, g_tsc0;
static inline uint64_t rdtsc(void) {
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}
static void clock_init(void) {
    outb(0x61, (uint8_t)((inb(0x61) & 0xFC) | 1)); /* gate channel 2, speaker off */
    outb(0x43, 0xB0);                              /* channel 2, lobyte/hibyte, mode 0 */
    outb(0x42, 0x9C);                              /* 11932 ticks of 1.193182 MHz = 10 ms */
    outb(0x42, 0x2E);
    uint64_t t0 = rdtsc();
    for (int spin = 0; spin < 50000000 && !(inb(0x61) & 0x20); spin++) {}
    uint64_t t1 = rdtsc();
    if (t1 > t0 + 1000000) g_tsc_hz = (t1 - t0) * 100;
    g_tsc0 = rdtsc();
}
uint64_t uptime_us(void) { return (rdtsc() - g_tsc0) / (g_tsc_hz / 1000000); }
uint64_t uptime_ms(void) { return uptime_us() / 1000; }

/* ------------------------------------------------------------------ */
/* page allocator behind mmap()                                        */
/* ------------------------------------------------------------------ */
enum { PAGE = 4096, MAX_RANGES = 4096 };
static Range g_free[MAX_RANGES]; /* sorted by start, never adjacent */
static int g_nfree;

static void range_free(uint64_t start, uint64_t len) {
    int i = 0;
    while (i < g_nfree && g_free[i].start < start) i++;
    if (i > 0 && g_free[i - 1].start + g_free[i - 1].len == start) {
        g_free[i - 1].len += len;
        if (i < g_nfree && g_free[i - 1].start + g_free[i - 1].len == g_free[i].start) {
            g_free[i - 1].len += g_free[i].len;
            memmove(&g_free[i], &g_free[i + 1], (size_t)(g_nfree - i - 1) * sizeof(Range));
            g_nfree--;
        }
    } else if (i < g_nfree && start + len == g_free[i].start) {
        g_free[i].start = start;
        g_free[i].len += len;
    } else {
        if (g_nfree == MAX_RANGES) return; /* leak rather than fail */
        memmove(&g_free[i + 1], &g_free[i], (size_t)(g_nfree - i) * sizeof(Range));
        g_free[i].start = start;
        g_free[i].len = len;
        g_nfree++;
    }
    g_mem_free_pages += len / PAGE;
}

static void *page_alloc(uint64_t len) {
    len = (len + PAGE - 1) & ~(uint64_t)(PAGE - 1);
    for (int i = 0; i < g_nfree; i++) {
        if (g_free[i].len >= len) {
            uint64_t a = g_free[i].start;
            g_free[i].start += len;
            g_free[i].len -= len;
            if (g_free[i].len == 0) {
                memmove(&g_free[i], &g_free[i + 1], (size_t)(g_nfree - i - 1) * sizeof(Range));
                g_nfree--;
            }
            g_mem_free_pages -= len / PAGE;
            return (void *)(uintptr_t)a;
        }
    }
    return NULL;
}

/* memory handed to the Sprint kernel for user pages: the C side (libc heap for the kernel VM) keeps the rest */
Range g_user_mem[64];
int g_nuser_mem;

static void carve_user_memory(void) {
    uint64_t keep = g_mem_total / 2 < (96ull << 20) ? g_mem_total / 2 : (96ull << 20); /* bytes the C heap keeps */
    uint64_t have = 0;
    for (int i = 0; i < g_nfree; i++) have += g_free[i].len;
    uint64_t take = have > keep ? have - keep : 0;
    for (int i = g_nfree - 1; i >= 0 && take > 0; i--) {
        uint64_t n = g_free[i].len < take ? g_free[i].len : take;
        uint64_t start = g_free[i].start + g_free[i].len - n;
        if (g_nuser_mem < 64) {
            g_user_mem[g_nuser_mem].start = start;
            g_user_mem[g_nuser_mem].len = n;
            g_nuser_mem++;
        }
        g_free[i].len -= n;
        g_mem_free_pages -= n / PAGE;
        take -= n;
        if (g_free[i].len == 0) {
            memmove(&g_free[i], &g_free[i + 1], (size_t)(g_nfree - i - 1) * sizeof(Range));
            g_nfree--;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Linux syscall emulation                                             */
/* ------------------------------------------------------------------ */
enum {
    SYS_read = 0, SYS_write = 1, SYS_open = 2, SYS_close = 3, SYS_stat = 4, SYS_fstat = 5, SYS_lstat = 6, SYS_access = 21,
    SYS_readlink = 89, SYS_openat = 257, SYS_newfstatat = 262, SYS_mmap = 9, SYS_mprotect = 10, SYS_munmap = 11, SYS_brk = 12,
    SYS_rt_sigaction = 13, SYS_rt_sigprocmask = 14, SYS_ioctl = 16, SYS_writev = 20, SYS_sched_yield = 24,
    SYS_mremap = 25, SYS_madvise = 28, SYS_nanosleep = 35, SYS_getpid = 39, SYS_exit = 60, SYS_fcntl = 72,
    SYS_arch_prctl = 158, SYS_gettid = 186, SYS_futex = 202, SYS_set_tid_address = 218, SYS_clock_gettime = 228,
    SYS_exit_group = 231, SYS_tgkill = 234, SYS_getrandom = 318
};
struct iovec_k { void *base; size_t len; };

static uint64_t g_rng = 0x853c49e6748fea9bull;
static uint64_t rng_next(void) {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
}

long ksyscall(long n, long a1, long a2, long a3, long a4, long a5, long a6);
long ksyscall(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a4;
    (void)a5;
    (void)a6;
    switch (n) {
    case SYS_write:
        if (a1 == 1 || a1 == 2) {
            serial_write((const char *)a2, (size_t)a3);
            return a3;
        }
        return -EBADF;
    case SYS_writev: {
        const struct iovec_k *v = (const struct iovec_k *)a2;
        long total = 0;
        if (a1 != 1 && a1 != 2) return -EBADF;
        for (long i = 0; i < a3; i++) {
            serial_write(v[i].base, v[i].len);
            total += (long)v[i].len;
        }
        return total;
    }
    case SYS_read: return 0;
    case SYS_close: return 0;
    case SYS_mmap: {
        /* anonymous memory only */
        if (!(a4 & 0x20)) return -ENODEV;
        void *p = page_alloc((uint64_t)a2);
        if (!p) return -ENOMEM;
        memset(p, 0, (size_t)a2);
        return (long)(uintptr_t)p;
    }
    case SYS_munmap:
        range_free((uint64_t)a1, ((uint64_t)a2 + PAGE - 1) & ~(uint64_t)(PAGE - 1));
        return 0;
    case SYS_mremap: {
        void *p = page_alloc((uint64_t)a3);
        if (!p) return -ENOMEM;
        uint64_t keep = (uint64_t)a2 < (uint64_t)a3 ? (uint64_t)a2 : (uint64_t)a3;
        memcpy(p, (void *)a1, keep);
        if ((uint64_t)a3 > keep) memset((char *)p + keep, 0, (size_t)((uint64_t)a3 - keep));
        range_free((uint64_t)a1, ((uint64_t)a2 + PAGE - 1) & ~(uint64_t)(PAGE - 1));
        return (long)(uintptr_t)p;
    }
    case SYS_mprotect:
    case SYS_madvise:
    case SYS_rt_sigaction:
    case SYS_rt_sigprocmask:
    case SYS_sched_yield:
    case SYS_futex:
    case SYS_tgkill: return 0;
    case SYS_brk: return 0; /* no brk heap: musl falls back to mmap */
    case SYS_ioctl: return -ENOTTY;
    case SYS_fcntl: return -ENOSYS;
    case SYS_open:
    case SYS_openat:
    case SYS_stat:
    case SYS_lstat:
    case SYS_newfstatat:
    case SYS_readlink:
    case SYS_access: return -ENOENT; /* there is no host file system: Sprint's own vfs is the file system */
    case SYS_fstat: return -EBADF;
    case SYS_getpid:
    case SYS_gettid:
    case SYS_set_tid_address: return 1;
    case SYS_arch_prctl:
        if (a1 == 0x1002) { /* ARCH_SET_FS */
            wrmsr(0xC0000100, (uint64_t)a2);
            return 0;
        }
        return -EINVAL;
    case SYS_clock_gettime: {
        uint64_t us = uptime_us();
        long *ts = (long *)a2;
        ts[0] = (long)(us / 1000000);
        ts[1] = (long)(us % 1000000) * 1000;
        return 0;
    }
    case SYS_nanosleep: {
        const long *ts = (const long *)a1;
        uint64_t us = (uint64_t)ts[0] * 1000000 + (uint64_t)ts[1] / 1000;
        uint64_t end = uptime_us() + us;
        while (uptime_us() < end) __asm__ volatile("pause");
        return 0;
    }
    case SYS_getrandom: {
        unsigned char *p = (unsigned char *)a1;
        for (long i = 0; i < a2; i++) p[i] = (unsigned char)(rng_next() >> 24);
        return a2;
    }
    case SYS_exit:
    case SYS_exit_group:
        serial_puts("\n[kernel] program exited; powering off\n");
        power_off();
    default: {
        char b[64];
        int k = snprintf(b, sizeof b, "[kernel] unsupported syscall %ld\n", n);
        serial_write(b, (size_t)k);
        return -ENOSYS;
    }
    }
}

/* ------------------------------------------------------------------ */
/* boot information (Multiboot2)                                       */
/* ------------------------------------------------------------------ */
typedef struct __attribute__((packed)) MbTag { uint32_t type, size; } MbTag;

uint64_t g_rsdp;
static void parse_boot_info(uint64_t mbi) {
    uint64_t heap_lo = ((uint64_t)(uintptr_t)_end + PAGE - 1) & ~(uint64_t)(PAGE - 1);
    uint32_t total = *(uint32_t *)(uintptr_t)mbi;
    uint64_t mbi_end = mbi + total;
    if (mbi >= heap_lo && mbi < heap_lo + (64u << 20)) heap_lo = (mbi_end + PAGE - 1) & ~(uint64_t)(PAGE - 1);
    const MbTag *t = (const MbTag *)(uintptr_t)(mbi + 8);
    while (t->type != 0) {
        const uint8_t *p = (const uint8_t *)t;
        if (t->type == 1) g_cmdline = (const char *)(p + 8);
        if (t->type == 14 || t->type == 15) g_rsdp = (uint64_t)(uintptr_t)(p + 8);
        if (t->type == 8) {
            g_fb.addr = *(const uint64_t *)(p + 8);
            g_fb.pitch = *(const uint32_t *)(p + 16);
            g_fb.width = *(const uint32_t *)(p + 20);
            g_fb.height = *(const uint32_t *)(p + 24);
            g_fb.bpp = p[28];
            g_fb.present = p[29] == 1 && g_fb.bpp == 32;
        }
        if (t->type == 6) {
            uint32_t esz = *(const uint32_t *)(p + 8);
            for (const uint8_t *e = p + 16; e < p + t->size; e += esz) {
                uint64_t base = *(const uint64_t *)e, len = *(const uint64_t *)(e + 8);
                uint32_t ty = *(const uint32_t *)(e + 16);
                if (ty != 1) continue;
                uint64_t lo = base < heap_lo ? heap_lo : base, hi = base + len;
                if (hi > (4ull << 30)) hi = 4ull << 30; /* only the first 4 GiB is mapped */
                if (hi <= lo) continue;
                lo = (lo + PAGE - 1) & ~(uint64_t)(PAGE - 1);
                hi &= ~(uint64_t)(PAGE - 1);
                if (hi > lo) {
                    range_free(lo, hi - lo);
                    g_mem_total += hi - lo;
                }
            }
        }
        t = (const MbTag *)((const uint8_t *)t + ((t->size + 7u) & ~7u));
    }
}

/* ------------------------------------------------------------------ */
/* running Sprint                                                      */
/* ------------------------------------------------------------------ */
static SpStatus os_loader(void *ud, const char *name, const char **src, size_t *len, const char **path) {
    (void)ud;
    const BundledMod *b = bundled_find(name, strlen(name));
    if (!b) return SP_E_IMPORT;
    *src = b->src;
    *len = b->len;
    *path = b->name;
    return SP_OK;
}

static size_t os_write(void *ud, int stream, const char *data, size_t len) {
    (void)ud;
    (void)stream;
    serial_write(data, len);
    return len;
}

static int os_main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    cpu_capture_fs();
    SpConfig cfg;
    sp_config_init(&cfg);
    cfg.capabilities = SP_CAP_STDIO_WRITE | SP_CAP_CLOCK;
    cfg.deterministic = 0;
    cfg.limits.max_heap_bytes = (uint64_t)g_mem_total / 2;
    cfg.write = os_write;
    cfg.loader = os_loader;
    SpVM *vm;
    if (sp_vm_new(&cfg, &vm) != SP_OK) kpanic("cannot create the Sprint VM");
    if (hw_register(vm) != SP_OK) kpanic("cannot register the hw module");
    SpProgram *prog;
    const char *entry = "osmain";
    SpStatus st = sp_compile(vm, entry, &prog);
    if (st != SP_OK) {
        for (size_t i = 0; i < sp_diagnostic_count(vm); i++) {
            const SpDiagnostic *d = sp_diagnostic(vm, i);
            char b[512];
            int k = snprintf(b, sizeof b, "%s:%u: %s: %s\n", d->file, d->line, d->kind, d->message);
            serial_write(b, (size_t)k);
        }
        kpanic("cannot compile the OS");
    }
    st = sp_run(vm, prog, 0, NULL);
    {
        char b[96];
        int k = snprintf(b, sizeof b, "\n[kernel] osmain ended with status %d\n", (int)st);
        serial_write(b, (size_t)k);
        if (st != SP_OK) {
            SpValue e = sp_last_error(vm);
            if (e.type == SP_T_ERROR) {
                SpValue m;
                if (sp_get_member(vm, e, "message", &m) == SP_OK && m.type == SP_T_STRING) {
                    size_t n;
                    const char *s = sp_string_data(m, &n);
                    serial_write(s, n);
                    serial_puts("\n");
                }
            }
        }
    }
    if (st != SP_OK) power_off();
    smp_run_bsp();
}

void kmain(uint64_t mbi);
void kmain(uint64_t mbi) {
    serial_init();
    serial_puts("[kernel] Sprint OS booting\n");
    cpu_init(0);
    clock_init();
    parse_boot_info(mbi);
    carve_user_memory();
    {
        char b[128];
        int k = snprintf(b, sizeof b, "[kernel] %lu MiB free, tsc %lu MHz, fb %ux%u\n", (unsigned long)(g_mem_total >> 20),
                         (unsigned long)(g_tsc_hz / 1000000), g_fb.width, g_fb.height);
        serial_write(b, (size_t)k);
    }
    /* the process image musl expects: argc, argv, envp, auxv */
    static char name[] = "sprintos";
    static uint64_t stk[16];
    int i = 0;
    stk[i++] = 1;
    stk[i++] = (uint64_t)(uintptr_t)name;
    stk[i++] = 0; /* argv end */
    stk[i++] = 0; /* envp end */
    stk[i++] = 6; /* AT_PAGESZ */
    stk[i++] = PAGE;
    stk[i++] = 25; /* AT_RANDOM */
    static uint64_t rnd[2] = {0x9e3779b97f4a7c15ull, 0xdeadbeefcafef00dull};
    stk[i++] = (uint64_t)(uintptr_t)rnd;
    stk[i++] = 0;
    stk[i++] = 0;
    __libc_start_main(os_main, 1, (char **)&stk[1], 0, 0, 0);
    kpanic("libc returned");
}
