#ifndef SPRINT_RUNTIME_JIT_SNAPSHOT_H
#define SPRINT_RUNTIME_JIT_SNAPSHOT_H

#include <stddef.h>
#include <stdint.h>
#include "../../sp.h"
#include "../trace_ir.h"

enum {
    SP_JIT_SNAPSHOT_EXIT = 0,
    SP_JIT_SNAPSHOT_DEOPT = 1,
    SP_JIT_SNAPSHOT_MISS = 2,
    SP_JIT_SNAPSHOT_BUDGET = 3,
    SP_JIT_SNAPSHOT_KIND_COUNT = 4,
    SP_JIT_SNAPSHOT_SLOT_COUNT = 64
};

#define SP_JIT_SNAPSHOT_TAG UINT32_C(0x80000000)
#define SP_JIT_SNAPSHOT_SLOT_SHIFT 2U
#define SP_JIT_SNAPSHOT_SLOT_MASK UINT32_C(0x000000fc)
#define SP_JIT_SNAPSHOT_KIND_MASK UINT32_C(0x00000003)

typedef enum {
    SP_JIT_SNAPSHOT_FROM_IR = 1,
    /* Value is already materialized in its VM frame slot and is preserved in place. */
    SP_JIT_SNAPSHOT_FROM_SLOT = 2
} SpJitSnapshotSource;

typedef struct {
    uint32_t value;
    uint16_t slot;       /* absolute slot from Frame.base: locals, then operand stack */
    uint8_t source;
    uint8_t type;        /* SpTIRType */
    uint8_t runtime_type;/* exact SpType present in the VM slot */
    uint8_t reserved;
} SpJitSnapshotEntry;

typedef struct {
    const SpJitSnapshotEntry *entries;
    uint32_t local_count;
    uint32_t slot_count; /* local_count + stack_depth */
    uint16_t entry_count;
    uint16_t stack_depth;
} SpJitSnapshotMap;

typedef struct {
    const SpJitSnapshotMap *map;
    uint32_t resume_pc;
    uint8_t kind;
} SpJitSnapshot;

typedef struct {
    SpJitSnapshotEntry *entries;
    SpJitSnapshotEntry *entry_entries;
    SpJitSnapshotMap loop_map;
    SpJitSnapshotMap entry_map;
    SpJitSnapshot snapshots[SP_JIT_SNAPSHOT_KIND_COUNT];
    size_t bytes;
} SpJitSnapshotSet;

int sp_jit_snapshot_set_init(SpJitSnapshotSet *set, const SpTraceIR *ir,
                             const int32_t *phi_slot, const SpValue *base,
                             uint32_t local_count, uint32_t stack_depth,
                             uint32_t header_pc, uint32_t exit_pc,
                             uint32_t backedge_pc);
void sp_jit_snapshot_set_destroy(SpJitSnapshotSet *set);
int sp_jit_snapshot_make_token(uint8_t slot, uint8_t kind, uint32_t *token_out);
int sp_jit_snapshot_decode_token(uint32_t token, uint8_t *slot_out, uint8_t *kind_out);
int sp_jit_snapshot_validate(const SpJitSnapshot *snapshot, const Proto *proto);
int sp_jit_snapshot_restore(const SpJitSnapshot *snapshot, const Proto *proto,
                            Frame *frame, SpValue *base,
                            SpValue **sp_out, const uint8_t **pc_out);

#endif
