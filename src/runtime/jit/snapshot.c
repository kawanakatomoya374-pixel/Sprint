#include "snapshot.h"

#include <stdlib.h>
#include <string.h>

static uint8_t snapshot_tir_type(SpType type) {
    switch (type) {
    case T_INT: return (uint8_t)SP_TIR_T_I64;
    case T_FLOAT: return (uint8_t)SP_TIR_T_F64;
    case T_BOOL: return (uint8_t)SP_TIR_T_BOOL;
    case T_NIL: case T_STRING: case T_ARRAY: case T_TABLE: case T_FUNCTION:
    case T_CLASS: case T_INSTANCE: case T_MODULE: case T_ITERATOR: case T_COROUTINE:
    case T_ERROR: case T_NATIVE: case T_CELL: case T_UNINIT:
        return (uint8_t)SP_TIR_T_REF;
    default:
        return UINT8_MAX;
    }
}

static uint8_t snapshot_runtime_type(SpTIRType type) {
    switch (type) {
    case SP_TIR_T_I64: return (uint8_t)T_INT;
    case SP_TIR_T_F64: return (uint8_t)T_FLOAT;
    case SP_TIR_T_BOOL: return (uint8_t)T_BOOL;
    case SP_TIR_T_REF: return UINT8_MAX;
    default: return UINT8_MAX;
    }
}

static const SpTIRInst *snapshot_find_def(const SpTraceIR *ir, uint32_t value) {
    if (ir == NULL || value == 0U) return NULL;
    for (size_t i = 0U; i < ir->count; i++) {
        if (ir->inst[i].dst == value) return &ir->inst[i];
    }
    return NULL;
}

static int snapshot_slot_type_valid(uint8_t type) {
    return type <= (uint8_t)T_UNINIT;
}

static int snapshot_append_slot(SpJitSnapshotEntry *entries, size_t capacity,
                                size_t *count, uint32_t slot, SpType type) {
    uint8_t tir_type;
    if (entries == NULL || count == NULL || slot > UINT16_MAX || *count >= capacity ||
        !snapshot_slot_type_valid((uint8_t)type)) return 0;
    tir_type = snapshot_tir_type(type);
    if (tir_type == UINT8_MAX) return 0;
    entries[*count] = (SpJitSnapshotEntry){0U, (uint16_t)slot,
        (uint8_t)SP_JIT_SNAPSHOT_FROM_SLOT, tir_type, (uint8_t)type, 0U};
    (*count)++;
    return 1;
}

int sp_jit_snapshot_set_init(SpJitSnapshotSet *set, const SpTraceIR *ir,
                             const int32_t *phi_slot, const SpValue *base,
                             uint32_t local_count, uint32_t stack_depth,
                             uint32_t header_pc, uint32_t exit_pc,
                             uint32_t backedge_pc) {
    size_t phi_count = 0U, loop_capacity, loop_count = 0U;
    size_t entry_count = 0U, entry_capacity, bytes = 0U;
    uint8_t *seen = NULL;
    uint32_t slot_count;

    if (set == NULL || ir == NULL || phi_slot == NULL || base == NULL ||
        local_count == 0U || local_count > UINT16_MAX ||
        stack_depth > UINT16_MAX - local_count ||
        header_pc == UINT32_MAX || exit_pc == UINT32_MAX ||
        backedge_pc == UINT32_MAX || ir->nvalues == 0U) return 0;
    memset(set, 0, sizeof *set);
    slot_count = local_count + stack_depth;

    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *inst = &ir->inst[i];
        if (inst->op != SP_TIR_PHI) continue;
        if (inst->dst == 0U || inst->dst > ir->nvalues || phi_slot[inst->dst] < 0) goto fail;
        if ((uint32_t)phi_slot[inst->dst] >= slot_count) continue;   /* a module variable the native code keeps in a scratch slot */
        phi_count++;
    }
    /* Every unchanged local and operand-stack cell is part of the restore map.
     * PHI-backed locals and stack cells are materialized by native code. */
    if (phi_count > slot_count) goto fail;
    loop_capacity = slot_count;
    entry_capacity = 0U;
    if (loop_capacity > UINT16_MAX || entry_capacity > UINT16_MAX ||
        loop_capacity > SIZE_MAX / sizeof *set->entries ||
        entry_capacity > SIZE_MAX / sizeof *set->entry_entries) goto fail;

    set->entries = loop_capacity != 0U ?
        (SpJitSnapshotEntry *)calloc(loop_capacity, sizeof *set->entries) : NULL;
    set->entry_entries = NULL;
    seen = (uint8_t *)calloc((size_t)slot_count, sizeof *seen);
    if ((loop_capacity != 0U && set->entries == NULL) ||
        seen == NULL) goto fail;

    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *inst = &ir->inst[i];
        const SpTIRInst *param;
        uint32_t slot;
        uint8_t runtime_type;
        if (inst->op != SP_TIR_PHI) continue;
        slot = (uint32_t)phi_slot[inst->dst];
        if (slot >= slot_count) continue;
        if (seen[slot] != 0U || inst->a == 0U ||
            (param = snapshot_find_def(ir, inst->a)) == NULL || param->op != SP_TIR_PARAM) goto fail;
        if (inst->type == SP_TIR_T_REF) {
            if (param->aux > (uint32_t)T_CELL) goto fail;
            runtime_type = (uint8_t)param->aux;
        } else {
            runtime_type = snapshot_runtime_type(inst->type);
            if (runtime_type == UINT8_MAX) goto fail;
        }
        if (base[slot].type != runtime_type) goto fail;
        seen[slot] = 1U;
        set->entries[loop_count++] = (SpJitSnapshotEntry){inst->dst, (uint16_t)slot,
            (uint8_t)SP_JIT_SNAPSHOT_FROM_IR, (uint8_t)inst->type, runtime_type, 0U};
    }

    /* Unchanged locals remain in their VM slots.  Keeping an exact type entry
     * documents their restoration contract and guards against stale frames. */
    for (uint32_t i = 0U; i < local_count; i++) {
        if (seen[i] == 0U) {
            if (!snapshot_append_slot(set->entries, loop_capacity, &loop_count, i,
                                      (SpType)base[i].type)) goto fail;
            seen[i] = 1U;
        }
    }
    /* Operand stack cells may be PHI-backed and materialized by native code,
     * or unchanged and preserved in their VM slots.  Register each cell once. */
    for (uint32_t i = 0U; i < stack_depth; i++) {
        uint32_t slot = local_count + i;
        if (seen[slot] == 0U) {
            if (!snapshot_append_slot(set->entries, loop_capacity, &loop_count, slot,
                                      (SpType)base[slot].type)) goto fail;
            seen[slot] = 1U;
        }
    }

    /* An entry MISS is raised before native state is modified.  Keep an empty
     * map so a type mismatch cannot make restoration reject the very value
     * whose type caused the miss.  The VM slots themselves remain GC roots. */
    free(seen);
    seen = NULL;

    set->loop_map.entries = set->entries;
    set->loop_map.local_count = local_count;
    set->loop_map.slot_count = slot_count;
    set->loop_map.entry_count = (uint16_t)loop_count;
    set->loop_map.stack_depth = (uint16_t)stack_depth;
    set->entry_map.entries = NULL;
    set->entry_map.local_count = local_count;
    set->entry_map.slot_count = slot_count;
    set->entry_map.entry_count = 0U;
    set->entry_map.stack_depth = (uint16_t)stack_depth;

    set->snapshots[SP_JIT_SNAPSHOT_EXIT] = (SpJitSnapshot){
        &set->loop_map, exit_pc, (uint8_t)SP_JIT_SNAPSHOT_EXIT};
    set->snapshots[SP_JIT_SNAPSHOT_DEOPT] = (SpJitSnapshot){
        &set->loop_map, header_pc, (uint8_t)SP_JIT_SNAPSHOT_DEOPT};
    set->snapshots[SP_JIT_SNAPSHOT_MISS] = (SpJitSnapshot){
        &set->entry_map, header_pc, (uint8_t)SP_JIT_SNAPSHOT_MISS};
    set->snapshots[SP_JIT_SNAPSHOT_BUDGET] = (SpJitSnapshot){
        &set->loop_map, backedge_pc, (uint8_t)SP_JIT_SNAPSHOT_BUDGET};

    bytes = loop_count * sizeof *set->entries;
    (void)entry_count;
    if (bytes > SIZE_MAX - sizeof *set) goto fail;
    set->bytes = bytes + sizeof *set;
    return 1;

fail:
    free(seen);
    sp_jit_snapshot_set_destroy(set);
    return 0;
}

void sp_jit_snapshot_set_destroy(SpJitSnapshotSet *set) {
    if (set == NULL) return;
    free(set->entries);
    free(set->entry_entries);
    memset(set, 0, sizeof *set);
}

int sp_jit_snapshot_make_token(uint8_t slot, uint8_t kind, uint32_t *token_out) {
    if (token_out == NULL || slot >= SP_JIT_SNAPSHOT_SLOT_COUNT ||
        kind >= SP_JIT_SNAPSHOT_KIND_COUNT) return 0;
    *token_out = SP_JIT_SNAPSHOT_TAG |
                 ((uint32_t)slot << SP_JIT_SNAPSHOT_SLOT_SHIFT) |
                 (uint32_t)kind;
    return 1;
}

int sp_jit_snapshot_decode_token(uint32_t token, uint8_t *slot_out, uint8_t *kind_out) {
    uint32_t payload;
    if ((token & SP_JIT_SNAPSHOT_TAG) == 0U || slot_out == NULL || kind_out == NULL) return 0;
    payload = token & ~SP_JIT_SNAPSHOT_TAG;
    if ((payload & ~(SP_JIT_SNAPSHOT_SLOT_MASK | SP_JIT_SNAPSHOT_KIND_MASK)) != 0U) return 0;
    *slot_out = (uint8_t)((payload & SP_JIT_SNAPSHOT_SLOT_MASK) >> SP_JIT_SNAPSHOT_SLOT_SHIFT);
    *kind_out = (uint8_t)(payload & SP_JIT_SNAPSHOT_KIND_MASK);
    return *slot_out < SP_JIT_SNAPSHOT_SLOT_COUNT && *kind_out < SP_JIT_SNAPSHOT_KIND_COUNT;
}

static int snapshot_shape_valid(const SpJitSnapshot *snapshot, const Proto *proto) {
    const SpJitSnapshotMap *map;
    if (snapshot == NULL || proto == NULL || snapshot->map == NULL ||
        snapshot->kind >= SP_JIT_SNAPSHOT_KIND_COUNT || snapshot->resume_pc > proto->code_len) return 0;
    map = snapshot->map;
    if (map->local_count != (uint32_t)proto->nlocals ||
        map->stack_depth > UINT16_MAX - map->local_count ||
        map->slot_count != map->local_count + map->stack_depth ||
        map->entry_count > map->slot_count ||
        (map->entry_count != 0U && map->entries == NULL)) return 0;
    for (uint16_t i = 0U; i < map->entry_count; i++) {
        const SpJitSnapshotEntry *entry = &map->entries[i];
        if (entry->slot >= map->slot_count || !snapshot_slot_type_valid(entry->runtime_type) ||
            entry->type != snapshot_tir_type((SpType)entry->runtime_type)) return 0;
        if (entry->source == (uint8_t)SP_JIT_SNAPSHOT_FROM_IR) {
            uint8_t expected = snapshot_runtime_type((SpTIRType)entry->type);
            if (entry->value == 0U ||
                (entry->type == (uint8_t)SP_TIR_T_REF && entry->runtime_type > (uint8_t)T_CELL) ||
                (entry->type != (uint8_t)SP_TIR_T_REF && expected != entry->runtime_type)) return 0;
        } else if (entry->source == (uint8_t)SP_JIT_SNAPSHOT_FROM_SLOT) {
            if (entry->value != 0U) return 0;
        } else return 0;
    }
    return 1;
}

int sp_jit_snapshot_validate(const SpJitSnapshot *snapshot, const Proto *proto) {
    uint8_t *seen;
    if (!snapshot_shape_valid(snapshot, proto)) return 0;
    if (snapshot->map->slot_count == 0U) return snapshot->map->entry_count == 0U;
    seen = (uint8_t *)calloc((size_t)snapshot->map->slot_count, sizeof *seen);
    if (seen == NULL) return 0;
    for (uint16_t i = 0U; i < snapshot->map->entry_count; i++) {
        uint16_t slot = snapshot->map->entries[i].slot;
        if (seen[slot] != 0U) { free(seen); return 0; }
        seen[slot] = 1U;
    }
    free(seen);
    return 1;
}

int sp_jit_snapshot_restore(const SpJitSnapshot *snapshot, const Proto *proto,
                            Frame *frame, SpValue *base,
                            SpValue **sp_out, const uint8_t **pc_out) {
    if (frame == NULL || base == NULL || sp_out == NULL || pc_out == NULL ||
        frame->fn == NULL || frame->fn->proto != proto || frame->base != base ||
        proto == NULL || proto->code == NULL || !snapshot_shape_valid(snapshot, proto)) return 0;
    for (uint16_t i = 0U; i < snapshot->map->entry_count; i++) {
        const SpJitSnapshotEntry *entry = &snapshot->map->entries[i];
        if (entry->source == (uint8_t)SP_JIT_SNAPSHOT_FROM_IR &&
            base[entry->slot].type != entry->runtime_type) return 0;
    }
    *pc_out = proto->code + snapshot->resume_pc;
    *sp_out = base + snapshot->map->slot_count;
    return 1;
}
