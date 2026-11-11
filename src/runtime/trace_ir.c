/* Typed SSA trace IR used by the tracing JIT and its standalone verifier tests. */
#include "trace_ir.h"
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#define SP_TIR_MAX_INST UINT32_C(65536)
#define SP_TIR_NO_VALUE UINT32_C(0)
#define SP_TIR_NO_EXIT UINT32_MAX

static int tir_valid_type(SpTIRType type) {
    return type == SP_TIR_T_I64 || type == SP_TIR_T_F64 ||
           type == SP_TIR_T_BOOL || type == SP_TIR_T_REF;
}

static const char *tir_type_name(SpTIRType type) {
    switch (type) {
    case SP_TIR_T_I64: return "i64";
    case SP_TIR_T_F64: return "f64";
    case SP_TIR_T_BOOL: return "bool";
    case SP_TIR_T_REF: return "ref";
    default: break;
    }
    return "<invalid-type>";
}

static const char *tir_op_name(SpTIROp op) {
    switch (op) {
    case SP_TIR_PARAM: return "param";
    case SP_TIR_CONST_I64: return "const.i64";
    case SP_TIR_CONST_F64: return "const.f64";
    case SP_TIR_CONST_BOOL: return "const.bool";
    case SP_TIR_PHI: return "phi";
    case SP_TIR_IADD: return "iadd";
    case SP_TIR_ISUB: return "isub";
    case SP_TIR_IMUL: return "imul";
    case SP_TIR_IDIV: return "idiv";
    case SP_TIR_IMOD: return "imod";
    case SP_TIR_I2F: return "i2f";
    case SP_TIR_FCALL1: return "fcall1";
    case SP_TIR_FSQRT: return "fsqrt";
    case SP_TIR_FABS: return "fabs";
    case SP_TIR_FFLOOR: return "ffloor";
    case SP_TIR_IAND: return "iand";
    case SP_TIR_IOR: return "ior";
    case SP_TIR_IXOR: return "ixor";
    case SP_TIR_ISHL: return "ishl";
    case SP_TIR_ISHR: return "ishr";
    case SP_TIR_INEG: return "ineg";
    case SP_TIR_FADD: return "fadd";
    case SP_TIR_FSUB: return "fsub";
    case SP_TIR_FMUL: return "fmul";
    case SP_TIR_FDIV: return "fdiv";
    case SP_TIR_FNEG: return "fneg";
    case SP_TIR_ICMP_EQ: return "icmp.eq";
    case SP_TIR_ICMP_NE: return "icmp.ne";
    case SP_TIR_ICMP_LT: return "icmp.lt";
    case SP_TIR_ICMP_LE: return "icmp.le";
    case SP_TIR_ICMP_GT: return "icmp.gt";
    case SP_TIR_ICMP_GE: return "icmp.ge";
    case SP_TIR_FCMP_EQ: return "fcmp.eq";
    case SP_TIR_FCMP_NE: return "fcmp.ne";
    case SP_TIR_FCMP_LT: return "fcmp.lt";
    case SP_TIR_FCMP_LE: return "fcmp.le";
    case SP_TIR_FCMP_GT: return "fcmp.gt";
    case SP_TIR_FCMP_GE: return "fcmp.ge";
    case SP_TIR_GUARD_TRUE: return "guard.true";
    case SP_TIR_LOOP: return "loop";
    case SP_TIR_FLOAD: return "fload";
    case SP_TIR_FSTORE: return "fstore";
    case SP_TIR_CGUARD: return "cguard";
    case SP_TIR_UCELL: return "ucell";
    case SP_TIR_SLOAD: return "sload";
    case SP_TIR_LEAFCALL: return "leafcall";
    case SP_TIR_VFIELD: return "vfield";
    case SP_TIR_NEWINST: return "newinst";
    case SP_TIR_ALOAD: return "aload";
    case SP_TIR_ASTORE: return "astore";
    case SP_TIR_RETURN: return "return";
    default: break;
    }
    return "<invalid-op>";
}

static void tir_error(char *message, size_t message_size, const char *text) {
    size_t i = 0U;
    if (message == NULL || message_size == 0U) return;
    while (i + 1U < message_size && text[i] != '\0') {
        message[i] = text[i];
        i++;
    }
    message[i] = '\0';
}

void sp_tir_init(SpTraceIR *ir) {
    if (ir != NULL) {
        memset(ir, 0, sizeof *ir);
    }
}

void sp_tir_destroy(SpTraceIR *ir) {
    if (ir != NULL) {
        free(ir->inst);
        free(ir->value_types);
        memset(ir, 0, sizeof *ir);
    }
}

static int tir_reserve(SpTraceIR *ir, size_t extra) {
    size_t need;
    size_t next;
    SpTIRInst *grown;

    if (ir == NULL || extra > (size_t)SP_TIR_MAX_INST ||
        ir->count > (size_t)SP_TIR_MAX_INST - extra) {
        return 0;
    }
    need = ir->count + extra;
    if (need <= ir->capacity) {
        return 1;
    }
    next = ir->capacity == 0U ? 16U : ir->capacity;
    while (next < need) {
        if (next > (size_t)SP_TIR_MAX_INST / 2U) {
            next = (size_t)SP_TIR_MAX_INST;
            break;
        }
        next *= 2U;
    }
    if (next < need || next > SIZE_MAX / sizeof *grown) {
        return 0;
    }
    grown = (SpTIRInst *)realloc(ir->inst, next * sizeof *grown);
    if (grown == NULL) {
        return 0;
    }
    ir->inst = grown;
    ir->capacity = next;
    return 1;
}

static int tir_append(SpTraceIR *ir, SpTIROp op, SpTIRType type,
                      SpTIRValue a, SpTIRValue b, uint32_t aux,
                      uint64_t imm, int has_result, SpTIRValue *out) {
    SpTIRInst inst;
    if (ir == NULL || ir->terminated || !tir_reserve(ir, 1U)) {
        return 0;
    }
    if (has_result) {
        size_t need;
        size_t next;
        SpTIRType *grown;
        if (ir->nvalues >= UINT32_MAX - 1U || out == NULL) return 0;
        need = (size_t)ir->nvalues + 2U;
        if (need > ir->type_capacity) {
            next = ir->type_capacity == 0U ? 16U : ir->type_capacity;
            while (next < need) {
                if (next > ((size_t)SP_TIR_MAX_INST + 1U) / 2U) {
                    next = (size_t)SP_TIR_MAX_INST + 1U;
                    break;
                }
                next *= 2U;
            }
            if (next < need || next > SIZE_MAX / sizeof *grown) return 0;
            grown = (SpTIRType *)realloc(ir->value_types, next * sizeof *grown);
            if (grown == NULL) return 0;
            ir->value_types = grown;
            ir->type_capacity = next;
        }
    }
    inst.op = op;
    inst.type = type;
    inst.dst = has_result ? ir->nvalues + 1U : SP_TIR_NO_VALUE;
    inst.a = a;
    inst.b = b;
    inst.aux = aux;
    inst.imm = imm;
    ir->inst[ir->count++] = inst;
    if (has_result) {
        ir->nvalues++;
        ir->value_types[inst.dst] = type;
    }
    if (op != SP_TIR_PARAM && op != SP_TIR_CONST_I64 &&
        op != SP_TIR_CONST_F64 && op != SP_TIR_CONST_BOOL &&
        op != SP_TIR_PHI) {
        ir->body_started = 1;
    }
    if (op == SP_TIR_LOOP || op == SP_TIR_RETURN) {
        ir->terminated = 1;
    }
    if (out != NULL) *out = inst.dst;
    return 1;
}

int sp_tir_emit_param(SpTraceIR *ir, SpTIRType type, uint32_t index, SpTIRValue *out) {
    return sp_tir_emit_param_ex(ir, type, index, 0U, out);
}

int sp_tir_emit_param_ex(SpTraceIR *ir, SpTIRType type, uint32_t index,
                         uint8_t runtime_type, SpTIRValue *out) {
    if (!tir_valid_type(type) ||
        (type == SP_TIR_T_REF && runtime_type > SP_TIR_RUNTIME_TYPE_MAX) ||
        (type != SP_TIR_T_REF && runtime_type != 0U)) return 0;
    return tir_append(ir, SP_TIR_PARAM, type, SP_TIR_NO_VALUE, SP_TIR_NO_VALUE,
                      runtime_type, (uint64_t)index, 1, out);
}

int sp_tir_emit_const_i64(SpTraceIR *ir, int64_t value, SpTIRValue *out) {
    return tir_append(ir, SP_TIR_CONST_I64, SP_TIR_T_I64,
                      SP_TIR_NO_VALUE, SP_TIR_NO_VALUE, 0U,
                      (uint64_t)value, 1, out);
}

int sp_tir_emit_const_f64(SpTraceIR *ir, double value, SpTIRValue *out) {
    uint64_t bits = 0U;
    _Static_assert(sizeof bits == sizeof value, "F64 payload width");
    memcpy(&bits, &value, sizeof bits);
    return tir_append(ir, SP_TIR_CONST_F64, SP_TIR_T_F64,
                      SP_TIR_NO_VALUE, SP_TIR_NO_VALUE, 0U,
                      bits, 1, out);
}

int sp_tir_emit_const_bool(SpTraceIR *ir, int value, SpTIRValue *out) {
    if (value != 0 && value != 1) return 0;
    return tir_append(ir, SP_TIR_CONST_BOOL, SP_TIR_T_BOOL,
                      SP_TIR_NO_VALUE, SP_TIR_NO_VALUE, 0U,
                      (uint64_t)value, 1, out);
}

static int tir_value_type(const SpTraceIR *ir, SpTIRValue value, SpTIRType *type) {
    if (ir == NULL || value == SP_TIR_NO_VALUE || value > ir->nvalues ||
        (size_t)value >= ir->type_capacity || type == NULL || ir->value_types == NULL) {
        return 0;
    }
    *type = ir->value_types[value];
    return tir_valid_type(*type);
}

int sp_tir_emit_phi(SpTraceIR *ir, SpTIRType type, SpTIRValue entry, SpTIRValue *out) {
    SpTIRType entry_type;
    if (ir == NULL || ir->body_started || !tir_valid_type(type) ||
        !tir_value_type(ir, entry, &entry_type) || entry_type != type) {
        return 0;
    }
    return tir_append(ir, SP_TIR_PHI, type, entry, SP_TIR_NO_VALUE,
                      0U, 0U, 1, out);
}

int sp_tir_set_phi_backedge(SpTraceIR *ir, SpTIRValue phi, SpTIRValue backedge) {
    SpTIRInst *phi_inst = NULL;
    SpTIRType backedge_type;
    if (ir == NULL || phi == SP_TIR_NO_VALUE || backedge == SP_TIR_NO_VALUE ||
        !tir_value_type(ir, backedge, &backedge_type)) {
        return 0;
    }
    for (size_t i = 0U; i < ir->count; i++) {
        if (ir->inst[i].dst == phi && ir->inst[i].op == SP_TIR_PHI) {
            phi_inst = &ir->inst[i];
            break;
        }
    }
    if (phi_inst == NULL || phi_inst->b != SP_TIR_NO_VALUE ||
        phi_inst->type != backedge_type) {
        return 0;
    }
    phi_inst->b = backedge;
    return 1;
}

static int tir_is_integer_binary(SpTIROp op) {
    return op == SP_TIR_IADD || op == SP_TIR_ISUB || op == SP_TIR_IMUL ||
           op == SP_TIR_IDIV || op == SP_TIR_IMOD ||
           op == SP_TIR_IAND || op == SP_TIR_IOR || op == SP_TIR_IXOR || op == SP_TIR_ISHL || op == SP_TIR_ISHR;
}

static int tir_is_float_binary(SpTIROp op) {
    return op == SP_TIR_FADD || op == SP_TIR_FSUB ||
           op == SP_TIR_FMUL || op == SP_TIR_FDIV;
}

static int tir_is_integer_compare(SpTIROp op) {
    return op >= SP_TIR_ICMP_EQ && op <= SP_TIR_ICMP_GE;
}

static int tir_is_float_compare(SpTIROp op) {
    return op >= SP_TIR_FCMP_EQ && op <= SP_TIR_FCMP_GE;
}

int sp_tir_emit_binary(SpTraceIR *ir, SpTIROp op, SpTIRValue a,
                       SpTIRValue b, SpTIRValue *out) {
    SpTIRType at, bt, result_type;
    if (!tir_value_type(ir, a, &at) || !tir_value_type(ir, b, &bt) || at != bt) {
        return 0;
    }
    if (tir_is_integer_binary(op) && at == SP_TIR_T_I64) {
        result_type = SP_TIR_T_I64;
    } else if (tir_is_float_binary(op) && at == SP_TIR_T_F64) {
        result_type = SP_TIR_T_F64;
    } else if ((tir_is_integer_compare(op) && at == SP_TIR_T_I64) ||
               (tir_is_float_compare(op) && at == SP_TIR_T_F64)) {
        result_type = SP_TIR_T_BOOL;
    } else {
        return 0;
    }
    return tir_append(ir, op, result_type, a, b, 0U, 0U, 1, out);
}

int sp_tir_emit_unary(SpTraceIR *ir, SpTIROp op, SpTIRValue a, SpTIRValue *out) {
    SpTIRType at;
    if (!tir_value_type(ir, a, &at)) return 0;
    if (op == SP_TIR_I2F) {
        if (at != SP_TIR_T_I64) return 0;
        return tir_append(ir, op, SP_TIR_T_F64, a, SP_TIR_NO_VALUE, 0U, 0U, 1, out);
    }
    if (!((op == SP_TIR_INEG && at == SP_TIR_T_I64) ||
          (op == SP_TIR_FNEG && at == SP_TIR_T_F64))) {
        return 0;
    }
    return tir_append(ir, op, at, a, SP_TIR_NO_VALUE, 0U, 0U, 1, out);
}

int sp_tir_emit_fcall(SpTraceIR *ir, SpTIROp op, uint64_t fn, unsigned aux, SpTIRValue a, SpTIRValue *out) {
    SpTIRType at;
    if ((op != SP_TIR_FCALL1 && op != SP_TIR_FSQRT && op != SP_TIR_FABS && op != SP_TIR_FFLOOR) || (op == SP_TIR_FCALL1 && fn == 0U) ||
        aux > 1U || !tir_value_type(ir, a, &at) || at != SP_TIR_T_F64) return 0;
    return tir_append(ir, op, op == SP_TIR_FFLOOR ? SP_TIR_T_I64 : SP_TIR_T_F64, a, SP_TIR_NO_VALUE, aux, op == SP_TIR_FCALL1 ? fn : 0U, 1, out);
}

int sp_tir_emit_guard(SpTraceIR *ir, SpTIRValue condition, uint32_t side_exit, unsigned flags) {
    SpTIRType type;
    if (side_exit == SP_TIR_NO_EXIT || flags > (SP_TIR_GUARD_DEOPT | SP_TIR_GUARD_INVERT | SP_TIR_GUARD_ENTRY) ||
        !tir_value_type(ir, condition, &type) || type != SP_TIR_T_BOOL) {
        return 0;
    }
    return tir_append(ir, SP_TIR_GUARD_TRUE, SP_TIR_T_BOOL, condition,
                      SP_TIR_NO_VALUE, side_exit, (uint64_t)flags, 0, NULL);
}
int sp_tir_emit_guard_true(SpTraceIR *ir, SpTIRValue condition, uint32_t side_exit) {
    return sp_tir_emit_guard(ir, condition, side_exit, 0U);
}

int sp_tir_emit_aload(SpTraceIR *ir, SpTIRType elem_type, uint8_t elem_tag, SpTIRValue array, SpTIRValue index, SpTIRValue *out) {
    SpTIRType ta, tb;
    if (!tir_value_type(ir, array, &ta) || ta != SP_TIR_T_REF || !tir_value_type(ir, index, &tb) || tb != SP_TIR_T_I64) return 0;
    return tir_append(ir, SP_TIR_ALOAD, elem_type, array, index, 0U, (uint64_t)elem_tag, 1, out);
}
int sp_tir_emit_astore(SpTraceIR *ir, SpTIRValue array, SpTIRValue index, SpTIRValue value) {
    SpTIRType ta, tb, tv;
    if (!tir_value_type(ir, array, &ta) || ta != SP_TIR_T_REF || !tir_value_type(ir, index, &tb) || tb != SP_TIR_T_I64 ||
        !tir_value_type(ir, value, &tv) || value == SP_TIR_NO_VALUE) return 0;
    return tir_append(ir, SP_TIR_ASTORE, tv, array, index, value, 0U, 0, NULL);
}

int sp_tir_emit_fload(SpTraceIR *ir, SpTIRType type, uint8_t tag, SpTIRValue object, uint32_t slot, SpTIRValue *out) {
    SpTIRType t;
    if (!tir_value_type(ir, object, &t) || t != SP_TIR_T_REF) return 0;
    return tir_append(ir, SP_TIR_FLOAD, type, object, SP_TIR_NO_VALUE, slot, (uint64_t)tag, 1, out);
}
int sp_tir_emit_fstore(SpTraceIR *ir, SpTIRValue object, uint32_t slot, SpTIRValue value) {
    SpTIRType t, tv;
    if (!tir_value_type(ir, object, &t) || t != SP_TIR_T_REF || !tir_value_type(ir, value, &tv) || value == SP_TIR_NO_VALUE) return 0;
    return tir_append(ir, SP_TIR_FSTORE, tv, object, SP_TIR_NO_VALUE, value, (uint64_t)slot, 0, NULL);
}
int sp_tir_emit_newinst(SpTraceIR *ir, uint64_t cls, SpTIRValue *out) {
    return tir_append(ir, SP_TIR_NEWINST, SP_TIR_T_REF, SP_TIR_NO_VALUE, SP_TIR_NO_VALUE, 0U, cls, 1, out);
}
int sp_tir_emit_fparam(SpTraceIR *ir, SpTIRType type, SpTIRValue object, uint32_t offset, uint64_t cls, SpTIRValue *out) {
    SpTIRType t;
    if (type != SP_TIR_T_I64 && type != SP_TIR_T_F64 && type != SP_TIR_T_BOOL) return 0;
    if (!tir_value_type(ir, object, &t) || t != SP_TIR_T_REF) return 0;
    return tir_append(ir, SP_TIR_PARAM, type, object, SP_TIR_NO_VALUE, offset, cls, 1, out);
}
int sp_tir_emit_vfield(SpTraceIR *ir, SpTIRValue object_phi, SpTIRValue field_phi, uint32_t offset, uint8_t tag) {
    return tir_append(ir, SP_TIR_VFIELD, SP_TIR_T_REF, object_phi, field_phi, offset, (uint64_t)tag, 0, NULL);
}
int sp_tir_mark_virtual(SpTraceIR *ir, SpTIRValue value, uint64_t cls) {
    for (size_t i = 0U; i < ir->count; i++) {
        SpTIRInst *in = &ir->inst[i];
        if (in->dst != value || (in->op != SP_TIR_PHI && in->op != SP_TIR_NEWINST)) continue;
        in->aux = 1U;
        if (in->op == SP_TIR_PHI) in->imm = cls;
        return 1;
    }
    return 0;
}
/* Loop-invariant array reads (`a[i]` where neither the array nor the index changes in the loop, and nothing in the trace stores into
 * an array) are moved to the entry, after the PHIs: they run once instead of every trip. Their constants move with them. The
 * instruction list is rebuilt in the new order and the values are renumbered. Returns the number of loads moved, or -1 on error. */
int sp_tir_hoist_loads(SpTraceIR *ir) {
    size_t n = ir->count, last_phi = 0U, nh = 0U, out = 0U;
    uint8_t *inv = NULL, *move = NULL;
    size_t *order = NULL;
    SpTIRValue *remap = NULL;
    SpTIRInst *copy = NULL;
    SpTIRType *types = NULL;
    int rc = -1;
    for (size_t i = 0U; i < n; i++) {
        if (ir->inst[i].op == SP_TIR_ASTORE) return 0;
        if (ir->inst[i].op == SP_TIR_PHI) last_phi = i;
    }
    inv = (uint8_t *)calloc((size_t)ir->nvalues + 1U, 1U);
    move = (uint8_t *)calloc(n, 1U);
    order = (size_t *)malloc(n * sizeof *order);
    remap = (SpTIRValue *)calloc((size_t)ir->nvalues + 1U, sizeof *remap);
    copy = (SpTIRInst *)malloc(n * sizeof *copy);
    types = (SpTIRType *)calloc(ir->type_capacity, sizeof *types);
    if (!inv || !move || !order || !remap || !copy || !types) goto done;
    for (size_t i = 0U; i < n; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op == SP_TIR_PHI && in->b == in->dst && in->aux == 0U) inv[in->dst] = 1U;
        else if (in->op == SP_TIR_CONST_I64 && i > last_phi) inv[in->dst] = 1U;
        else if (in->op == SP_TIR_ALOAD && i > last_phi && inv[in->a] && inv[in->b]) { inv[in->dst] = 1U; move[i] = 2U; nh++; }
    }
    if (nh == 0U) { rc = 0; goto done; }
    /* the constants a moved load uses move too (they are pure) */
    for (size_t i = 0U; i < n; i++)
        if (move[i] == 2U)
            for (size_t k = last_phi + 1U; k < i; k++)
                if (ir->inst[k].op == SP_TIR_CONST_I64 && (ir->inst[k].dst == ir->inst[i].b || ir->inst[k].dst == ir->inst[i].a)) move[k] = 1U;
    for (size_t i = 0U; i <= last_phi; i++) order[out++] = i;
    for (size_t i = last_phi + 1U; i < n; i++) if (move[i]) order[out++] = i;
    for (size_t i = last_phi + 1U; i < n; i++) if (!move[i]) order[out++] = i;
    {
        SpTIRValue next = 0U;
        for (size_t k = 0U; k < n; k++) {
            const SpTIRInst *in = &ir->inst[order[k]];
            if (in->dst != SP_TIR_NO_VALUE) remap[in->dst] = ++next;
        }
        for (size_t k = 0U; k < n; k++) {
            SpTIRInst in = ir->inst[order[k]];
            if (in.dst != SP_TIR_NO_VALUE) { types[remap[in.dst]] = ir->value_types[in.dst]; in.dst = remap[in.dst]; }
            if (in.a != SP_TIR_NO_VALUE) in.a = remap[in.a];
            if (in.b != SP_TIR_NO_VALUE) in.b = remap[in.b];
            if (in.op == SP_TIR_ASTORE || in.op == SP_TIR_FSTORE) in.aux = remap[in.aux];
            copy[k] = in;
        }
    }
    memcpy(ir->inst, copy, n * sizeof *copy);
    memcpy(ir->value_types, types, ir->type_capacity * sizeof *types);
    rc = (int)nh;
done:
    free(inv); free(move); free(order); free(remap); free(copy); free(types);
    return rc;
}

/* Bounds checks that a range loop makes redundant: for `for i in range(start, stop)` (step 1) the test `i < stop` precedes every use of
 * i as an index in the body, so `a[i]` with a loop-invariant array a is in range for the whole loop when stop <= len(a) and
 * start >= 0 -- two checks made once at the entry instead of one per trip. The loads are marked (aux = 1) and the entry guards are
 * inserted before the loop test. Returns the number of loads relieved, or -1 on error. */
int sp_tir_elide_bounds(SpTraceIR *ir) {
    size_t fc = ir->count, n = ir->count, found = 0U;
    SpTIRValue arrays[8], cur, stop;
    unsigned narr = 0U;
    const SpTIRInst *test, *add = NULL;
    for (size_t i = 0U; i + 1U < n; i++) {
        const SpTIROp o = ir->inst[i].op;
        if (o >= SP_TIR_ICMP_EQ && o <= SP_TIR_ICMP_GE && !(ir->inst[i + 1U].op == SP_TIR_GUARD_TRUE && (ir->inst[i + 1U].imm & SP_TIR_GUARD_ENTRY))) { fc = i; break; }
    }
    if (fc >= n - 1U) return 0;
    test = &ir->inst[fc];
    if (test->op != SP_TIR_ICMP_LT || ir->inst[fc + 1U].op != SP_TIR_GUARD_TRUE || (ir->inst[fc + 1U].imm & SP_TIR_GUARD_INVERT)) return 0;
    cur = test->a; stop = test->b;
    for (size_t i = 0U; i < n; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op == SP_TIR_PHI && in->dst == cur) {
            for (size_t k = 0U; k < n; k++) if (ir->inst[k].dst == in->b) add = &ir->inst[k];
            if (in->type != SP_TIR_T_I64 || add == NULL || add->op != SP_TIR_IADD || add->aux != 1U || add->a != cur) return 0;
            for (size_t k = 0U; k < n; k++) if (ir->inst[k].dst == add->b && (ir->inst[k].op != SP_TIR_CONST_I64 || ir->inst[k].imm != 1U)) return 0;
        }
    }
    if (add == NULL) return 0;
    for (size_t i = fc + 2U; i < n; i++) {
        SpTIRInst *in = &ir->inst[i];
        int invariant = 0;
        if (in->op != SP_TIR_ALOAD || in->b != cur || (in->aux & 1U)) continue;
        for (size_t k = 0U; k < fc && !invariant; k++) {
            const SpTIRInst *d = &ir->inst[k];
            if (d->dst != in->a) continue;
            invariant = (d->op == SP_TIR_PHI && d->b == d->dst) || d->op == SP_TIR_ALOAD;
        }
        if (!invariant) continue;
        in->aux |= 1U;
        found++;
        {
            unsigned u;
            for (u = 0U; u < narr && arrays[u] != in->a; u++) {}
            if (u == narr) { if (narr == 8U) return -1; arrays[narr++] = in->a; }
        }
    }
    if (found == 0U) return 0;
    if (!tir_reserve(ir, (size_t)narr + 1U)) return -1;
    memmove(&ir->inst[fc + narr + 1U], &ir->inst[fc], (n - fc) * sizeof ir->inst[0]);
    for (unsigned u = 0U; u < narr; u++) {
        SpTIRInst g;
        memset(&g, 0, sizeof g);
        g.op = SP_TIR_CGUARD; g.type = SP_TIR_T_REF; g.a = arrays[u]; g.b = stop; g.aux = 2U;
        ir->inst[fc + u] = g;
    }
    {
        SpTIRInst g;
        memset(&g, 0, sizeof g);
        g.op = SP_TIR_CGUARD; g.type = SP_TIR_T_I64; g.a = cur; g.b = SP_TIR_NO_VALUE; g.aux = 3U;
        ir->inst[fc + narr] = g;
    }
    ir->count = n + (size_t)narr + 1U;
    return (int)found;
}

/* Element tags that the array's own note settles: in a trace that stores into no array at all, a read from a loop-invariant array
 * needs no per-element type check once the array's note (Obj.xt) has been checked on entry. Marks such loads (aux bit 1) and
 * inserts the entry guards (CGUARD aux 4, imm = tag) before the first loop test. Returns the number of loads relieved. */
int sp_tir_elide_tags(SpTraceIR *ir) {
    size_t fc = ir->count, n = ir->count, found = 0U;
    SpTIRValue arrays[8];
    uint8_t tags[8];
    unsigned narr = 0U;
    for (size_t i = 0U; i < n; i++) if (ir->inst[i].op == SP_TIR_ASTORE) return 0;
    for (size_t i = 0U; i + 1U < n; i++) {
        const SpTIROp o = ir->inst[i].op;
        if (o >= SP_TIR_ICMP_EQ && o <= SP_TIR_ICMP_GE && !(ir->inst[i + 1U].op == SP_TIR_GUARD_TRUE && (ir->inst[i + 1U].imm & SP_TIR_GUARD_ENTRY))) { fc = i; break; }
    }
    if (fc >= n - 1U) return 0;
    for (size_t i = fc + 2U; i < n; i++) {
        SpTIRInst *in = &ir->inst[i];
        int invariant = 0;
        if (in->op != SP_TIR_ALOAD || (in->aux & 2U)) continue;
        for (size_t k = 0U; k < fc && !invariant; k++) {
            const SpTIRInst *d = &ir->inst[k];
            if (d->dst != in->a) continue;
            invariant = (d->op == SP_TIR_PHI && d->b == d->dst && d->aux == 0U) || d->op == SP_TIR_ALOAD;
        }
        if (!invariant) continue;
        {
            unsigned u;
            for (u = 0U; u < narr && !(arrays[u] == in->a && tags[u] == (uint8_t)in->imm); u++) {}
            if (u == narr) { if (narr == 8U) continue; arrays[narr] = in->a; tags[narr] = (uint8_t)in->imm; narr++; }
        }
        in->aux |= 2U;
        found++;
    }
    if (found == 0U) return 0;
    if (!tir_reserve(ir, (size_t)narr)) return -1;
    memmove(&ir->inst[fc + narr], &ir->inst[fc], (n - fc) * sizeof ir->inst[0]);
    for (unsigned u = 0U; u < narr; u++) {
        SpTIRInst g;
        memset(&g, 0, sizeof g);
        g.op = SP_TIR_CGUARD; g.type = SP_TIR_T_REF; g.a = arrays[u]; g.aux = 4U; g.imm = tags[u];
        ir->inst[fc + u] = g;
    }
    ir->count = n + narr;
    return (int)found;
}

int sp_tir_emit_sload(SpTraceIR *ir, SpTIRValue string, SpTIRValue index, SpTIRValue *out) {
    SpTIRType ts, ti;
    if (!tir_value_type(ir, string, &ts) || ts != SP_TIR_T_REF || !tir_value_type(ir, index, &ti) || ti != SP_TIR_T_I64) return 0;
    return tir_append(ir, SP_TIR_SLOAD, SP_TIR_T_I64, string, index, 0U, 0U, 1, out);
}
int sp_tir_emit_leafcall(SpTraceIR *ir, SpTIRType type, uint64_t fn, SpTIRValue a, SpTIRValue b, unsigned argc, SpTIRValue *out) {
    SpTIRType t;
    if ((type != SP_TIR_T_I64 && type != SP_TIR_T_BOOL) || (argc != 1U && argc != 2U) || fn == 0U ||
        !tir_value_type(ir, a, &t) || t != SP_TIR_T_I64) return 0;
    if (argc == 2U && (!tir_value_type(ir, b, &t) || t != SP_TIR_T_I64)) return 0;
    return tir_append(ir, SP_TIR_LEAFCALL, type, a, argc == 2U ? b : SP_TIR_NO_VALUE, argc, fn, 1, out);
}
int sp_tir_emit_ucell(SpTraceIR *ir, SpTIRValue fn, uint32_t idx, SpTIRValue *out) {
    SpTIRType t;
    if (!tir_value_type(ir, fn, &t) || t != SP_TIR_T_REF) return 0;
    return tir_append(ir, SP_TIR_UCELL, SP_TIR_T_REF, fn, SP_TIR_NO_VALUE, idx, 0U, 1, out);
}
int sp_tir_emit_rguard(SpTraceIR *ir, SpTIRValue ref, uint64_t ptr) {
    SpTIRType t;
    if (!tir_value_type(ir, ref, &t) || t != SP_TIR_T_REF) return 0;
    return tir_append(ir, SP_TIR_CGUARD, SP_TIR_T_REF, ref, SP_TIR_NO_VALUE, 1U, ptr, 0, NULL);
}
int sp_tir_emit_cguard(SpTraceIR *ir, SpTIRValue object, uint64_t cls) {
    SpTIRType t;
    if (!tir_value_type(ir, object, &t) || t != SP_TIR_T_REF) return 0;
    return tir_append(ir, SP_TIR_CGUARD, SP_TIR_T_REF, object, SP_TIR_NO_VALUE, 0U, cls, 0, NULL);
}

int sp_tir_emit_loop(SpTraceIR *ir) {
    return tir_append(ir, SP_TIR_LOOP, SP_TIR_T_REF, SP_TIR_NO_VALUE,
                      SP_TIR_NO_VALUE, 0U, 0U, 0, NULL);
}

int sp_tir_emit_return(SpTraceIR *ir, SpTIRValue value) {
    SpTIRType type;
    if (!tir_value_type(ir, value, &type)) return 0;
    return tir_append(ir, SP_TIR_RETURN, type, value, SP_TIR_NO_VALUE,
                      0U, 0U, 0, NULL);
}

static int tir_value_defined_before(const size_t *defs, uint32_t value,
                                    size_t pc, size_t nvalues) {
    return value != SP_TIR_NO_VALUE && (size_t)value <= nvalues &&
           defs[value] != SIZE_MAX && defs[value] < pc;
}

static int tir_fail(char *message, size_t message_size, const char *text) {
    tir_error(message, message_size, text);
    return 0;
}

int sp_tir_verify(const SpTraceIR *ir, char *message, size_t message_size) {
    size_t *defs = NULL;
    SpTIRType *types = NULL;
    size_t ndefs = 0U;
    int body_started = 0;
    int terminated = 0;
    int ok = 0;

    if (message != NULL && message_size != 0U) message[0] = '\0';
    if (ir == NULL || ir->inst == NULL || ir->count == 0U ||
        ir->count > (size_t)SP_TIR_MAX_INST || ir->count > ir->capacity ||
        (ir->nvalues != 0U && (ir->value_types == NULL ||
         (size_t)ir->nvalues >= ir->type_capacity))) {
        return tir_fail(message, message_size, "empty, malformed, or oversized IR storage");
    }
    if ((size_t)ir->nvalues > ir->count) {
        return tir_fail(message, message_size, "SSA value count exceeds instruction count");
    }
    defs = (size_t *)malloc(((size_t)ir->nvalues + 1U) * sizeof *defs);
    types = (SpTIRType *)malloc(((size_t)ir->nvalues + 1U) * sizeof *types);
    if (defs == NULL || types == NULL) {
        tir_error(message, message_size, "out of memory while verifying IR");
        goto done;
    }
    for (size_t i = 0U; i <= (size_t)ir->nvalues; i++) defs[i] = SIZE_MAX;

    /* First pass: unique SSA definitions, valid opcodes/types, PHI prefix, terminator. */
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        int has_result = in->op != SP_TIR_GUARD_TRUE && in->op != SP_TIR_ASTORE && in->op != SP_TIR_FSTORE &&
                         in->op != SP_TIR_CGUARD && in->op != SP_TIR_VFIELD && in->op != SP_TIR_LOOP && in->op != SP_TIR_RETURN;
        if (terminated) {
            tir_error(message, message_size, "instruction appears after terminator");
            goto done;
        }
        if (in->op < SP_TIR_PARAM || in->op > SP_TIR_RETURN || !tir_valid_type(in->type)) {
            tir_error(message, message_size, "invalid opcode or result type");
            goto done;
        }
        if (in->op == SP_TIR_PHI) {
            if (body_started) {
                tir_error(message, message_size, "PHI appears after trace body begins");
                goto done;
            }
        } else if (in->op != SP_TIR_PARAM && in->op != SP_TIR_CONST_I64 &&
                   in->op != SP_TIR_CONST_F64 && in->op != SP_TIR_CONST_BOOL) {
            body_started = 1;
        }
        if (has_result) {
            if (in->dst == SP_TIR_NO_VALUE || (size_t)in->dst > (size_t)ir->nvalues ||
                (size_t)in->dst != ndefs + 1U || defs[in->dst] != SIZE_MAX) {
                tir_error(message, message_size, "missing, duplicate, or non-sequential SSA definition");
                goto done;
            }
            defs[in->dst] = i;
            types[in->dst] = in->type;
            ndefs++;
        } else if (in->dst != SP_TIR_NO_VALUE) {
            tir_error(message, message_size, "non-value instruction has an SSA destination");
            goto done;
        }
        if (in->op == SP_TIR_LOOP || in->op == SP_TIR_RETURN) terminated = 1;
    }
    if (!terminated) {
        tir_error(message, message_size, "trace has no loop or return terminator");
        goto done;
    }
    if (ndefs != (size_t)ir->nvalues) {
        tir_error(message, message_size, "SSA value count does not match definitions");
        goto done;
    }
    for (uint32_t value = 1U; value <= ir->nvalues; value++) {
        if (ir->value_types[value] != types[value]) {
            tir_error(message, message_size, "SSA type table disagrees with definitions");
            goto done;
        }
    }

    /* Second pass: validate operands and ensure non-PHI uses are dominated in trace order. */
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        SpTIRType expected = in->type;
        switch (in->op) {
        case SP_TIR_PARAM:
            if (in->a != SP_TIR_NO_VALUE && in->type != SP_TIR_T_REF && in->b == SP_TIR_NO_VALUE &&
                tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) && types[in->a] == SP_TIR_T_REF) break;   /* a field of a sunk object */
            if (in->a != SP_TIR_NO_VALUE || in->b != SP_TIR_NO_VALUE ||
                (in->type == SP_TIR_T_REF ? in->aux > SP_TIR_RUNTIME_TYPE_MAX : in->aux != 0U)) {
                tir_error(message, message_size, "malformed parameter instruction");
                goto done;
            }
            break;
        case SP_TIR_CONST_I64:
            if (expected != SP_TIR_T_I64 || in->a != SP_TIR_NO_VALUE ||
                in->b != SP_TIR_NO_VALUE || in->aux != 0U) {
                tir_error(message, message_size, "malformed i64 constant");
                goto done;
            }
            break;
        case SP_TIR_CONST_F64:
            if (expected != SP_TIR_T_F64 || in->a != SP_TIR_NO_VALUE ||
                in->b != SP_TIR_NO_VALUE || in->aux != 0U) {
                tir_error(message, message_size, "malformed f64 constant");
                goto done;
            }
            break;
        case SP_TIR_CONST_BOOL:
            if (expected != SP_TIR_T_BOOL || in->a != SP_TIR_NO_VALUE ||
                in->b != SP_TIR_NO_VALUE || in->aux != 0U || in->imm > 1U) {
                tir_error(message, message_size, "malformed boolean constant");
                goto done;
            }
            break;
        case SP_TIR_PHI:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                in->b == SP_TIR_NO_VALUE || (size_t)in->b > (size_t)ir->nvalues ||
                defs[in->b] == SIZE_MAX ||
                (defs[in->b] < i && ir->inst[defs[in->b]].op != SP_TIR_PHI) ||
                types[in->a] != expected || types[in->b] != expected) {
                tir_error(message, message_size, "invalid PHI entry/back-edge inputs");
                goto done;
            }
            break;
        case SP_TIR_IADD:
        case SP_TIR_ISUB:
        case SP_TIR_IMUL:
        case SP_TIR_IDIV:
        case SP_TIR_IMOD:
        case SP_TIR_IAND: case SP_TIR_IOR: case SP_TIR_IXOR: case SP_TIR_ISHL: case SP_TIR_ISHR:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                !tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_I64 || types[in->b] != SP_TIR_T_I64 ||
                expected != SP_TIR_T_I64) {
                tir_error(message, message_size, "invalid integer binary operands");
                goto done;
            }
            break;
        case SP_TIR_FADD:
        case SP_TIR_FSUB:
        case SP_TIR_FMUL:
        case SP_TIR_FDIV:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                !tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_F64 || types[in->b] != SP_TIR_T_F64 ||
                expected != SP_TIR_T_F64) {
                tir_error(message, message_size, "invalid floating-point binary operands");
                goto done;
            }
            break;
        case SP_TIR_INEG:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_I64 || expected != SP_TIR_T_I64) {
                tir_error(message, message_size, "invalid integer unary operand");
                goto done;
            }
            break;
        case SP_TIR_FNEG:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_F64 || expected != SP_TIR_T_F64) {
                tir_error(message, message_size, "invalid floating-point unary operand");
                goto done;
            }
            break;
        case SP_TIR_FCALL1:
        case SP_TIR_FSQRT:
        case SP_TIR_FABS:
        case SP_TIR_FFLOOR:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_F64 || expected != (in->op == SP_TIR_FFLOOR ? SP_TIR_T_I64 : SP_TIR_T_F64)) {
                tir_error(message, message_size, "invalid float function operand");
                goto done;
            }
            break;
        case SP_TIR_I2F:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_I64 || expected != SP_TIR_T_F64) {
                tir_error(message, message_size, "invalid int-to-float operand");
                goto done;
            }
            break;
        case SP_TIR_ICMP_EQ:
        case SP_TIR_ICMP_NE:
        case SP_TIR_ICMP_LT:
        case SP_TIR_ICMP_LE:
        case SP_TIR_ICMP_GT:
        case SP_TIR_ICMP_GE:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                !tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_I64 || types[in->b] != SP_TIR_T_I64 ||
                expected != SP_TIR_T_BOOL) {
                tir_error(message, message_size, "invalid integer comparison operands");
                goto done;
            }
            break;
        case SP_TIR_FCMP_EQ:
        case SP_TIR_FCMP_NE:
        case SP_TIR_FCMP_LT:
        case SP_TIR_FCMP_LE:
        case SP_TIR_FCMP_GT:
        case SP_TIR_FCMP_GE:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                !tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_F64 || types[in->b] != SP_TIR_T_F64 ||
                expected != SP_TIR_T_BOOL) {
                tir_error(message, message_size, "invalid floating-point comparison operands");
                goto done;
            }
            break;
        case SP_TIR_GUARD_TRUE:
            if (expected != SP_TIR_T_BOOL ||
                !tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                types[in->a] != SP_TIR_T_BOOL || in->aux == SP_TIR_NO_EXIT ||
                in->imm > (uint64_t)(SP_TIR_GUARD_DEOPT | SP_TIR_GUARD_INVERT | SP_TIR_GUARD_ENTRY)) {
                tir_error(message, message_size, "invalid guard condition or side-exit id");
                goto done;
            }
            break;
        case SP_TIR_ALOAD:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_REF ||
                !tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) || types[in->b] != SP_TIR_T_I64 ||
                in->imm > 255U) {
                tir_error(message, message_size, "invalid array load operands");
                goto done;
            }
            break;
        case SP_TIR_NEWINST:
            break;
        case SP_TIR_VFIELD:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_REF ||
                in->b == SP_TIR_NO_VALUE || (size_t)in->b > (size_t)ir->nvalues || defs[in->b] == SIZE_MAX) {
                tir_error(message, message_size, "invalid sunk-object field");
                goto done;
            }
            break;
        case SP_TIR_SLOAD:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_REF ||
                !tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) || types[in->b] != SP_TIR_T_I64 || expected != SP_TIR_T_I64) {
                tir_error(message, message_size, "invalid string load operands");
                goto done;
            }
            break;
        case SP_TIR_LEAFCALL:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_I64 ||
                (in->aux == 2U && (!tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) || types[in->b] != SP_TIR_T_I64)) ||
                (in->aux != 1U && in->aux != 2U) || (expected != SP_TIR_T_I64 && expected != SP_TIR_T_BOOL)) {
                tir_error(message, message_size, "invalid leaf call operands");
                goto done;
            }
            break;
        case SP_TIR_UCELL:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_REF) {
                tir_error(message, message_size, "invalid upvalue operand");
                goto done;
            }
            break;
        case SP_TIR_FLOAD:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_REF || in->imm > 255U) {
                tir_error(message, message_size, "invalid field load operands");
                goto done;
            }
            break;
        case SP_TIR_FSTORE:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_REF ||
                !tir_value_defined_before(defs, in->aux, i, (size_t)ir->nvalues) || types[in->aux] != in->type) {
                tir_error(message, message_size, "invalid field store operands");
                goto done;
            }
            break;
        case SP_TIR_CGUARD:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != (in->aux == 3U ? SP_TIR_T_I64 : SP_TIR_T_REF) ||
                (in->aux == 2U && (!tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) || types[in->b] != SP_TIR_T_I64))) {
                tir_error(message, message_size, "invalid class guard operand");
                goto done;
            }
            break;
        case SP_TIR_ASTORE:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) || types[in->a] != SP_TIR_T_REF ||
                !tir_value_defined_before(defs, in->b, i, (size_t)ir->nvalues) || types[in->b] != SP_TIR_T_I64 ||
                !tir_value_defined_before(defs, in->aux, i, (size_t)ir->nvalues) || types[in->aux] != in->type) {
                tir_error(message, message_size, "invalid array store operands");
                goto done;
            }
            break;
        case SP_TIR_LOOP:
            if (in->type != SP_TIR_T_REF || in->a != SP_TIR_NO_VALUE ||
                in->b != SP_TIR_NO_VALUE || in->aux != 0U) {
                tir_error(message, message_size, "malformed loop terminator");
                goto done;
            }
            break;
        case SP_TIR_RETURN:
            if (!tir_value_defined_before(defs, in->a, i, (size_t)ir->nvalues) ||
                types[in->a] != expected) {
                tir_error(message, message_size, "invalid return value");
                goto done;
            }
            break;
        default:
            tir_error(message, message_size, "unknown opcode during operand validation");
            goto done;
        }
    }
    ok = 1;
    tir_error(message, message_size, "ok");

done:
    free(types);
    free(defs);
    return ok;
}

/* Checked integer helpers: folding must preserve runtime overflow/error behavior. */
static int tir_i64_add_checked(int64_t a, int64_t b, int64_t *out) {
    if ((b > 0 && a > INT64_MAX - b) ||
        (b < 0 && a < INT64_MIN - b)) return 0;
    *out = a + b;
    return 1;
}

static int tir_i64_sub_checked(int64_t a, int64_t b, int64_t *out) {
    if ((b < 0 && a > INT64_MAX + b) ||
        (b > 0 && a < INT64_MIN + b)) return 0;
    *out = a - b;
    return 1;
}

static int tir_i64_mul_checked(int64_t a, int64_t b, int64_t *out) {
    if (a == 0 || b == 0) {
        *out = 0;
        return 1;
    }
    if ((a == -1 && b == INT64_MIN) || (b == -1 && a == INT64_MIN)) return 0;
    if (a > 0) {
        if ((b > 0 && a > INT64_MAX / b) ||
            (b < 0 && b < INT64_MIN / a)) return 0;
    } else {
        if ((b > 0 && a < INT64_MIN / b) ||
            (b < 0 && a < INT64_MAX / b)) return 0;
    }
    *out = a * b;
    return 1;
}

static int tir_i64_eval_binary(SpTIROp op, int64_t a, int64_t b, int64_t *out) {
    int64_t remainder;
    switch (op) {
    case SP_TIR_IADD:
        return tir_i64_add_checked(a, b, out);
    case SP_TIR_ISUB:
        return tir_i64_sub_checked(a, b, out);
    case SP_TIR_IMUL:
        return tir_i64_mul_checked(a, b, out);
    case SP_TIR_IDIV:
        if (b == 0 || (a == INT64_MIN && b == -1)) return 0;
        *out = a / b;
        remainder = a % b;
        if (remainder != 0 && ((a < 0) != (b < 0))) (*out)--;
        return 1;
    case SP_TIR_IMOD:
        if (b == 0) return 0;
        if (b == -1) {
            *out = 0;
            return 1;
        }
        *out = a % b;
        if (*out != 0 && ((*out < 0) != (b < 0))) *out += b;
        return 1;
    case SP_TIR_IAND: *out = a & b; return 1;
    case SP_TIR_IOR: *out = a | b; return 1;
    case SP_TIR_IXOR: *out = a ^ b; return 1;
    case SP_TIR_ISHL:
        if (b < 0 || b > 63) return 0;
        *out = (int64_t)((uint64_t)a << b);
        return 1;
    case SP_TIR_ISHR:
        if (b < 0 || b > 63) return 0;
        *out = a >> b;
        return 1;
    case SP_TIR_PARAM: case SP_TIR_CONST_I64: case SP_TIR_CONST_F64:
    case SP_TIR_CONST_BOOL: case SP_TIR_PHI: case SP_TIR_INEG: case SP_TIR_I2F: case SP_TIR_FCALL1: case SP_TIR_FSQRT: case SP_TIR_FABS: case SP_TIR_FFLOOR:
    case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL: case SP_TIR_FDIV:
    case SP_TIR_FNEG: case SP_TIR_ICMP_EQ: case SP_TIR_ICMP_NE:
    case SP_TIR_ICMP_LT: case SP_TIR_ICMP_LE: case SP_TIR_ICMP_GT:
    case SP_TIR_ICMP_GE: case SP_TIR_FCMP_EQ: case SP_TIR_FCMP_NE:
    case SP_TIR_FCMP_LT: case SP_TIR_FCMP_LE: case SP_TIR_FCMP_GT:
    case SP_TIR_FCMP_GE: case SP_TIR_GUARD_TRUE: case SP_TIR_ALOAD: case SP_TIR_ASTORE: case SP_TIR_FLOAD: case SP_TIR_VFIELD: case SP_TIR_SLOAD: case SP_TIR_LEAFCALL: case SP_TIR_UCELL: case SP_TIR_NEWINST: case SP_TIR_FSTORE: case SP_TIR_CGUARD: case SP_TIR_LOOP:
    case SP_TIR_RETURN:
        return 0;
    default:
        return 0;
    }
}

static int tir_i64_eval_compare(SpTIROp op, int64_t a, int64_t b, int *out) {
    switch (op) {
    case SP_TIR_ICMP_EQ: *out = (a == b); return 1;
    case SP_TIR_ICMP_NE: *out = (a != b); return 1;
    case SP_TIR_ICMP_LT: *out = (a < b); return 1;
    case SP_TIR_ICMP_LE: *out = (a <= b); return 1;
    case SP_TIR_ICMP_GT: *out = (a > b); return 1;
    case SP_TIR_ICMP_GE: *out = (a >= b); return 1;
    case SP_TIR_PARAM: case SP_TIR_CONST_I64: case SP_TIR_CONST_F64:
    case SP_TIR_CONST_BOOL: case SP_TIR_PHI: case SP_TIR_IADD:
    case SP_TIR_ISUB: case SP_TIR_IMUL: case SP_TIR_IDIV: case SP_TIR_IMOD:
    case SP_TIR_INEG: case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL:
    case SP_TIR_FDIV: case SP_TIR_FNEG: case SP_TIR_FCMP_EQ:
    case SP_TIR_FCMP_NE: case SP_TIR_FCMP_LT: case SP_TIR_FCMP_LE:
    case SP_TIR_FCMP_GT: case SP_TIR_FCMP_GE: case SP_TIR_GUARD_TRUE:
    case SP_TIR_ALOAD: case SP_TIR_ASTORE: case SP_TIR_FLOAD: case SP_TIR_VFIELD: case SP_TIR_SLOAD: case SP_TIR_LEAFCALL: case SP_TIR_UCELL: case SP_TIR_NEWINST: case SP_TIR_FSTORE: case SP_TIR_IAND: case SP_TIR_IOR: case SP_TIR_IXOR: case SP_TIR_ISHL: case SP_TIR_ISHR: case SP_TIR_I2F: case SP_TIR_FCALL1: case SP_TIR_FSQRT: case SP_TIR_FABS: case SP_TIR_FFLOOR: case SP_TIR_CGUARD: case SP_TIR_LOOP: case SP_TIR_RETURN:
        return 0;
    default: return 0;
    }
}

static int tir_i64_from_bits(uint64_t bits, int64_t *out) {
    if (out == NULL) return 0;
    memcpy(out, &bits, sizeof *out);
    return 1;
}

static void tir_rewrite_constant(SpTIRInst *in, SpTIROp op,
                                 SpTIRType type, int64_t value) {
    in->op = op;
    in->type = type;
    in->a = SP_TIR_NO_VALUE;
    in->b = SP_TIR_NO_VALUE;
    in->aux = 0U;
    in->imm = (uint64_t)value;
}

/*
 * Fold integer-only constant expressions in SSA order.  Floating-point
 * operations deliberately remain untouched to preserve NaN, signed-zero and
 * floating-environment behavior.  Operations that would raise a runtime
 * arithmetic error (division by zero or signed overflow) are not folded.
 * The pass is transactional: malformed IR or allocation/verification failure
 * leaves the caller's instruction stream unchanged.
 */
int sp_tir_constant_fold(SpTraceIR *ir, size_t *folded_count) {
    uint8_t *known = NULL;
    int64_t *constants = NULL;
    SpTIRInst *backup = NULL;
    size_t folded = 0U;
    size_t value_slots;
    char verify_message[128];
    int result = 0;

    if (folded_count != NULL) *folded_count = 0U;
    if (ir == NULL || !sp_tir_verify(ir, verify_message, sizeof verify_message)) return 0;
    value_slots = (size_t)ir->nvalues + 1U;
    if (value_slots > SIZE_MAX / sizeof *constants ||
        ir->count > SIZE_MAX / sizeof *backup) return 0;

    known = (uint8_t *)calloc(value_slots, sizeof *known);
    constants = (int64_t *)calloc(value_slots, sizeof *constants);
    backup = (SpTIRInst *)malloc(ir->count * sizeof *backup);
    if (known == NULL || constants == NULL || backup == NULL) goto done;
    memcpy(backup, ir->inst, ir->count * sizeof *backup);

    for (size_t i = 0U; i < ir->count; i++) {
        SpTIRInst *in = &ir->inst[i];
        int64_t value = 0;
        int can_fold = 0;

        if (in->op == SP_TIR_CONST_I64 || in->op == SP_TIR_CONST_BOOL) {
            (void)tir_i64_from_bits(in->imm, &constants[in->dst]);
            known[in->dst] = 1U;
            continue;
        }

        if (in->op == SP_TIR_INEG && known[in->a] != 0U) {
            int64_t operand = constants[in->a];
            if (operand != INT64_MIN) {
                value = -operand;
                can_fold = 1;
            }
        } else if (tir_is_integer_binary(in->op) &&
                   known[in->a] != 0U && known[in->b] != 0U) {
            can_fold = tir_i64_eval_binary(in->op, constants[in->a],
                                           constants[in->b], &value);
        } else if (tir_is_integer_compare(in->op) &&
                   known[in->a] != 0U && known[in->b] != 0U) {
            int boolean_value = 0;
            if (tir_i64_eval_compare(in->op, constants[in->a],
                                     constants[in->b], &boolean_value)) {
                value = (int64_t)boolean_value;
                in->op = SP_TIR_CONST_BOOL;
                can_fold = 1;
            }
        }

        if (can_fold) {
            SpTIROp replacement = in->type == SP_TIR_T_BOOL ?
                                  SP_TIR_CONST_BOOL : SP_TIR_CONST_I64;
            tir_rewrite_constant(in, replacement, in->type, value);
            constants[in->dst] = value;
            known[in->dst] = 1U;
            folded++;
        }
    }

    if (!sp_tir_verify(ir, verify_message, sizeof verify_message)) {
        memcpy(ir->inst, backup, ir->count * sizeof *backup);
        goto done;
    }
    result = 1;
    if (folded_count != NULL) *folded_count = folded;

done:
    free(backup);
    free(constants);
    free(known);
    return result;
}

/*
 * Run the trace-IR scalar passes as one transaction. Constant folding is
 * followed by SSA dead-code elimination; PHI nodes (loop state that must be
 * materialized on side exit), guards, loops and returns are observable and are
 * always retained. PHI entry and back-edge operands are both marked live, then
 * all surviving SSA values are densely renumbered.
 */
/* Common subexpressions: an instruction that repeats an earlier pure one (same operation, operands, type and immediates) is dropped and its
 * result replaced by the earlier value. A failure the duplicate could have raised (overflow, a zero divisor) was already raised by the first
 * one; comparisons are left alone (the backend wants each fused with its own guard), as are loads. `dup[i]` marks dropped instructions. */
static int tir_cse_op(SpTIROp op) {
    switch (op) {
    case SP_TIR_CONST_I64: case SP_TIR_CONST_F64: case SP_TIR_IADD: case SP_TIR_ISUB: case SP_TIR_IMUL: case SP_TIR_IDIV: case SP_TIR_IMOD:
    case SP_TIR_INEG: case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL: case SP_TIR_FDIV: case SP_TIR_FNEG: case SP_TIR_I2F:
    case SP_TIR_FCALL1: case SP_TIR_FSQRT: case SP_TIR_FABS: case SP_TIR_FFLOOR: case SP_TIR_IAND: case SP_TIR_IOR: case SP_TIR_IXOR: case SP_TIR_ISHL: case SP_TIR_ISHR:
        return 1;
    case SP_TIR_PARAM: case SP_TIR_CONST_BOOL: case SP_TIR_PHI: case SP_TIR_ICMP_EQ: case SP_TIR_ICMP_NE: case SP_TIR_ICMP_LT:
    case SP_TIR_ICMP_LE: case SP_TIR_ICMP_GT: case SP_TIR_ICMP_GE: case SP_TIR_FCMP_EQ: case SP_TIR_FCMP_NE: case SP_TIR_FCMP_LT:
    case SP_TIR_FCMP_LE: case SP_TIR_FCMP_GT: case SP_TIR_FCMP_GE: case SP_TIR_GUARD_TRUE: case SP_TIR_ALOAD: case SP_TIR_ASTORE:
    case SP_TIR_FLOAD: case SP_TIR_FSTORE: case SP_TIR_NEWINST: case SP_TIR_SLOAD: case SP_TIR_LEAFCALL: case SP_TIR_UCELL:
    case SP_TIR_VFIELD: case SP_TIR_CGUARD: case SP_TIR_LOOP: case SP_TIR_RETURN:
    default:
        return 0;
    }
}
static int tir_cse_commutes(SpTIROp op) {
    return op == SP_TIR_IADD || op == SP_TIR_IMUL || op == SP_TIR_FADD || op == SP_TIR_FMUL ||
           op == SP_TIR_IAND || op == SP_TIR_IOR || op == SP_TIR_IXOR;
}
static void tir_cse(SpTraceIR *ir, uint8_t *dup, SpTIRValue *rep) {
    /* Code before the loop label (the entry guards and what they read) runs once, and its registers are not kept across iterations: only
     * the loop body, from the first comparison that is not an entry guard, takes part. */
    size_t body = ir->count;
    for (size_t i = 0U; i + 1U < ir->count && body == ir->count; i++) {
        const SpTIROp o = ir->inst[i].op;
        if (o >= SP_TIR_ICMP_EQ && o <= SP_TIR_FCMP_GE && !(ir->inst[i + 1U].op == SP_TIR_GUARD_TRUE && (ir->inst[i + 1U].imm & SP_TIR_GUARD_ENTRY) != 0U)) body = i;
    }
    for (size_t i = 0U; i < ir->count; i++) {
        SpTIRInst *in = &ir->inst[i];
        if (in->a != SP_TIR_NO_VALUE && rep[in->a] != SP_TIR_NO_VALUE) in->a = rep[in->a];
        if (in->b != SP_TIR_NO_VALUE && rep[in->b] != SP_TIR_NO_VALUE && in->op != SP_TIR_PHI) in->b = rep[in->b];
        if (i < body || !tir_cse_op(in->op) || in->op == SP_TIR_CONST_I64 || in->op == SP_TIR_CONST_F64 || in->dst == SP_TIR_NO_VALUE) continue;
        for (size_t j = body; j < i; j++) {
            const SpTIRInst *o = &ir->inst[j];
            if (dup[j] != 0U || o->op != in->op || o->type != in->type || o->imm != in->imm || o->aux != in->aux || o->dst == SP_TIR_NO_VALUE) continue;
            if ((o->a == in->a && o->b == in->b) || (tir_cse_commutes(in->op) && o->a == in->b && o->b == in->a)) {
                dup[i] = 1U;
                rep[in->dst] = o->dst;
                break;
            }
        }
    }
    for (size_t i = 0U; i < ir->count; i++) {   /* uses that precede the rewriting (PHI back-edges refer forward) */
        SpTIRInst *in = &ir->inst[i];
        if (in->a != SP_TIR_NO_VALUE && rep[in->a] != SP_TIR_NO_VALUE) in->a = rep[in->a];
        if (in->b != SP_TIR_NO_VALUE && rep[in->b] != SP_TIR_NO_VALUE) in->b = rep[in->b];
        if ((in->op == SP_TIR_ASTORE || in->op == SP_TIR_FSTORE) && in->aux != SP_TIR_NO_VALUE && rep[in->aux] != SP_TIR_NO_VALUE) in->aux = rep[in->aux];
    }
}

int sp_tir_optimize(SpTraceIR *ir, size_t *folded_count, size_t *removed_count) {
    SpTIRInst *backup = NULL;
    SpTIRInst *compact = NULL;
    SpTIRType *types_backup = NULL;
    uint8_t *live = NULL;
    uint8_t *keep = NULL;
    uint8_t *dup = NULL;
    SpTIRValue *remap = NULL, *rep = NULL;
    size_t old_count;
    uint32_t old_nvalues;
    size_t folded = 0U;
    size_t out_count = 0U;
    uint32_t new_nvalues = 0U;
    size_t value_slots;
    size_t type_slots;
    char verify_message[128];
    int ok = 0;

    if (folded_count != NULL) *folded_count = 0U;
    if (removed_count != NULL) *removed_count = 0U;
    if (ir == NULL || !sp_tir_verify(ir, verify_message, sizeof verify_message)) return 0;
    old_count = ir->count;
    old_nvalues = ir->nvalues;
    value_slots = (size_t)old_nvalues + 1U;
    type_slots = ir->type_capacity;
    if (type_slots < value_slots || old_count > SIZE_MAX / sizeof *backup ||
        type_slots > SIZE_MAX / sizeof *types_backup ||
        value_slots > SIZE_MAX / sizeof *remap) return 0;

    backup = (SpTIRInst *)malloc(old_count * sizeof *backup);
    compact = (SpTIRInst *)malloc(old_count * sizeof *compact);
    types_backup = (SpTIRType *)malloc(type_slots * sizeof *types_backup);
    live = (uint8_t *)calloc(value_slots, sizeof *live);
    keep = (uint8_t *)calloc(old_count, sizeof *keep);
    remap = (SpTIRValue *)calloc(value_slots, sizeof *remap);
    rep = (SpTIRValue *)calloc(value_slots, sizeof *rep);
    dup = (uint8_t *)calloc(old_count, sizeof *dup);
    if (backup == NULL || compact == NULL || types_backup == NULL ||
        live == NULL || keep == NULL || remap == NULL || rep == NULL || dup == NULL) goto done;

    memcpy(backup, ir->inst, old_count * sizeof *backup);
    memcpy(types_backup, ir->value_types, type_slots * sizeof *types_backup);
    if (!sp_tir_constant_fold(ir, &folded)) goto rollback;
    tir_cse(ir, dup, rep);

    /* PHI back-edges can refer to definitions later in the instruction
     * stream. A single reverse walk can therefore miss transitive uses that
     * are reachable only through a loop-carried value. Iterate to a fixed
     * point so every definition reachable from an observable root is kept. */
    {
        int changed;
        do {
            changed = 0;
            for (size_t i = 0U; i < ir->count; i++) {
                const SpTIRInst *in = &ir->inst[i];
                if (dup[i] != 0U) continue;   /* a repeated computation (tir_cse): nothing uses its result any more */
                /* Instructions that can fail (an overflow, a zero divisor, an index outside the array) stay even when their result is
                 * unused: the failure deoptimises, and the interpreter then raises the error the program must see. */
                int observable = in->op == SP_TIR_PHI ||
                                in->op == SP_TIR_GUARD_TRUE || in->op == SP_TIR_ASTORE || in->op == SP_TIR_ALOAD ||
                                in->op == SP_TIR_FLOAD || in->op == SP_TIR_FSTORE || in->op == SP_TIR_CGUARD || in->op == SP_TIR_VFIELD ||
                                in->op == SP_TIR_SLOAD || in->op == SP_TIR_LEAFCALL ||
                                in->op == SP_TIR_IADD || in->op == SP_TIR_ISUB || in->op == SP_TIR_IMUL || in->op == SP_TIR_INEG ||
                                in->op == SP_TIR_IDIV || in->op == SP_TIR_IMOD || in->op == SP_TIR_FDIV ||
                                in->op == SP_TIR_ISHL || in->op == SP_TIR_ISHR || in->op == SP_TIR_FSQRT || in->op == SP_TIR_FFLOOR || (in->op == SP_TIR_FCALL1 && in->aux == 1U) ||
                                in->op == SP_TIR_LOOP || in->op == SP_TIR_RETURN;
                int value_needed = in->dst != SP_TIR_NO_VALUE && live[in->dst] != 0U;
                if (observable || value_needed) {
                    if (keep[i] == 0U) {
                        keep[i] = 1U;
                        changed = 1;
                    }
                    if (in->a != SP_TIR_NO_VALUE && live[in->a] == 0U) {
                        live[in->a] = 1U;
                        changed = 1;
                    }
                    if (in->b != SP_TIR_NO_VALUE && live[in->b] == 0U) {
                        live[in->b] = 1U;
                        changed = 1;
                    }
                    if ((in->op == SP_TIR_ASTORE || in->op == SP_TIR_FSTORE) && in->aux != SP_TIR_NO_VALUE && live[in->aux] == 0U) {
                        live[in->aux] = 1U;
                        changed = 1;
                    }
                }
            }
        } while (changed);
    }

    /* Assign every surviving definition first so forward PHI back-edges can
     * be remapped even though their defining instruction appears later. */
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (keep[i] != 0U && in->dst != SP_TIR_NO_VALUE) {
            if (in->dst > old_nvalues || new_nvalues == UINT32_MAX) goto rollback;
            new_nvalues++;
            remap[in->dst] = new_nvalues;
        }
    }

    for (size_t i = 0U; i < ir->count; i++) {
        SpTIRInst in;
        if (keep[i] == 0U) continue;
        in = ir->inst[i];
        if (in.dst != SP_TIR_NO_VALUE) {
            if (remap[in.dst] == SP_TIR_NO_VALUE) goto rollback;
            in.dst = remap[in.dst];
        }
        if (in.a != SP_TIR_NO_VALUE) {
            if (in.a > old_nvalues || remap[in.a] == SP_TIR_NO_VALUE) goto rollback;
            in.a = remap[in.a];
        }
        if (in.b != SP_TIR_NO_VALUE) {
            if (in.b > old_nvalues || remap[in.b] == SP_TIR_NO_VALUE) goto rollback;
            in.b = remap[in.b];
        }
        if (in.op == SP_TIR_ASTORE || in.op == SP_TIR_FSTORE) {   /* the stored value travels in aux */
            if (in.aux == SP_TIR_NO_VALUE || in.aux > old_nvalues || remap[in.aux] == SP_TIR_NO_VALUE) goto rollback;
            in.aux = remap[in.aux];
        }
        compact[out_count++] = in;
    }

    memset(ir->value_types, 0, ir->type_capacity * sizeof *ir->value_types);
    for (uint32_t old_value = 1U; old_value <= old_nvalues; old_value++) {
        if (remap[old_value] != SP_TIR_NO_VALUE) {
            ir->value_types[remap[old_value]] = types_backup[old_value];
        }
    }
    memcpy(ir->inst, compact, out_count * sizeof *compact);
    ir->count = out_count;
    ir->nvalues = new_nvalues;
    if (!sp_tir_verify(ir, verify_message, sizeof verify_message)) goto rollback;

    if (folded_count != NULL) *folded_count = folded;
    if (removed_count != NULL) *removed_count = old_count - out_count;
    ok = 1;
    goto done;

rollback:
    if (backup != NULL && types_backup != NULL) {
        memcpy(ir->inst, backup, old_count * sizeof *backup);
        memcpy(ir->value_types, types_backup, type_slots * sizeof *types_backup);
        ir->count = old_count;
        ir->nvalues = old_nvalues;
    }
done:
    free(rep);
    free(dup);
    free(remap);
    free(keep);
    free(live);
    free(types_backup);
    free(compact);
    free(backup);
    return ok;
}

int sp_tir_dump(const SpTraceIR *ir, FILE *out) {
    if (ir == NULL || out == NULL) return 0;
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->dst != SP_TIR_NO_VALUE) {
            if (fprintf(out, "  v%" PRIu32 " = ", in->dst) < 0) return 0;
        } else if (fputs("  ", out) == EOF) {
            return 0;
        }
        if (fprintf(out, "%s", tir_op_name(in->op)) < 0) return 0;
        switch (in->op) {
        case SP_TIR_PARAM:
            if (fprintf(out, " %s[%" PRIu64 "]", tir_type_name(in->type), in->imm) < 0) return 0;
            break;
        case SP_TIR_CONST_I64:
            if (fprintf(out, " %" PRId64, (int64_t)in->imm) < 0) return 0;
            break;
        case SP_TIR_CONST_F64: {
            double value;
            memcpy(&value, &in->imm, sizeof value);
            if (fprintf(out, " %.17g", value) < 0) return 0;
            break;
        }
        case SP_TIR_CONST_BOOL:
            if (fputs(in->imm != 0U ? " true" : " false", out) == EOF) return 0;
            break;
        case SP_TIR_PHI:
            if (fprintf(out, " %s [v%" PRIu32 ", v%" PRIu32 "]",
                        tir_type_name(in->type), in->a, in->b) < 0) return 0;
            break;
        case SP_TIR_IADD: case SP_TIR_ISUB: case SP_TIR_IMUL: case SP_TIR_IDIV: case SP_TIR_IMOD:
        case SP_TIR_IAND: case SP_TIR_IOR: case SP_TIR_IXOR: case SP_TIR_ISHL: case SP_TIR_ISHR:
        case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL: case SP_TIR_FDIV:
        case SP_TIR_ICMP_EQ: case SP_TIR_ICMP_NE: case SP_TIR_ICMP_LT: case SP_TIR_ICMP_LE:
        case SP_TIR_ICMP_GT: case SP_TIR_ICMP_GE:
        case SP_TIR_FCMP_EQ: case SP_TIR_FCMP_NE: case SP_TIR_FCMP_LT: case SP_TIR_FCMP_LE:
        case SP_TIR_FCMP_GT: case SP_TIR_FCMP_GE:
            if (fprintf(out, " v%" PRIu32 ", v%" PRIu32, in->a, in->b) < 0) return 0;
            break;
        case SP_TIR_INEG: case SP_TIR_FNEG: case SP_TIR_I2F: case SP_TIR_FCALL1: case SP_TIR_FSQRT: case SP_TIR_FABS: case SP_TIR_FFLOOR: case SP_TIR_RETURN:
            if (fprintf(out, " v%" PRIu32, in->a) < 0) return 0;
            break;
        case SP_TIR_ALOAD:
            if (fprintf(out, " v%" PRIu32 "[v%" PRIu32 "] tag=%" PRIu64, in->a, in->b, in->imm) < 0) return 0;
            break;
        case SP_TIR_VFIELD:
            if (fprintf(out, " v%" PRIu32 ".%" PRIu32 " = phi v%" PRIu32, in->a, in->aux, in->b) < 0) return 0;
            break;
        case SP_TIR_NEWINST:
            if (fprintf(out, " class=%#" PRIx64, in->imm) < 0) return 0;
            break;
        case SP_TIR_SLOAD:
            if (fprintf(out, " v%" PRIu32 "[v%" PRIu32 "]", in->a, in->b) < 0) return 0;
            break;
        case SP_TIR_LEAFCALL:
            if (fprintf(out, " %#" PRIx64 "(v%" PRIu32 ", v%" PRIu32 ")", in->imm, in->a, in->b) < 0) return 0;
            break;
        case SP_TIR_UCELL:
            if (fprintf(out, " v%" PRIu32 ".up[%" PRIu32 "]", in->a, in->aux) < 0) return 0;
            break;
        case SP_TIR_FLOAD:
            if (fprintf(out, " v%" PRIu32 ".%" PRIu32 " tag=%" PRIu64, in->a, in->aux, in->imm) < 0) return 0;
            break;
        case SP_TIR_FSTORE:
            if (fprintf(out, " v%" PRIu32 ".%" PRIu64 " = v%" PRIu32, in->a, in->imm, in->aux) < 0) return 0;
            break;
        case SP_TIR_CGUARD:
            if (fprintf(out, " v%" PRIu32 " class=%#" PRIx64, in->a, in->imm) < 0) return 0;
            break;
        case SP_TIR_ASTORE:
            if (fprintf(out, " v%" PRIu32 "[v%" PRIu32 "] = v%" PRIu32, in->a, in->b, in->aux) < 0) return 0;
            break;
        case SP_TIR_GUARD_TRUE:
            if (fprintf(out, " v%" PRIu32 " exit=%" PRIu32 "%s%s", in->a, in->aux,
                        (in->imm & SP_TIR_GUARD_DEOPT) ? " deopt" : "", (in->imm & SP_TIR_GUARD_INVERT) ? " invert" : (in->imm & SP_TIR_GUARD_ENTRY) ? " entry" : "") < 0) return 0;
            break;
        case SP_TIR_LOOP:
            break;
        default:
            return 0;
        }
        if (fputc('\n', out) == EOF) return 0;
    }
    return !ferror(out);
}

#ifdef SPRINT_TRACE_IR_TEST
static int test_fail(const char *name) {
    (void)fprintf(stderr, "FAIL: %s\n", name);
    return 1;
}

int main(void) {
    SpTraceIR ir;
    SpTIRValue limit, zero, one, phi_i, phi_sum, next_i, next_sum, cond;
    char message[128];
    int failures = 0;

    sp_tir_init(&ir);
    if (!sp_tir_emit_param(&ir, SP_TIR_T_I64, 0U, &limit) ||
        !sp_tir_emit_const_i64(&ir, 0, &zero) ||
        !sp_tir_emit_const_i64(&ir, 1, &one) ||
        !sp_tir_emit_phi(&ir, SP_TIR_T_I64, zero, &phi_i) ||
        !sp_tir_emit_phi(&ir, SP_TIR_T_I64, zero, &phi_sum) ||
        !sp_tir_emit_binary(&ir, SP_TIR_IADD, phi_i, one, &next_i) ||
        !sp_tir_emit_binary(&ir, SP_TIR_IADD, phi_sum, phi_i, &next_sum) ||
        !sp_tir_set_phi_backedge(&ir, phi_i, next_i) ||
        !sp_tir_set_phi_backedge(&ir, phi_sum, next_sum) ||
        !sp_tir_emit_binary(&ir, SP_TIR_ICMP_LT, next_i, limit, &cond) ||
        !sp_tir_emit_guard_true(&ir, cond, 7U) ||
        !sp_tir_emit_loop(&ir)) {
        failures += test_fail("build valid loop-carried SSA trace");
        sp_tir_destroy(&ir);
        return failures;
    }
    if (!sp_tir_verify(&ir, message, sizeof message)) {
        (void)fprintf(stderr, "verify message: %s\n", message);
        failures += test_fail("verify valid SSA trace");
    }
    if (!sp_tir_dump(&ir, stdout)) failures += test_fail("dump SSA trace");
    if (sp_tir_set_phi_backedge(&ir, phi_i, next_i)) {
        failures += test_fail("reject duplicate PHI back-edge");
    }
    {
        SpTIRValue saved = ir.inst[5].a;
        ir.inst[5].a = next_sum;
        if (sp_tir_verify(&ir, message, sizeof message)) {
            failures += test_fail("reject non-dominating forward use");
        }
        ir.inst[5].a = saved;
    }
    {
        SpTIRType saved = ir.value_types[phi_i];
        ir.value_types[phi_i] = SP_TIR_T_F64;
        if (sp_tir_verify(&ir, message, sizeof message)) {
            failures += test_fail("reject inconsistent SSA type table");
        }
        ir.value_types[phi_i] = saved;
    }
    sp_tir_destroy(&ir);

    sp_tir_init(&ir);
    if (!sp_tir_emit_const_i64(&ir, 1, &zero) ||
        !sp_tir_emit_const_i64(&ir, 2, &one) ||
        !sp_tir_emit_binary(&ir, SP_TIR_IADD, zero, one, &next_i) ||
        sp_tir_emit_phi(&ir, SP_TIR_T_I64, zero, &phi_i)) {
        failures += test_fail("reject PHI after ordinary trace instruction");
    }
    sp_tir_destroy(&ir);

    sp_tir_init(&ir);
    if (!sp_tir_emit_const_i64(&ir, 3, &zero)) {
        failures += test_fail("emit integer constant");
    } else if (sp_tir_emit_binary(&ir, SP_TIR_FADD, zero, zero, &one)) {
        failures += test_fail("reject mixed integer/float operation");
    }
    sp_tir_destroy(&ir);

    sp_tir_init(&ir);
    if (!sp_tir_emit_const_i64(&ir, 9, &zero) || !sp_tir_emit_loop(&ir)) {
        failures += test_fail("build terminator test trace");
    } else if (sp_tir_emit_const_i64(&ir, 10, &one)) {
        failures += test_fail("reject instruction after terminator");
    }
    sp_tir_destroy(&ir);

    sp_tir_init(&ir);
    if (!sp_tir_emit_const_i64(&ir, 1, &zero)) {
        failures += test_fail("emit incomplete-PHI test constant");
    } else if (!sp_tir_emit_phi(&ir, SP_TIR_T_I64, zero, &phi_i) ||
               !sp_tir_emit_const_i64(&ir, 2, &one) || !sp_tir_emit_loop(&ir)) {
        failures += test_fail("build incomplete-PHI trace");
    } else if (sp_tir_verify(&ir, message, sizeof message)) {
        failures += test_fail("reject PHI without back-edge");
    }
    sp_tir_destroy(&ir);

    sp_tir_init(&ir);
    if (!sp_tir_emit_loop(&ir) || !sp_tir_verify(&ir, message, sizeof message)) {
        failures += test_fail("verify value-free trace terminator");
    }
    sp_tir_destroy(&ir);

    sp_tir_init(&ir);
    {
        SpTIRValue value, next;
        int built = sp_tir_emit_const_i64(&ir, 0, &value);
        for (unsigned i = 0U; built && i < 4096U; i++) {
            SpTIRValue increment;
            built = sp_tir_emit_const_i64(&ir, 1, &increment) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IADD, value, increment, &next);
            if (built) value = next;
        }
        if (!built || !sp_tir_emit_return(&ir, value) ||
            !sp_tir_verify(&ir, message, sizeof message)) {
            failures += test_fail("grow SSA instruction and type tables");
        }
    }
    sp_tir_destroy(&ir);

    sp_tir_init(&ir);
    {
        SpTIRValue fa, fb, fc, fcmp;
        size_t folded = 0U;
        if (!sp_tir_emit_param(&ir, SP_TIR_T_F64, 0U, &fa) ||
            !sp_tir_emit_const_f64(&ir, 0.5, &fb) ||
            !sp_tir_emit_binary(&ir, SP_TIR_FADD, fa, fb, &fc) ||
            !sp_tir_emit_binary(&ir, SP_TIR_FCMP_GT, fc, fb, &fcmp) ||
            !sp_tir_emit_guard_true(&ir, fcmp, 3U) ||
            !sp_tir_emit_return(&ir, fc) ||
            !sp_tir_verify(&ir, message, sizeof message) ||
            !sp_tir_constant_fold(&ir, &folded) || folded != 0U ||
            ir.inst[2].op != SP_TIR_FADD || ir.inst[3].op != SP_TIR_FCMP_GT) {
            failures += test_fail("build and preserve typed floating-point trace");
        }
    }
    sp_tir_destroy(&ir);

    /* Constant folding: transitive integer expressions and boolean guards. */
    sp_tir_init(&ir);
    {
        SpTIRValue c20, c22, sum, c3, product, c100, difference, comparison, negated;
        size_t folded = 0U;
        int built = sp_tir_emit_const_i64(&ir, 20, &c20) &&
                    sp_tir_emit_const_i64(&ir, 22, &c22) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IADD, c20, c22, &sum) &&
                    sp_tir_emit_const_i64(&ir, 3, &c3) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IMUL, sum, c3, &product) &&
                    sp_tir_emit_const_i64(&ir, 100, &c100) &&
                    sp_tir_emit_binary(&ir, SP_TIR_ISUB, product, c100, &difference) &&
                    sp_tir_emit_binary(&ir, SP_TIR_ICMP_GT, difference, c3, &comparison) &&
                    sp_tir_emit_unary(&ir, SP_TIR_INEG, c3, &negated) &&
                    sp_tir_emit_guard_true(&ir, comparison, 9U) &&
                    sp_tir_emit_return(&ir, difference);
        if (!built || !sp_tir_verify(&ir, message, sizeof message) ||
            !sp_tir_constant_fold(&ir, &folded) || folded != 5U ||
            !sp_tir_verify(&ir, message, sizeof message) ||
            ir.inst[2].op != SP_TIR_CONST_I64 || ir.inst[2].imm != 42U ||
            ir.inst[4].op != SP_TIR_CONST_I64 || ir.inst[4].imm != 126U ||
            ir.inst[6].op != SP_TIR_CONST_I64 || ir.inst[6].imm != 26U ||
            ir.inst[7].op != SP_TIR_CONST_BOOL || ir.inst[7].imm != 1U ||
            ir.inst[8].op != SP_TIR_CONST_I64 || ir.inst[8].imm != (uint64_t)(int64_t)-3) {
            (void)fprintf(stderr, "constant-fold message: %s\n", message);
            failures += test_fail("fold chained integer expressions and boolean guard");
        } else if (!sp_tir_constant_fold(&ir, &folded) || folded != 0U) {
            failures += test_fail("constant folding is idempotent");
        }
    }
    sp_tir_destroy(&ir);

    /* Floor division/modulo semantics and exceptional arithmetic stay intact. */
    sp_tir_init(&ir);
    {
        SpTIRValue neg7, pos3, floor_a, mod_a, pos7, neg3, floor_b, mod_b;
        SpTIRValue min_value, neg_one, overflow_div, overflow_neg, zero_value, div_zero;
        SpTIRValue mod_min, max_value, one_value, overflow_add, overflow_mul;
        size_t folded = 0U;
        int built = sp_tir_emit_const_i64(&ir, -7, &neg7) &&
                    sp_tir_emit_const_i64(&ir, 3, &pos3) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IDIV, neg7, pos3, &floor_a) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IMOD, neg7, pos3, &mod_a) &&
                    sp_tir_emit_const_i64(&ir, 7, &pos7) &&
                    sp_tir_emit_const_i64(&ir, -3, &neg3) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IDIV, pos7, neg3, &floor_b) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IMOD, pos7, neg3, &mod_b) &&
                    sp_tir_emit_const_i64(&ir, INT64_MIN, &min_value) &&
                    sp_tir_emit_const_i64(&ir, -1, &neg_one) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IDIV, min_value, neg_one, &overflow_div) &&
                    sp_tir_emit_unary(&ir, SP_TIR_INEG, min_value, &overflow_neg) &&
                    sp_tir_emit_const_i64(&ir, 0, &zero_value) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IDIV, pos7, zero_value, &div_zero) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IMOD, min_value, neg_one, &mod_min) &&
                    sp_tir_emit_const_i64(&ir, INT64_MAX, &max_value) &&
                    sp_tir_emit_const_i64(&ir, 1, &one_value) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IADD, max_value, one_value, &overflow_add) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IMUL, min_value, neg_one, &overflow_mul) &&
                    sp_tir_emit_return(&ir, mod_b);
        if (!built || !sp_tir_constant_fold(&ir, &folded) || folded != 5U ||
            !sp_tir_verify(&ir, message, sizeof message) ||
            ir.inst[2].op != SP_TIR_CONST_I64 || ir.inst[2].imm != (uint64_t)(int64_t)-3 ||
            ir.inst[3].op != SP_TIR_CONST_I64 || ir.inst[3].imm != 2U ||
            ir.inst[6].op != SP_TIR_CONST_I64 || ir.inst[6].imm != (uint64_t)(int64_t)-3 ||
            ir.inst[7].op != SP_TIR_CONST_I64 || ir.inst[7].imm != (uint64_t)(int64_t)-2 ||
            ir.inst[10].op != SP_TIR_IDIV || ir.inst[11].op != SP_TIR_INEG ||
            ir.inst[13].op != SP_TIR_IDIV ||
            ir.inst[14].op != SP_TIR_CONST_I64 || ir.inst[14].imm != 0U ||
            ir.inst[17].op != SP_TIR_IADD || ir.inst[18].op != SP_TIR_IMUL) {
            (void)fprintf(stderr, "constant-fold edge message: %s\n", message);
            failures += test_fail("preserve floor arithmetic and exceptional cases");
        }
        (void)overflow_div;
        (void)overflow_neg;
        (void)div_zero;
        (void)mod_min;
        (void)overflow_add;
        (void)overflow_mul;
    }
    sp_tir_destroy(&ir);

    sp_tir_destroy(&ir);

    /* Boolean constant builder validates and stores canonical 0/1 values. */
    sp_tir_init(&ir);
    {
        SpTIRValue truth, bool_value;
        if (!sp_tir_emit_const_bool(&ir, 1, &truth) ||
            sp_tir_emit_const_bool(&ir, 2, &bool_value) ||
            !sp_tir_emit_guard_true(&ir, truth, 2U) ||
            !sp_tir_emit_const_i64(&ir, 0, &bool_value) ||
            !sp_tir_emit_return(&ir, bool_value) ||
            !sp_tir_verify(&ir, message, sizeof message) ||
            ir.inst[0].op != SP_TIR_CONST_BOOL || ir.inst[0].imm != 1U) {
            failures += test_fail("build and verify canonical boolean constant");
        }
    }
    sp_tir_destroy(&ir);

    /* Malformed input is rejected transactionally without changing its bytes. */
    sp_tir_init(&ir);
    {
        SpTIRValue a, b, sum;
        SpTIRInst damaged;
        size_t folded = 99U;
        int built = sp_tir_emit_const_i64(&ir, 4, &a) &&
                    sp_tir_emit_const_i64(&ir, 5, &b) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IADD, a, b, &sum) &&
                    sp_tir_emit_return(&ir, sum);
        if (!built) {
            failures += test_fail("build transactional optimizer input");
        } else {
            ir.inst[2].a = SP_TIR_NO_VALUE;
            damaged = ir.inst[2];
            if (sp_tir_constant_fold(&ir, &folded) || folded != 0U ||
                memcmp(&ir.inst[2], &damaged, sizeof damaged) != 0) {
                failures += test_fail("reject malformed IR before mutation");
            }
        }
    }
    sp_tir_destroy(&ir);

    /* DCE removes unused definitions while preserving PHI back-edges and guards. */
    sp_tir_init(&ir);
    {
        SpTIRValue limit_value, unused_param, zero_value, one_value, dead_value;
        SpTIRValue phi_value, next_value, condition;
        size_t folded = 0U;
        size_t removed = 0U;
        int built = sp_tir_emit_param(&ir, SP_TIR_T_I64, 0U, &limit_value) &&
                    sp_tir_emit_param(&ir, SP_TIR_T_I64, 9U, &unused_param) &&
                    sp_tir_emit_const_i64(&ir, 0, &zero_value) &&
                    sp_tir_emit_const_i64(&ir, 1, &one_value) &&
                    sp_tir_emit_const_i64(&ir, 777, &dead_value) &&
                    sp_tir_emit_phi(&ir, SP_TIR_T_I64, zero_value, &phi_value) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IADD, phi_value, one_value, &next_value) &&
                    sp_tir_set_phi_backedge(&ir, phi_value, next_value) &&
                    sp_tir_emit_binary(&ir, SP_TIR_ICMP_LT, next_value, limit_value, &condition) &&
                    sp_tir_emit_guard_true(&ir, condition, 11U) &&
                    sp_tir_emit_loop(&ir);
        (void)unused_param;
        (void)dead_value;
        if (!built || !sp_tir_verify(&ir, message, sizeof message) ||
            !sp_tir_optimize(&ir, &folded, &removed) || removed != 2U ||
            !sp_tir_verify(&ir, message, sizeof message) ||
            ir.count != 8U || ir.nvalues != 6U ||
            ir.inst[3].op != SP_TIR_PHI || ir.inst[3].a != 2U ||
            ir.inst[3].b != 5U || ir.inst[4].op != SP_TIR_IADD ||
            ir.inst[6].op != SP_TIR_GUARD_TRUE || ir.inst[7].op != SP_TIR_LOOP) {
            (void)fprintf(stderr, "DCE optimize message: %s\n", message);
            failures += test_fail("DCE keeps PHI back-edge and guard while compacting SSA values");
        }
    }
    sp_tir_destroy(&ir);

    /* A loop-carried back-edge can be the sole user of a transitive value
     * chain whose definitions appear after the PHI. Fixed-point DCE must keep
     * the entire chain even though a single reverse scan would miss it. */
    sp_tir_init(&ir);
    {
        SpTIRValue limit_value, initial_value, scale_value, step_value;
        SpTIRValue phi_value, scaled_value, next_value, condition;
        int built = sp_tir_emit_param(&ir, SP_TIR_T_I64, 0U, &limit_value) &&
                    sp_tir_emit_const_i64(&ir, 0, &initial_value) &&
                    sp_tir_emit_const_i64(&ir, 2, &scale_value) &&
                    sp_tir_emit_const_i64(&ir, 1, &step_value) &&
                    sp_tir_emit_phi(&ir, SP_TIR_T_I64, initial_value, &phi_value) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IMUL, phi_value, scale_value, &scaled_value) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IADD, scaled_value, step_value, &next_value) &&
                    sp_tir_set_phi_backedge(&ir, phi_value, next_value) &&
                    sp_tir_emit_binary(&ir, SP_TIR_ICMP_LT, phi_value, limit_value, &condition) &&
                    sp_tir_emit_guard_true(&ir, condition, 19U) &&
                    sp_tir_emit_loop(&ir);
        if (!built || !sp_tir_optimize(&ir, NULL, NULL) ||
            !sp_tir_verify(&ir, message, sizeof message) ||
            ir.count != 10U || ir.nvalues != 8U ||
            ir.inst[4].op != SP_TIR_PHI || ir.inst[4].b != 7U ||
            ir.inst[5].op != SP_TIR_IMUL || ir.inst[6].op != SP_TIR_IADD ||
            ir.inst[8].op != SP_TIR_GUARD_TRUE || ir.inst[9].op != SP_TIR_LOOP) {
            (void)fprintf(stderr, "PHI back-edge liveness message: %s\n", message);
            failures += test_fail("DCE fixed point preserves transitive PHI back-edge dependencies");
        }
    }
    sp_tir_destroy(&ir);

    /* PHIs are observable to the VM side-exit state map even when their values
     * are not used by the loop condition. The accumulator and its back-edge
     * must therefore survive DCE. */
    sp_tir_init(&ir);
    {
        SpTIRValue guard_value, initial_value, step_value;
        SpTIRValue accumulator_phi, accumulator_next;
        int built = sp_tir_emit_param(&ir, SP_TIR_T_BOOL, 0U, &guard_value) &&
                    sp_tir_emit_const_i64(&ir, 0, &initial_value) &&
                    sp_tir_emit_const_i64(&ir, 1, &step_value) &&
                    sp_tir_emit_phi(&ir, SP_TIR_T_I64, initial_value, &accumulator_phi) &&
                    sp_tir_emit_binary(&ir, SP_TIR_IADD, accumulator_phi, step_value, &accumulator_next) &&
                    sp_tir_set_phi_backedge(&ir, accumulator_phi, accumulator_next) &&
                    sp_tir_emit_guard_true(&ir, guard_value, 23U) &&
                    sp_tir_emit_loop(&ir);
        if (!built || !sp_tir_optimize(&ir, NULL, NULL) ||
            !sp_tir_verify(&ir, message, sizeof message) ||
            ir.count != 7U || ir.nvalues != 5U ||
            ir.inst[3].op != SP_TIR_PHI || ir.inst[3].b != 5U ||
            ir.inst[4].op != SP_TIR_IADD ||
            ir.inst[5].op != SP_TIR_GUARD_TRUE || ir.inst[6].op != SP_TIR_LOOP) {
            (void)fprintf(stderr, "observable PHI message: %s count=%zu values=%u\n", message, ir.count, ir.nvalues);
            (void)sp_tir_dump(&ir, stderr);
            failures += test_fail("DCE retains loop-state PHIs that are not guard operands");
        }
    }
    sp_tir_destroy(&ir);

    if (failures == 0) {
        (void)puts("trace-ir: 15 invariant groups passed");
    }
    return failures == 0 ? 0 : 1;
}
#endif
