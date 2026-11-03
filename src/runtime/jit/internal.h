#ifndef SPRINT_RUNTIME_JIT_INTERNAL_H
#define SPRINT_RUNTIME_JIT_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include "../../sp.h"

typedef struct JRegion JRegion;
typedef struct TraceRegion TraceRegion;

struct JitProto {
    JRegion **r;
    int n, cap, nok;
    JRegion *unit;
    TraceRegion *traces;
    size_t trace_bytes;
    unsigned trace_count;
    uint64_t trace_clock;
    struct TraceIndexSlot *trace_index;
    TraceRegion *trace_slots[64];
};

typedef struct {
    const uint8_t *pool;
    size_t count;
    uint32_t used;
    int32_t owner[32];
} JitRegBank;

extern const uint8_t JIT_TRACE_GPR_POOL[11];
void jit_ra_init(JitRegBank *bank, const uint8_t *pool, size_t count);
void jit_ra_reset(JitRegBank *bank);
uint32_t jit_ra_mask(const JitRegBank *bank);
int jit_ra_alloc(JitRegBank *bank, int32_t owner);
int jit_ra_reassign(JitRegBank *bank, int reg, int32_t owner);
int32_t jit_ra_owner(const JitRegBank *bank, int reg);
void jit_ra_release(JitRegBank *bank, int reg);

struct JitProto *jit_proto(Proto *p);
int jit_magic_of(int64_t d, uint64_t *m); /* reciprocal of a constant divisor, shared by the region JIT and the TraceJIT */
void *jit_code_publish(const void *bytes, size_t length, size_t *mapped_size);
void jit_code_unmap(void *mem, size_t mapped_size);
void jit_trace_free_all(struct JitProto *jp);

#endif
