#ifndef OS_CPU_H
#define OS_CPU_H
#include <stddef.h>
#include <stdint.h>
#include "cpu_defs.h"

enum { MAX_CPUS = 32 };

typedef struct PerCpu {
    uint64_t self, kctx_rsp, cur_ctx, rsp0, uscratch, id, kfs;
    uint64_t pad[9];
} PerCpu;
_Static_assert(sizeof(PerCpu) == PC_SIZE, "PerCpu size");

extern PerCpu g_pc[MAX_CPUS];
extern volatile uint64_t g_irq_count[256];
extern int lapic_present;

void cpu_init(int id);
void cpu_capture_fs(void);
uint8_t *cpu_iopb(int id);
int enter_user(void *ctx); /* cpu.S */
#endif
