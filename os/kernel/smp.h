#ifndef OS_SMP_H
#define OS_SMP_H
#include <stdint.h>
#include "sprint.h"
enum { AP_STACK = 262144 };
void smp_set_hooks(SpVM *vm, SpRef *pick, SpRef *trap);
void smp_set_timer(uint32_t count);
void smp_run_bsp(void) __attribute__((noreturn));
void smp_kick(void);
int smp_start_ap(uint32_t apic_id, int idx);
#endif
