/* State that every processor's kernel shares. Each CPU runs its own Sprint VM (its own scheduler, process table and run queue - see os/sprint/sched.sp); what
 * they have in common lives here, in C, behind small locks: the physical page allocator, the process-id table, the service names, shared-memory segments, the
 * owners of device interrupts, the load of each CPU, and the mailboxes CPUs use to send each other messages (with an IPI to wake the receiver).
 * Sprint code reaches it through the module `k`. */
#define SP_EMBED_INTERNAL 1
#include "sp.h"
#include "sprint.h"
#include "kernel.h"
#include "cpu.h"
#include "smp.h"
#include <stdlib.h>
#include <string.h>

typedef volatile int Spin;
static inline void spin_lock(Spin *l) {
    while (__atomic_exchange_n(l, 1, __ATOMIC_ACQUIRE))
        while (__atomic_load_n(l, __ATOMIC_RELAXED)) __builtin_ia32_pause();
}
static inline void spin_unlock(Spin *l) { __atomic_store_n(l, 0, __ATOMIC_RELEASE); }

/* ---- physical pages for user processes (a bitmap, 1 = free) ---- */
enum { PG = 4096, PG_WORDS = 1u << 14 }; /* up to 1 Mi pages = 4 GiB */
static uint64_t pg_bits[PG_WORDS];
static uint64_t pg_base, pg_span;
static Spin pg_lock;
static uint64_t pg_cursor, pg_free_n, pg_total_n;

void upage_init(void) {
    uint64_t lo = ~0ull, hi = 0;
    for (int i = 0; i < g_nuser_mem; i++) {
        if (g_user_mem[i].start < lo) lo = g_user_mem[i].start;
        if (g_user_mem[i].start + g_user_mem[i].len > hi) hi = g_user_mem[i].start + g_user_mem[i].len;
    }
    if (lo >= hi) return;
    pg_base = lo & ~(uint64_t)(PG - 1);
    pg_span = (hi - pg_base) / PG;
    if (pg_span > (uint64_t)PG_WORDS * 64) pg_span = (uint64_t)PG_WORDS * 64;
    for (int i = 0; i < g_nuser_mem; i++) {
        uint64_t a = (g_user_mem[i].start + PG - 1) & ~(uint64_t)(PG - 1);
        for (; a + PG <= g_user_mem[i].start + g_user_mem[i].len; a += PG) {
            uint64_t k = (a - pg_base) / PG;
            if (k < pg_span) {
                pg_bits[k / 64] |= 1ull << (k % 64);
                pg_free_n++;
                pg_total_n++;
            }
        }
    }
}

/* one zeroed page, or 0 */
uint64_t upage_alloc(void) {
    uint64_t out = 0;
    spin_lock(&pg_lock);
    uint64_t words = (pg_span + 63) / 64;
    for (uint64_t n = 0; n < words; n++) {
        uint64_t w = (pg_cursor + n) % words;
        if (pg_bits[w]) {
            int b = __builtin_ctzll(pg_bits[w]);
            pg_bits[w] &= ~(1ull << b);
            pg_cursor = w;
            pg_free_n--;
            out = pg_base + (w * 64 + (uint64_t)b) * PG;
            break;
        }
    }
    spin_unlock(&pg_lock);
    if (out) memset((void *)(uintptr_t)out, 0, PG);
    return out;
}

void upage_free(uint64_t a) {
    if (a < pg_base) return;
    uint64_t k = (a - pg_base) / PG;
    if (k >= pg_span) return;
    spin_lock(&pg_lock);
    if (!(pg_bits[k / 64] & (1ull << (k % 64)))) {
        pg_bits[k / 64] |= 1ull << (k % 64);
        pg_free_n++;
    }
    spin_unlock(&pg_lock);
}

/* n physically contiguous zeroed pages, or 0 */
uint64_t upage_alloc_contig(uint64_t n) {
    uint64_t out = 0;
    if (n == 0) return 0;
    spin_lock(&pg_lock);
    uint64_t run = 0;
    for (uint64_t k = 0; k < pg_span; k++) {
        if (pg_bits[k / 64] & (1ull << (k % 64))) {
            run++;
            if (run == n) {
                uint64_t first = k + 1 - n;
                for (uint64_t j = first; j <= k; j++) pg_bits[j / 64] &= ~(1ull << (j % 64));
                pg_free_n -= n;
                out = pg_base + first * PG;
                break;
            }
        } else {
            run = 0;
        }
    }
    spin_unlock(&pg_lock);
    if (out) memset((void *)(uintptr_t)out, 0, (size_t)(n * PG));
    return out;
}

/* ---- process ids and which CPU owns each ---- */
enum { MAX_PID = 1 << 16 };
static uint8_t pid_cpu[MAX_PID];
static volatile uint32_t pid_next = 1;
static volatile int g_nproc;
static volatile int g_load[MAX_CPUS], g_ready[MAX_CPUS];

/* ---- service names ---- */
enum { MAX_NAMES = 64, NAME_LEN = 32 };
static struct { char name[NAME_LEN + 1]; int pid; } names[MAX_NAMES];
static Spin names_lock;

/* ---- shared-memory segments ---- */
enum { MAX_SEGS = 1024 };
static struct { uint64_t *pages; uint32_t n; int refs; } segs[MAX_SEGS];
static Spin segs_lock;

/* ---- device interrupt owners ---- */
static volatile int g_irq_owner[24];

/* ---- mailboxes: CPU to CPU messages ---- */
enum { MB_SLOTS = 64, MB_DATA = 4200 };
typedef struct {
    int64_t kind, a, b, c;
    uint32_t len;
    char data[MB_DATA];
} MbMsg;
typedef struct {
    Spin lock;
    uint32_t head, tail;
    MbMsg slot[MB_SLOTS];
} Mbox;
static Mbox g_mbox[MAX_CPUS];
static Spin g_icr_lock;
static volatile uint32_t g_apic_of[MAX_CPUS];

void smp_note_apic(int cpu, uint32_t apic_id) { g_apic_of[cpu] = apic_id; }

void smp_send_ipi(int cpu) {
    volatile uint32_t *lapic = (volatile uint32_t *)(uintptr_t)0xFEE00000u;
    spin_lock(&g_icr_lock);
    lapic[0x310 / 4] = g_apic_of[cpu] << 24;
    lapic[0x300 / 4] = 0x4000u | 0x21u; /* fixed delivery, assert, vector 0x21 (the scheduler kick) */
    for (int i = 0; i < 100000 && (lapic[0x300 / 4] & 0x1000); i++) __builtin_ia32_pause();
    spin_unlock(&g_icr_lock);
}

/* ---- the module `k` ---- */
static SpStatus need_int(SpVM *vm, SpValue v, int64_t *out) {
    if (v.type != SP_T_INT) return sp_throw(vm, "TypeError", "k: expected an int, got %s", sp_type_name(v));
    *out = v.as.i;
    return SP_OK;
}
#define ARG(i, var)                                       \
    int64_t var = 0;                                      \
    do {                                                  \
        SpStatus s_ = need_int(vm, argv[i], &var);        \
        if (s_ != SP_OK) return s_;                       \
    } while (0)

static SpStatus k_page_alloc(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    *ret = sp_int((int64_t)upage_alloc());
    return SP_OK;
}
static SpStatus k_page_free(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, a);
    upage_free((uint64_t)a);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus k_page_alloc_contig(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, n);
    *ret = sp_int((int64_t)upage_alloc_contig((uint64_t)n));
    return SP_OK;
}
static SpStatus k_pages_free(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    *ret = sp_int((int64_t)__atomic_load_n(&pg_free_n, __ATOMIC_RELAXED));
    return SP_OK;
}
static SpStatus k_pages_total(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    *ret = sp_int((int64_t)pg_total_n);
    return SP_OK;
}
static SpStatus k_pid_new(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    uint32_t p = __atomic_fetch_add(&pid_next, 1, __ATOMIC_RELAXED);
    if (p >= MAX_PID) return sp_throw(vm, "OSError", "k.pid_new: out of process ids");
    __atomic_store_n(&pid_cpu[p], (uint8_t)(cpu + 1), __ATOMIC_RELEASE);
    __atomic_fetch_add(&g_nproc, 1, __ATOMIC_RELAXED);
    *ret = sp_int(p);
    return SP_OK;
}
static SpStatus k_pid_cpu(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, p);
    int v = (p > 0 && p < MAX_PID) ? __atomic_load_n(&pid_cpu[p], __ATOMIC_ACQUIRE) : 0;
    *ret = sp_int(v - 1); /* -1: no such (live) process */
    return SP_OK;
}
static SpStatus k_pid_gone(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, p);
    if (p > 0 && p < MAX_PID) __atomic_store_n(&pid_cpu[p], 0, __ATOMIC_RELEASE);
    *ret = sp_int(__atomic_sub_fetch(&g_nproc, 1, __ATOMIC_ACQ_REL)); /* the number of live processes left */
    return SP_OK;
}
static SpStatus k_nproc(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    *ret = sp_int(__atomic_load_n(&g_nproc, __ATOMIC_ACQUIRE));
    return SP_OK;
}
static SpStatus k_load_set(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    ARG(1, n);
    if (cpu >= 0 && cpu < MAX_CPUS) g_load[cpu] = (int)n;
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus k_load_get(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    *ret = sp_int(cpu >= 0 && cpu < MAX_CPUS ? g_load[cpu] : 1 << 20);
    return SP_OK;
}
static SpStatus k_ready_set(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    if (cpu >= 0 && cpu < MAX_CPUS) __atomic_store_n(&g_ready[cpu], 1, __ATOMIC_RELEASE);
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus k_ready(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    *ret = sp_bool(cpu >= 0 && cpu < MAX_CPUS && __atomic_load_n(&g_ready[cpu], __ATOMIC_ACQUIRE));
    return SP_OK;
}
static SpStatus k_name_set(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(1, pid);
    if (argv[0].type != SP_T_STRING) return sp_throw(vm, "TypeError", "k.name_set: expected a name");
    size_t n;
    const char *s = sp_string_data(argv[0], &n);
    int64_t r = -22;
    if (n > 0 && n <= NAME_LEN) {
        spin_lock(&names_lock);
        int free_i = -1, hit = -1;
        for (int i = 0; i < MAX_NAMES; i++) {
            if (names[i].pid == 0) { if (free_i < 0) free_i = i; continue; }
            if (strlen(names[i].name) == n && memcmp(names[i].name, s, n) == 0) hit = i;
        }
        if (hit >= 0) {
            int old = names[hit].pid;
            if (old != pid && pid_cpu[old] != 0) r = -17; /* held by a live process */
            else { names[hit].pid = (int)pid; r = 0; }
        } else if (free_i >= 0) {
            memcpy(names[free_i].name, s, n);
            names[free_i].name[n] = 0;
            names[free_i].pid = (int)pid;
            r = 0;
        } else {
            r = -12;
        }
        spin_unlock(&names_lock);
    }
    *ret = sp_int(r);
    return SP_OK;
}
static SpStatus k_name_get(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    if (argv[0].type != SP_T_STRING) return sp_throw(vm, "TypeError", "k.name_get: expected a name");
    size_t n;
    const char *s = sp_string_data(argv[0], &n);
    int64_t r = -2;
    spin_lock(&names_lock);
    for (int i = 0; i < MAX_NAMES; i++)
        if (names[i].pid != 0 && strlen(names[i].name) == n && memcmp(names[i].name, s, n) == 0 && pid_cpu[names[i].pid] != 0) r = names[i].pid;
    spin_unlock(&names_lock);
    *ret = sp_int(r);
    return SP_OK;
}
static SpStatus k_shm_create(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, npages);
    if (npages <= 0 || npages > 4096) { *ret = sp_int(-22); return SP_OK; }
    uint64_t *pages = (uint64_t *)malloc((size_t)npages * 8);
    if (!pages) { *ret = sp_int(-12); return SP_OK; }
    for (int64_t i = 0; i < npages; i++) {
        pages[i] = upage_alloc();
        if (!pages[i]) {
            for (int64_t j = 0; j < i; j++) upage_free(pages[j]);
            free(pages);
            *ret = sp_int(-12);
            return SP_OK;
        }
    }
    int64_t id = -12;
    spin_lock(&segs_lock);
    for (int i = 1; i < MAX_SEGS; i++)
        if (!segs[i].pages) { segs[i].pages = pages; segs[i].n = (uint32_t)npages; segs[i].refs = 0; id = i; break; }
    spin_unlock(&segs_lock);
    if (id < 0) {
        for (int64_t i = 0; i < npages; i++) upage_free(pages[i]);
        free(pages);
    }
    *ret = sp_int(id);
    return SP_OK;
}
/* shm_adopt(first, n): pages the caller already owns (contiguous) become a segment */
static SpStatus k_shm_adopt(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, first);
    ARG(1, n);
    uint64_t *pages = (uint64_t *)malloc((size_t)n * 8);
    if (!pages) { *ret = sp_int(-12); return SP_OK; }
    for (int64_t i = 0; i < n; i++) pages[i] = (uint64_t)first + (uint64_t)i * PG;
    int64_t id = -12;
    spin_lock(&segs_lock);
    for (int i = 1; i < MAX_SEGS; i++)
        if (!segs[i].pages) { segs[i].pages = pages; segs[i].n = (uint32_t)n; segs[i].refs = 0; id = i; break; }
    spin_unlock(&segs_lock);
    if (id < 0) free(pages);
    *ret = sp_int(id);
    return SP_OK;
}
static SpStatus k_shm_n(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, id);
    int64_t n = 0;
    spin_lock(&segs_lock);
    if (id > 0 && id < MAX_SEGS && segs[id].pages) n = segs[id].n;
    spin_unlock(&segs_lock);
    *ret = sp_int(n);
    return SP_OK;
}
static SpStatus k_shm_page(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, id);
    ARG(1, i);
    int64_t a = 0;
    spin_lock(&segs_lock);
    if (id > 0 && id < MAX_SEGS && segs[id].pages && i >= 0 && i < segs[id].n) a = (int64_t)segs[id].pages[i];
    spin_unlock(&segs_lock);
    *ret = sp_int(a);
    return SP_OK;
}
/* shm_ref(id, delta): change the number of mappings; at zero the pages go back to the allocator. Returns the new count (-1 for an unknown segment). */
static SpStatus k_shm_ref(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, id);
    ARG(1, delta);
    int64_t r = -1;
    uint64_t *drop = NULL;
    uint32_t dn = 0;
    spin_lock(&segs_lock);
    if (id > 0 && id < MAX_SEGS && segs[id].pages) {
        segs[id].refs += (int)delta;
        r = segs[id].refs;
        if (r <= 0 && delta < 0) {
            drop = segs[id].pages;
            dn = segs[id].n;
            segs[id].pages = NULL;
        }
    }
    spin_unlock(&segs_lock);
    if (drop) {
        for (uint32_t i = 0; i < dn; i++) upage_free(drop[i]);
        free(drop);
    }
    *ret = sp_int(r);
    return SP_OK;
}
static SpStatus k_irq_owner_set(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, gsi);
    ARG(1, pid);
    int64_t r = -22;
    if (gsi >= 0 && gsi < 24) {
        int old = g_irq_owner[gsi];
        if (old != 0 && old != pid && pid_cpu[old] != 0) r = -16;
        else { g_irq_owner[gsi] = (int)pid; r = 0; }
    }
    *ret = sp_int(r);
    return SP_OK;
}
static SpStatus k_irq_owner(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, gsi);
    int o = (gsi >= 0 && gsi < 24) ? g_irq_owner[gsi] : 0;
    *ret = sp_int(o != 0 && pid_cpu[o] != 0 ? o : 0);
    return SP_OK;
}
/* mbox_send(cpu, kind, a, b, c, text) -> true when queued (the CPU is woken with an IPI) */
static SpStatus k_mbox_send(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    ARG(1, kind);
    ARG(2, a);
    ARG(3, b);
    ARG(4, c);
    if (cpu < 0 || cpu >= MAX_CPUS) return sp_throw(vm, "ValueError", "k.mbox_send: bad cpu");
    size_t n = 0;
    const char *s = "";
    if (argv[5].type == SP_T_STRING) s = sp_string_data(argv[5], &n);
    if (n > MB_DATA) { *ret = sp_bool(0); return SP_OK; }
    Mbox *m = &g_mbox[cpu];
    int ok = 0;
    spin_lock(&m->lock);
    if (m->head - m->tail < MB_SLOTS) {
        MbMsg *q = &m->slot[m->head % MB_SLOTS];
        q->kind = kind; q->a = a; q->b = b; q->c = c;
        q->len = (uint32_t)n;
        memcpy(q->data, s, n);
        m->head++;
        ok = 1;
    }
    spin_unlock(&m->lock);
    if (ok) smp_send_ipi((int)cpu);
    *ret = sp_bool(ok);
    return SP_OK;
}
/* mbox_recv() -> [kind, a, b, c, text] or nil: the oldest message for this CPU */
static SpStatus k_mbox_recv(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc; (void)argv;
    uint64_t id;
    __asm__ volatile("movq %%gs:%c1, %0" : "=r"(id) : "i"(PC_ID));
    Mbox *m = &g_mbox[id];
    MbMsg tmp;
    int got = 0;
    spin_lock(&m->lock);
    if (m->tail != m->head) {
        tmp = m->slot[m->tail % MB_SLOTS];
        m->tail++;
        got = 1;
    }
    spin_unlock(&m->lock);
    if (!got) { *ret = sp_nil(); return SP_OK; }
    SpStatus st = sp_new_array(vm, 5, ret);
    if (st != SP_OK) return st;
    (void)sp_array_push(vm, *ret, sp_int(tmp.kind));
    (void)sp_array_push(vm, *ret, sp_int(tmp.a));
    (void)sp_array_push(vm, *ret, sp_int(tmp.b));
    (void)sp_array_push(vm, *ret, sp_int(tmp.c));
    SpValue s;
    st = sp_new_string(vm, tmp.data, tmp.len, &s);
    if (st != SP_OK) return st;
    (void)sp_array_push(vm, *ret, s);
    return SP_OK;
}
static SpStatus k_mbox_pending(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)vm; (void)argc; (void)argv;
    uint64_t id;
    __asm__ volatile("movq %%gs:%c1, %0" : "=r"(id) : "i"(PC_ID));
    *ret = sp_bool(__atomic_load_n(&g_mbox[id].head, __ATOMIC_ACQUIRE) != __atomic_load_n(&g_mbox[id].tail, __ATOMIC_ACQUIRE));
    return SP_OK;
}
/* flag_set(i) -> the previous value (an atomic test-and-set: the first caller sees 0); flag_get(i) */
static volatile int g_flags[16];
static SpStatus k_flag_set(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, i);
    *ret = sp_int(i >= 0 && i < 16 ? __atomic_exchange_n(&g_flags[i], 1, __ATOMIC_ACQ_REL) : 1);
    return SP_OK;
}
static SpStatus k_flag_get(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, i);
    *ret = sp_int(i >= 0 && i < 16 ? __atomic_load_n(&g_flags[i], __ATOMIC_ACQUIRE) : 0);
    return SP_OK;
}
static SpStatus k_load_add(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    ARG(1, d);
    *ret = sp_int(cpu >= 0 && cpu < MAX_CPUS ? __atomic_add_fetch(&g_load[cpu], (int)d, __ATOMIC_ACQ_REL) : 0);
    return SP_OK;
}
/* stat_set(cpu, i, v) / stat_get(cpu, i): per-CPU counters the scheduler publishes (0 = processes run, 1 = timer preemptions) */
static volatile int64_t g_stat[MAX_CPUS][4];
static SpStatus k_stat_set(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    ARG(1, i);
    ARG(2, v);
    if (cpu >= 0 && cpu < MAX_CPUS && i >= 0 && i < 4) g_stat[cpu][i] = v;
    *ret = sp_nil();
    return SP_OK;
}
static SpStatus k_stat_get(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    ARG(1, i);
    *ret = sp_int(cpu >= 0 && cpu < MAX_CPUS && i >= 0 && i < 4 ? g_stat[cpu][i] : 0);
    return SP_OK;
}
static SpStatus k_ipi(SpVM *vm, int argc, const SpValue *argv, SpValue *ret) {
    (void)argc;
    ARG(0, cpu);
    if (cpu >= 0 && cpu < MAX_CPUS) smp_send_ipi((int)cpu);
    *ret = sp_nil();
    return SP_OK;
}

static const SpNativeDesc k_fns[] = {
    {"page_alloc", 0, 0, 0, 0, k_page_alloc}, {"page_free", 1, 1, 0, 0, k_page_free}, {"page_alloc_contig", 1, 1, 0, 0, k_page_alloc_contig},
    {"pages_free", 0, 0, 0, 0, k_pages_free}, {"pages_total", 0, 0, 0, 0, k_pages_total},
    {"pid_new", 1, 1, 0, 0, k_pid_new}, {"pid_cpu", 1, 1, 0, 0, k_pid_cpu}, {"pid_gone", 1, 1, 0, 0, k_pid_gone}, {"nproc", 0, 0, 0, 0, k_nproc},
    {"load_set", 2, 2, 0, 0, k_load_set}, {"load_get", 1, 1, 0, 0, k_load_get}, {"ready_set", 1, 1, 0, 0, k_ready_set}, {"ready", 1, 1, 0, 0, k_ready},
    {"name_set", 2, 2, 0, 0, k_name_set}, {"name_get", 1, 1, 0, 0, k_name_get},
    {"shm_create", 1, 1, 0, 0, k_shm_create}, {"shm_adopt", 2, 2, 0, 0, k_shm_adopt}, {"shm_n", 1, 1, 0, 0, k_shm_n}, {"shm_page", 2, 2, 0, 0, k_shm_page},
    {"shm_ref", 2, 2, 0, 0, k_shm_ref},
    {"irq_owner_set", 2, 2, 0, 0, k_irq_owner_set}, {"irq_owner", 1, 1, 0, 0, k_irq_owner},
    {"mbox_send", 6, 6, 0, 0, k_mbox_send}, {"mbox_recv", 0, 0, 0, SP_NATIVE_ALLOCATES, k_mbox_recv}, {"mbox_pending", 0, 0, 0, 0, k_mbox_pending},
    {"ipi", 1, 1, 0, 0, k_ipi}, {"flag_set", 1, 1, 0, 0, k_flag_set}, {"flag_get", 1, 1, 0, 0, k_flag_get}, {"load_add", 2, 2, 0, 0, k_load_add},
    {"stat_set", 3, 3, 0, 0, k_stat_set}, {"stat_get", 2, 2, 0, 0, k_stat_get},
};

int shared_register(SpVM *vm) { return (int)sp_register_module(vm, "k", k_fns, sizeof k_fns / sizeof k_fns[0]); }
