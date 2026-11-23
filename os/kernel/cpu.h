#ifndef OS_CPU_H
#define OS_CPU_H
#include <stddef.h>
#include <stdint.h>
#include "cpu_defs.h"

enum { MAX_CPUS = 8 }; /* the most processors SprintOS drives */

typedef struct PerCpu {
    uint64_t self, kctx_rsp, cur_ctx, rsp0, uscratch, id, kfs, kcr3;
    uint64_t pad[8];
} PerCpu;
_Static_assert(sizeof(PerCpu) == PC_SIZE, "PerCpu size");

extern PerCpu g_pc[MAX_CPUS];
extern volatile uint64_t g_irq_count[256];
extern int lapic_present;

enum { IRQ_BASE = 0x40 };
extern volatile uint64_t g_irq_pending;
extern volatile uint32_t *g_ioapic;
uint32_t ioapic_rd(uint32_t reg);
void ioapic_wr(uint32_t reg, uint32_t v);
void ioapic_set_mask(uint32_t gsi, int masked);
void cpu_init(int id);
void cpu_capture_fs(void);
uint8_t *cpu_iopb(int id);
int enter_user(void *ctx); /* cpu.S */
#endif
