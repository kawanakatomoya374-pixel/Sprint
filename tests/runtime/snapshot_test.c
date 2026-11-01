#include "runtime/jit/snapshot.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { \
    if (!(expr)) { \
        (void)fprintf(stderr, "snapshot-test: failed at %s:%d: %s\n", \
                      __FILE__, __LINE__, #expr); \
        return 1; \
    } \
} while (0)

int main(void) {
    SpTraceIR ir;
    SpJitSnapshotSet set;
    SpJitSnapshotMap invalid_map;
    SpJitSnapshot invalid_snapshot;
    SpTIRValue param = 0U, phi = 0U, ref_param = 0U, ref_phi = 0U;
    SpTIRValue one = 0U, next = 0U, stack_param = 0U, stack_phi = 0U;
    int32_t phi_local[8];
    uint8_t code[64];
    Proto proto;
    SFunc fn;
    Frame frame;
    SpValue locals[8];
    Obj stack_obj;
    SpValue *restored_sp = NULL;
    const uint8_t *restored_pc = NULL;
    uint32_t token = 0U;
    uint8_t slot = 0U, kind = 0U;

    memset(&set, 0, sizeof set);
    memset(&proto, 0, sizeof proto);
    memset(&fn, 0, sizeof fn);
    memset(&frame, 0, sizeof frame);
    memset(&stack_obj, 0, sizeof stack_obj);
    memset(code, 0, sizeof code);
    memset(locals, 0, sizeof locals);
    for (size_t i = 0U; i < sizeof phi_local / sizeof phi_local[0]; i++) phi_local[i] = -1;

    sp_tir_init(&ir);
    CHECK(sp_tir_emit_param(&ir, SP_TIR_T_I64, 2U, &param));
    CHECK(sp_tir_emit_param_ex(&ir, SP_TIR_T_REF, 1U, (uint8_t)T_STRING, &ref_param));
    CHECK(sp_tir_emit_phi(&ir, SP_TIR_T_I64, param, &phi));
    CHECK(sp_tir_emit_phi(&ir, SP_TIR_T_REF, ref_param, &ref_phi));
    CHECK(sp_tir_emit_param_ex(&ir, SP_TIR_T_REF, 4U, (uint8_t)T_STRING, &stack_param));
    CHECK(sp_tir_emit_phi(&ir, SP_TIR_T_REF, stack_param, &stack_phi));
    CHECK(sp_tir_emit_const_i64(&ir, 1, &one));
    CHECK(sp_tir_emit_binary(&ir, SP_TIR_IADD, phi, one, &next));
    CHECK(sp_tir_set_phi_backedge(&ir, phi, next));
    CHECK(sp_tir_set_phi_backedge(&ir, ref_phi, ref_phi));
    CHECK(sp_tir_set_phi_backedge(&ir, stack_phi, stack_phi));
    CHECK(sp_tir_emit_loop(&ir));
    phi_local[phi] = 2;
    phi_local[ref_phi] = 1;
    phi_local[stack_phi] = 4;

    locals[0] = v_int(1);
    locals[1] = v_obj(T_STRING, &stack_obj);
    locals[2] = v_int(42);
    locals[3] = v_uninit();
    locals[4] = v_obj(T_STRING, &stack_obj);
    locals[5] = v_obj(T_TABLE, &stack_obj);
    CHECK(sp_jit_snapshot_set_init(&set, &ir, phi_local, locals, 4U, 2U,
                                   8U, 30U, 25U));
    CHECK(set.loop_map.entry_count == 6U);
    CHECK(set.loop_map.entries[0].slot == 2U);
    CHECK(set.loop_map.entries[0].value == phi);
    CHECK(set.loop_map.entries[1].slot == 1U);
    CHECK(set.loop_map.entries[1].type == SP_TIR_T_REF);
    CHECK(set.loop_map.entries[1].runtime_type == T_STRING);
    CHECK(set.loop_map.entries[2].slot == 4U);
    CHECK(set.loop_map.entries[2].source == SP_JIT_SNAPSHOT_FROM_IR);
    CHECK(set.loop_map.entries[2].value == stack_phi);
    CHECK(set.loop_map.local_count == 4U && set.loop_map.slot_count == 6U);
    CHECK(set.loop_map.stack_depth == 2U);
    CHECK(set.loop_map.entries[5].source == SP_JIT_SNAPSHOT_FROM_SLOT);
    CHECK(set.snapshots[SP_JIT_SNAPSHOT_EXIT].resume_pc == 30U);
    CHECK(set.snapshots[SP_JIT_SNAPSHOT_DEOPT].resume_pc == 8U);
    CHECK(set.snapshots[SP_JIT_SNAPSHOT_MISS].resume_pc == 8U);
    CHECK(set.snapshots[SP_JIT_SNAPSHOT_BUDGET].resume_pc == 25U);
    CHECK(set.snapshots[SP_JIT_SNAPSHOT_MISS].map->entry_count == 0U);
    CHECK(set.snapshots[SP_JIT_SNAPSHOT_MISS].map->stack_depth == 2U);

    proto.nlocals = 4;
    proto.code = code;
    proto.code_len = (uint32_t)sizeof code;
    fn.proto = &proto;
    frame.fn = &fn;
    frame.base = locals;
    CHECK(sp_jit_snapshot_validate(&set.snapshots[SP_JIT_SNAPSHOT_EXIT], &proto));
    CHECK(sp_jit_snapshot_restore(&set.snapshots[SP_JIT_SNAPSHOT_EXIT], &proto,
                                  &frame, locals, &restored_sp, &restored_pc));
    CHECK(restored_pc == code + 30U);
    CHECK(restored_sp == locals + 6U);

    /* The stack PHI is specialized and materialized by native code.  The
     * untouched top stack cell remains in place and is not a type guard. */
    locals[5] = v_obj(T_ARRAY, &stack_obj);
    CHECK(sp_jit_snapshot_restore(&set.snapshots[SP_JIT_SNAPSHOT_EXIT], &proto,
                                  &frame, locals, &restored_sp, &restored_pc));
    CHECK(restored_sp == locals + 6U && locals[4].type == T_STRING && locals[5].type == T_ARRAY);
    locals[5] = v_obj(T_TABLE, &stack_obj);
    locals[4] = v_obj(T_ARRAY, &stack_obj);
    CHECK(!sp_jit_snapshot_restore(&set.snapshots[SP_JIT_SNAPSHOT_EXIT], &proto,
                                   &frame, locals, &restored_sp, &restored_pc));
    locals[4] = v_obj(T_STRING, &stack_obj);

    locals[2] = v_float(42.0);
    CHECK(!sp_jit_snapshot_restore(&set.snapshots[SP_JIT_SNAPSHOT_EXIT], &proto,
                                   &frame, locals, &restored_sp, &restored_pc));
    locals[2] = v_int(42);
    /* Entry MISS must restore even when the original loop-local type guard
     * failed. The pre-entry VM frame and operand stack remain untouched. */
    locals[2] = v_float(42.0);
    CHECK(sp_jit_snapshot_restore(&set.snapshots[SP_JIT_SNAPSHOT_MISS], &proto,
                                  &frame, locals, &restored_sp, &restored_pc));
    CHECK(restored_pc == code + 8U && restored_sp == locals + 6U);
    locals[2] = v_int(42);

    CHECK(sp_jit_snapshot_make_token(63U, (uint8_t)SP_JIT_SNAPSHOT_BUDGET, &token));
    CHECK(sp_jit_snapshot_decode_token(token, &slot, &kind));
    CHECK(slot == 63U && kind == (uint8_t)SP_JIT_SNAPSHOT_BUDGET);
    CHECK(!sp_jit_snapshot_make_token(64U, (uint8_t)SP_JIT_SNAPSHOT_EXIT, &token));
    CHECK(!sp_jit_snapshot_make_token(0U, 4U, &token));
    CHECK(!sp_jit_snapshot_decode_token(30U, &slot, &kind));
    CHECK(!sp_jit_snapshot_decode_token(UINT32_C(0x80000100), &slot, &kind));

    invalid_map = set.loop_map;
    invalid_snapshot = set.snapshots[SP_JIT_SNAPSHOT_EXIT];
    invalid_map.stack_depth = 1U;
    invalid_snapshot.map = &invalid_map;
    CHECK(!sp_jit_snapshot_validate(&invalid_snapshot, &proto));

    sp_jit_snapshot_set_destroy(&set);
    sp_tir_destroy(&ir);
    (void)puts("snapshot: 34 invariant checks passed");
    return 0;
}
