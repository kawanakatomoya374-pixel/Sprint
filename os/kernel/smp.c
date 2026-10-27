/* Symmetric multiprocessing: starting application processors and running the scheduler loop on every CPU.
 * All policy (who runs where, for how long) is Sprint code in os/sprint/sched.sp. The single Sprint VM is entered
 * by one CPU at a time (a big kernel lock); user code runs on all CPUs in parallel outside the lock. */
#define SP_EMBED_INTERNAL 1
#include "sp.h"
#include "sprint.h"
#include "kernel.h"
#include "cpu.h"
#include "smp.h"
#include <string.h>

extern const uint8_t ap_tramp_start[], ap_tramp_end[], ap_data[];
extern char pml4[];

static volatile int g_lock;
static SpVM *g_vm;
static SpRef *g_pick, *g_trap;
static volatile int g_go;
static volatile int g_ap_up[MAX_CPUS];
static uint32_t g_timer_count;
static uint8_t g_ap_stack[MAX_CPUS][AP_STACK] __attribute__((aligned(16)));

#define LAPIC ((volatile uint32_t *)(uintptr_t)0xFEE00000u)

static void lock(void) {
    while (__atomic_exchange_n(&g_lock, 1, __ATOMIC_ACQUIRE))
        while (__atomic_load_n(&g_lock, __ATOMIC_RELAXED)) __builtin_ia32_pause();
}
static void unlock(void) { __atomic_store_n(&g_lock, 0, __ATOMIC_RELEASE); }

void smp_set_hooks(SpVM *vm, SpRef *pick, SpRef *trap) {
    g_vm = vm;
    g_pick = pick;
    g_trap = trap;
}
void smp_set_timer(uint32_t count) { g_timer_count = count; }

static int64_t call_hook(SpRef *r, int cpu, int64_t v, int argc) {
    SpValue args[2] = {sp_int(cpu), sp_int(v)};
    SpValue ret = sp_nil();
    SpStatus st = sp_call(g_vm, sp_ref_get(r), argc, args, &ret);
    if (st != SP_OK) {
        serial_puts("\n[kernel] scheduler hook failed\n");
        SpValue e = sp_last_error(g_vm);
        SpValue m;
        if (e.type == SP_T_ERROR && sp_get_member(g_vm, e, "message", &m) == SP_OK && m.type == SP_T_STRING) {
            size_t n;
            const char *s = sp_string_data(m, &n);
            serial_write(s, n);
            serial_puts("\n");
        }
        power_off();
    }
    return ret.type == SP_T_INT ? ret.as.i : 0;
}

/* the scheduler loop of one CPU: ask Sprint what to run, run it in ring 3, report the trap back */
static void smp_loop(int id) __attribute__((noreturn));
static void smp_loop(int id) {
    for (;;) {
        lock();
        int64_t ctx = call_hook(g_pick, id, 0, 1);
        unlock();
        if (!ctx) {
            __asm__ volatile("sti; hlt; cli"); /* an interrupt (timer or kick) ends the wait */
            continue;
        }
        int64_t v = enter_user((void *)(uintptr_t)ctx);
        lock();
        (void)call_hook(g_trap, id, v, 2);
        unlock();
    }
}

void smp_run_bsp(void) {
    __atomic_store_n(&g_go, 1, __ATOMIC_RELEASE);
    smp_loop(0);
}

void smp_kick(void) { LAPIC[0x300 / 4] = 0xC0000u | 0x21u; } /* all excluding self */

void ap_main(uint64_t idx);
void ap_main(uint64_t idx) {
    cpu_init((int)idx);
    LAPIC[0xF0 / 4] = 0x1FF;
    LAPIC[0x3E0 / 4] = 3;
    LAPIC[0x320 / 4] = 0x20000u | 0x20u;
    LAPIC[0x380 / 4] = g_timer_count;
    __atomic_store_n(&g_ap_up[idx], 1, __ATOMIC_RELEASE);
    while (!__atomic_load_n(&g_go, __ATOMIC_ACQUIRE)) __builtin_ia32_pause();
    smp_loop((int)idx);
}

static void icr(uint32_t apic, uint32_t lo) {
    LAPIC[0x310 / 4] = apic << 24;
    LAPIC[0x300 / 4] = lo;
    for (int i = 0; i < 1000000 && (LAPIC[0x300 / 4] & 0x1000); i++) __builtin_ia32_pause();
}
static void udelay(uint64_t us) {
    uint64_t t = uptime_us();
    while (uptime_us() - t < us) __builtin_ia32_pause();
}

int smp_start_ap(uint32_t apic_id, int idx) {
    if (idx <= 0 || idx >= MAX_CPUS) return 0;
    uint8_t *dst = (uint8_t *)(uintptr_t)0x8000;
    memcpy(dst, ap_tramp_start, (size_t)(ap_tramp_end - ap_tramp_start));
    volatile uint64_t *d = (volatile uint64_t *)(void *)(dst + (ap_data - ap_tramp_start));
    d[0] = (uint64_t)(uintptr_t)pml4;
    d[1] = (uint64_t)(uintptr_t)&g_ap_stack[idx][AP_STACK];
    d[2] = (uint64_t)(uintptr_t)ap_main;
    d[3] = (uint64_t)idx;
    g_ap_up[idx] = 0;
    icr(apic_id, 0x4500); /* INIT, level, assert */
    udelay(10000);
    icr(apic_id, 0x4600 | 0x08); /* SIPI: start at 0x8000 */
    udelay(200);
    icr(apic_id, 0x4600 | 0x08);
    for (int i = 0; i < 1000 && !__atomic_load_n(&g_ap_up[idx], __ATOMIC_ACQUIRE); i++) udelay(100);
    return __atomic_load_n(&g_ap_up[idx], __ATOMIC_ACQUIRE);
}
