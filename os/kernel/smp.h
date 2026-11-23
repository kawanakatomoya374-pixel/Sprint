#ifndef OS_SMP_H
#define OS_SMP_H
#include <stdint.h>
#include "sprint.h"
enum { AP_STACK = 2 * 1024 * 1024 };
void smp_set_hooks(SpVM *vm, SpRef *pick, SpRef *trap);
void smp_set_timer(uint32_t count);
void smp_run_bsp(void) __attribute__((noreturn));
void smp_kick(void);
int smp_start_ap(uint32_t apic_id, int idx);
void smp_go(void);
int shared_register(SpVM *vm);
void smp_note_apic(int cpu, uint32_t apic_id);
void smp_send_ipi(int cpu);
void ap_vm_run(int cpu);
#endif
