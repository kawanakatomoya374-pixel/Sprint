#ifndef SPRINT_TRACE_IR_H
#define SPRINT_TRACE_IR_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef uint32_t SpTIRValue;

typedef enum {
    SP_TIR_T_I64 = 1, SP_TIR_T_F64, SP_TIR_T_BOOL, SP_TIR_T_REF
} SpTIRType;

enum { SP_TIR_RUNTIME_TYPE_MAX = 16U };

typedef enum {
    SP_TIR_PARAM = 1, SP_TIR_CONST_I64, SP_TIR_CONST_F64, SP_TIR_CONST_BOOL,
    SP_TIR_PHI, SP_TIR_IADD, SP_TIR_ISUB, SP_TIR_IMUL, SP_TIR_IDIV,
    SP_TIR_IMOD, SP_TIR_INEG, SP_TIR_FADD, SP_TIR_FSUB, SP_TIR_FMUL,
    SP_TIR_FDIV, SP_TIR_FNEG, SP_TIR_ICMP_EQ, SP_TIR_ICMP_NE,
    SP_TIR_ICMP_LT, SP_TIR_ICMP_LE, SP_TIR_ICMP_GT, SP_TIR_ICMP_GE,
    SP_TIR_FCMP_EQ, SP_TIR_FCMP_NE, SP_TIR_FCMP_LT, SP_TIR_FCMP_LE,
    SP_TIR_FCMP_GT, SP_TIR_FCMP_GE, SP_TIR_GUARD_TRUE,
    SP_TIR_ALOAD,   /* dst = a[b]: a is an array reference, b an index; imm = the element tag the trace was recorded with; a failed bound or tag check deoptimises */
    SP_TIR_ASTORE,  /* a[b] = value aux (no result); the backend performs it after the iteration's last deopt point */
    SP_TIR_LOOP,
    SP_TIR_RETURN
} SpTIROp;

typedef struct {
    SpTIROp op;
    SpTIRType type;
    SpTIRValue dst, a, b;
    uint32_t aux;
    uint64_t imm;
} SpTIRInst;

typedef struct {
    SpTIRInst *inst;
    SpTIRType *value_types;
    size_t count, capacity, type_capacity;
    uint32_t nvalues;
    int body_started, terminated;
} SpTraceIR;

void sp_tir_init(SpTraceIR *ir);
void sp_tir_destroy(SpTraceIR *ir);
int sp_tir_emit_param(SpTraceIR *ir, SpTIRType type, uint32_t index, SpTIRValue *out);
int sp_tir_emit_param_ex(SpTraceIR *ir, SpTIRType type, uint32_t index,
                         uint8_t runtime_type, SpTIRValue *out);
int sp_tir_emit_const_i64(SpTraceIR *ir, int64_t value, SpTIRValue *out);
int sp_tir_emit_const_f64(SpTraceIR *ir, double value, SpTIRValue *out);
int sp_tir_emit_const_bool(SpTraceIR *ir, int value, SpTIRValue *out);
int sp_tir_emit_phi(SpTraceIR *ir, SpTIRType type, SpTIRValue entry, SpTIRValue *out);
int sp_tir_set_phi_backedge(SpTraceIR *ir, SpTIRValue phi, SpTIRValue backedge);
int sp_tir_emit_binary(SpTraceIR *ir, SpTIROp op, SpTIRValue a, SpTIRValue b, SpTIRValue *out);
int sp_tir_emit_unary(SpTraceIR *ir, SpTIROp op, SpTIRValue a, SpTIRValue *out);
/* flags of a guard (stored in the instruction's imm): where a failed guard leaves, and which truth value it demands */
enum { SP_TIR_GUARD_DEOPT = 1U,   /* leave through the deopt exit: restore the iteration-start state and re-run the iteration in the interpreter (default: the loop exit) */
       SP_TIR_GUARD_INVERT = 2U   /* the guard holds when the condition is FALSE (integer comparisons only in the native backend) */ };
int sp_tir_emit_guard_true(SpTraceIR *ir, SpTIRValue condition, uint32_t side_exit);
int sp_tir_emit_guard(SpTraceIR *ir, SpTIRValue condition, uint32_t side_exit, unsigned flags);
int sp_tir_emit_aload(SpTraceIR *ir, SpTIRType elem_type, uint8_t elem_tag, SpTIRValue array, SpTIRValue index, SpTIRValue *out);
int sp_tir_emit_astore(SpTraceIR *ir, SpTIRValue array, SpTIRValue index, SpTIRValue value);
int sp_tir_emit_loop(SpTraceIR *ir);
int sp_tir_emit_return(SpTraceIR *ir, SpTIRValue value);
int sp_tir_verify(const SpTraceIR *ir, char *message, size_t message_size);
int sp_tir_constant_fold(SpTraceIR *ir, size_t *folded_count);
int sp_tir_optimize(SpTraceIR *ir, size_t *folded_count, size_t *removed_count);
int sp_tir_dump(const SpTraceIR *ir, FILE *out);

#endif
