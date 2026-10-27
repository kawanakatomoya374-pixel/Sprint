/* CPU layer: GDT with ring-3 segments and one TSS per CPU, the IDT, per-CPU blocks and the SYSCALL MSRs.
 * Policy lives in Sprint; this file only provides the mechanisms (see cpu.S for the trap entry). */
#include "cpu.h"
#include "kernel.h"
#include <string.h>

typedef struct __attribute__((packed)) Tss {
    uint32_t rsvd0;
    uint64_t rsp[3];
    uint64_t rsvd1;
    uint64_t ist[7];
    uint64_t rsvd2;
    uint16_t rsvd3;
    uint16_t iopb_off;
    uint8_t iopb[8192 + 1];
} Tss;

typedef struct __attribute__((packed)) IdtEntry {
    uint16_t lo, sel;
    uint8_t ist, attr;
    uint16_t mid;
    uint32_t hi, zero;
} IdtEntry;

enum { TRAP_STACK = 16384 };

PerCpu g_pc[MAX_CPUS] __attribute__((aligned(64)));
static Tss g_tss[MAX_CPUS] __attribute__((aligned(16)));
static uint64_t g_gdt[5 + 2 * MAX_CPUS] __attribute__((aligned(16)));
static IdtEntry g_idt[256] __attribute__((aligned(16)));
static uint8_t g_trap_stack[MAX_CPUS][TRAP_STACK] __attribute__((aligned(16)));
static uint64_t g_kernel_fs;
volatile uint64_t g_irq_count[256];
int lapic_present;
extern const uint64_t isr_table[256];
extern void syscall_entry(void);

static void wrmsr_(uint32_t msr, uint64_t v) {
    __asm__ volatile("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}
static uint64_t rdmsr_(uint32_t msr) {
    uint32_t lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
    return ((uint64_t)hi << 32) | lo;
}

static void idt_build(void) {
    for (int i = 0; i < 256; i++) {
        uint64_t a = isr_table[i];
        g_idt[i].lo = (uint16_t)a;
        g_idt[i].sel = SEL_KCODE;
        g_idt[i].attr = 0x8E; /* present, ring 0, interrupt gate (IF cleared on entry) */
        g_idt[i].mid = (uint16_t)(a >> 16);
        g_idt[i].hi = (uint32_t)(a >> 32);
    }
}

static void gdt_build(void) {
    g_gdt[0] = 0;
    g_gdt[1] = 0x00AF9A000000FFFFull; /* 0x08 kernel code */
    g_gdt[2] = 0x00CF92000000FFFFull; /* 0x10 kernel data */
    g_gdt[3] = 0x00CFF2000000FFFFull; /* 0x18 user data */
    g_gdt[4] = 0x00AFFA000000FFFFull; /* 0x20 user code (64-bit) */
    for (int c = 0; c < MAX_CPUS; c++) {
        uint64_t base = (uint64_t)(uintptr_t)&g_tss[c];
        uint64_t lim = sizeof(Tss) - 1;
        g_gdt[5 + 2 * c] = (lim & 0xFFFF) | ((base & 0xFFFFFF) << 16) | (0x89ull << 40) | (((lim >> 16) & 0xF) << 48) |
                           (((base >> 24) & 0xFF) << 56);
        g_gdt[6 + 2 * c] = base >> 32;
    }
}

/* the legacy 8259 PICs: move them out of the exception vectors and mask everything (the LAPIC/IOAPIC take over) */
static void pic_disable(void) {
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20); /* IRQ0-7 -> vectors 0x20.. (never delivered: all masked) */
    outb(0xA1, 0x28);
    outb(0x21, 4);
    outb(0xA1, 2);
    outb(0x21, 1);
    outb(0xA1, 1);
    outb(0x21, 0xFF);
    outb(0xA1, 0xFF);
}

/* make this CPU ready: its GDT/TSS/IDT, GS base (per-CPU block) and the SYSCALL MSRs */
void cpu_init(int id) {
    static int built;
    if (!built) {
        pic_disable();
        idt_build();
        gdt_build();
        built = 1;
    }
    PerCpu *pc = &g_pc[id];
    pc->self = (uint64_t)(uintptr_t)pc;
    pc->id = (uint64_t)id;
    pc->rsp0 = (uint64_t)(uintptr_t)&g_trap_stack[id][TRAP_STACK];
    if (id == 0) {
        uint64_t fs = rdmsr_(0xC0000100);
        g_kernel_fs = fs;
    }
    pc->kfs = g_kernel_fs;
    if (id != 0) wrmsr_(0xC0000100, g_kernel_fs); /* libc's thread pointer */
    Tss *t = &g_tss[id];
    t->rsp[0] = pc->rsp0;
    t->iopb_off = (uint16_t)offsetof(Tss, iopb);
    memset(t->iopb, 0xFF, sizeof t->iopb); /* no port access from ring 3 */
    struct __attribute__((packed)) { uint16_t lim; uint64_t base; } g = {(uint16_t)(sizeof g_gdt - 1), (uint64_t)(uintptr_t)g_gdt};
    __asm__ volatile("lgdt %0" : : "m"(g));
    /* reload CS and the data segments from the new GDT (an AP arrives with the trampoline's selectors) */
    __asm__ volatile("pushq $0x08\n\tleaq 1f(%%rip), %%rax\n\tpushq %%rax\n\tlretq\n1:\n\tmovw $0x10, %%ax\n\tmovw %%ax, %%ds\n\tmovw %%ax, %%es\n\tmovw %%ax, %%ss"
                     : : : "rax", "memory");
    struct __attribute__((packed)) { uint16_t lim; uint64_t base; } i = {(uint16_t)(sizeof g_idt - 1), (uint64_t)(uintptr_t)g_idt};
    __asm__ volatile("lidt %0" : : "m"(i));
    uint16_t sel = (uint16_t)(0x28 + 16 * id);
    __asm__ volatile("ltr %0" : : "r"(sel));
    wrmsr_(0xC0000101, (uint64_t)(uintptr_t)pc); /* GS base: the per-CPU block */
    wrmsr_(0xC0000102, 0);                       /* KERNEL_GS_BASE: user value */
    wrmsr_(0xC0000080, rdmsr_(0xC0000080) | 1);  /* EFER.SCE */
    wrmsr_(0xC0000081, ((uint64_t)SEL_KCODE << 32) | ((uint64_t)0x10 << 48));
    wrmsr_(0xC0000082, (uint64_t)(uintptr_t)syscall_entry);
    wrmsr_(0xC0000084, 0x200 | 0x100 | 0x400);   /* SFMASK: clear IF, TF, DF on entry */
}

/* record the kernel's FS base (libc's thread pointer) once libc has set it up; every CPU restores it on a trap */
void cpu_capture_fs(void) {
    g_kernel_fs = rdmsr_(0xC0000100);
    for (int i = 0; i < MAX_CPUS; i++) g_pc[i].kfs = g_kernel_fs;
}

/* the I/O permission bitmap of this CPU's TSS: bit set = port denied */
uint8_t *cpu_iopb(int id) { return g_tss[id].iopb; }

/* an interrupt arrived while the kernel was idle (hlt): count it; the Sprint scheduler looks at the counters */
void kernel_irq(uint64_t vec);
void kernel_irq(uint64_t vec) {
    g_irq_count[vec & 255]++;
    volatile uint32_t *lapic = (volatile uint32_t *)(uintptr_t)0xFEE00000u;
    if (lapic_present) lapic[0xB0 / 4] = 0; /* EOI */
}
