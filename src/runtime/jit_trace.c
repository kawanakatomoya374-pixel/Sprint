#include "../sp.h"
#if SP_JIT
#include "trace_ir.h"
#include "jit/internal.h"
#include "jit/snapshot.h"
#include "jit/stencils.h"
#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "jit/layout.h"

static unsigned rd16(const uint8_t *p) {
    return (unsigned)p[0] | ((unsigned)p[1] << 8);
}

static int32_t rd32s(const uint8_t *p) {
    uint32_t value = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                     ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    int32_t result;
    memcpy(&result, &value, sizeof result);
    return result;
}

enum {
    TRACE_CACHE_MAX_REGIONS = SP_JIT_SNAPSHOT_SLOT_COUNT,
    TRACE_CACHE_MAX_BYTES = 1 << 20,
    TRACE_INDEX_CAP = 128,
    TRACE_SIDE_MAX = 4,
    TRACE_SIDE_DEPTH_MAX = 3,
    TRACE_SIDE_ATTEMPT_MAX = 8
};

typedef uint32_t (*TraceEntry)(SpValue *, uint64_t *);
typedef struct {
    TraceEntry link_entry;
    uint64_t last_used;
    uint64_t *clock;
} TraceRuntimeCells;
_Static_assert(sizeof(void *) == 8U && sizeof(TraceEntry) == 8U &&
               offsetof(TraceRuntimeCells, last_used) == 8U &&
               offsetof(TraceRuntimeCells, clock) == 16U,
               "TraceJIT runtime-cell ABI");
struct TraceRegion {
    struct TraceRegion *next;
    struct TraceRegion *link;
    struct TraceRegion *parent;
    struct TraceRegion *sides[TRACE_SIDE_MAX];
    uint32_t header;
    uint32_t exit_pc;
    uint32_t backedge_pc;
    void *mem;
    size_t msize;
    TraceEntry entry;
    TraceRuntimeCells runtime;
    SpJitSnapshotSet snapshot_set;
    size_t meta_size;
    uint64_t signature_hash;
    uint64_t side_attempts[TRACE_SIDE_ATTEMPT_MAX];
    uint64_t deopts, deopt_iters; /* deopt exits taken, and loop iterations completed between them (demotion policy) */
    uint8_t dead;                 /* demoted: the loop is left to the region JIT */
    uint8_t nmod;                 /* module variables the trace keeps in scratch slots (mod_slot0 + k) of the frame */
    uint16_t mod_idx[8];          /* ... and their indices in vm->slots */
    uint32_t mod_slot0;
    uint8_t slot;
    uint8_t is_side;
    uint8_t side_count;
    uint8_t side_attempt_count;
    uint8_t depth;
};
struct TraceIndexSlot {
    uint32_t header;
    TraceRegion *region;
    uint8_t state; /* 0 = empty, 1 = occupied, 2 = tombstone */
};

/* ------------------------------------------------------------------ */
/* TraceJIT: record one hot path, lower it through verified SSA, and   */
/* execute a guarded x86-64 trace.  Unsupported bytecode is left to    */
/* the regular region JIT / interpreter.                               */
/* ------------------------------------------------------------------ */
typedef struct {
    uint8_t op;
    uint16_t arg;
    int64_t imm;
} TraceBuildOp;

typedef struct {
    uint8_t bytes[16384];
    size_t len;
    struct { size_t disp; unsigned label; int32_t addend; } fix[512];
    size_t nfix;
    size_t labels[6];
    uint8_t label_set[6];
    int failed;
} TraceAsm;

typedef struct {
    int32_t h[6];
    uint64_t q, q2;
    uint8_t b[6];
    unsigned target;
} TracePatch;

enum { TA_LOOP = 0, TA_EXIT, TA_DEOPT, TA_MISS, TA_BUDGET, TA_EPILOGUE };
#define TA_MEMREG 0xFEU /* regs[] mark of a loop-invariant integer that stays in its slot (see ta_is_invariant_mem) */
#define TA_NO_LABEL ((unsigned)-1)

static TracePatch ta_patch(void) {
    TracePatch p = {{0, 0, 0, 0, 0, 0}, 0U, 0U, {0, 0, 0, 0, 0, 0}, TA_NO_LABEL};
    return p;
}

static int ta_label(TraceAsm *a, unsigned label) {
    if (label >= sizeof a->labels / sizeof a->labels[0] || a->label_set[label]) {
        a->failed = 1;
        return 0;
    }
    a->labels[label] = a->len;
    a->label_set[label] = 1U;
    return 1;
}

static int ta_fix_at(TraceAsm *a, size_t disp, unsigned label, int32_t addend) {
    if (a->nfix >= sizeof a->fix / sizeof a->fix[0] ||
        label >= sizeof a->labels / sizeof a->labels[0] ||
        disp > sizeof a->bytes - sizeof(int32_t)) {
        a->failed = 1;
        return 0;
    }
    a->fix[a->nfix].disp = disp;
    a->fix[a->nfix].label = label;
    a->fix[a->nfix].addend = addend;
    a->nfix++;
    memset(a->bytes + disp, 0, sizeof(int32_t));
    return 1;
}

/* TraceJIT consumes the same generated stencil table as the regular JIT.
 * Every atom is copied from stencils.S, then the generator-described holes
 * are patched. Local branches are resolved after all trace labels are laid out. */
static int ta_stencil(TraceAsm *a, int sid, const TracePatch *patch) {
    const JStencil *s;
    size_t start;
    if (!a || !patch || sid < 0 || sid >= ST_COUNT || a->failed) return 0;
    s = &jst_tab[sid];
    if ((size_t)s->len > sizeof a->bytes - a->len) {
        a->failed = 1;
        return 0;
    }
    start = a->len;
    memcpy(a->bytes + start, jst_code + s->off, s->len);
    for (uint32_t i = 0U; i < s->nrel; i++) {
        const JReloc *r = &jst_rel[s->rel0 + i];
        size_t at = start + r->at;
        if ((size_t)r->at >= s->len) {
            a->failed = 1;
            return 0;
        }
        if (r->hole <= HOLE_H5) {
            int64_t v = (int64_t)patch->h[r->hole] + r->addend;
            int32_t v32;
            if (r->kind != REL_ABS32 || v < INT32_MIN || v > INT32_MAX ||
                (size_t)r->at + sizeof v32 > s->len) {
                a->failed = 1;
                return 0;
            }
            v32 = (int32_t)v;
            memcpy(a->bytes + at, &v32, sizeof v32);
        } else if (r->hole == HOLE_HQ || r->hole == HOLE_HQ2) {
            uint64_t base = r->hole == HOLE_HQ ? patch->q : patch->q2;
            uint64_t v = base + (uint64_t)(int64_t)r->addend;
            if (r->kind != REL_ABS64 || (size_t)r->at + sizeof v > s->len) {
                a->failed = 1;
                return 0;
            }
            memcpy(a->bytes + at, &v, sizeof v);
        } else if (r->hole >= HOLE_B0 && r->hole <= HOLE_B5) {
            int64_t v = (int64_t)patch->b[r->hole - HOLE_B0] + r->addend;
            if (r->kind != REL_ABS8 || v < 0 || v > UINT8_MAX) {
                a->failed = 1;
                return 0;
            }
            a->bytes[at] = (uint8_t)v;
        } else if (r->hole == HOLE_T || r->hole == HOLE_X) {
            if (r->kind != REL_PC32 || patch->target == TA_NO_LABEL ||
                (size_t)r->at + sizeof(int32_t) > s->len ||
                !ta_fix_at(a, at, patch->target, r->addend)) return 0;
        } else {
            a->failed = 1;
            return 0;
        }
    }
    a->len += s->len;
    return 1;
}

static int ta_jmp(TraceAsm *a, unsigned label) {
    TracePatch p = ta_patch();
    p.target = label;
    return ta_stencil(a, ST_tr_jmp, &p);
}
static int ta_jcc(TraceAsm *a, uint8_t cc, unsigned label) {
    TracePatch p = ta_patch();
    p.b[0] = cc;
    p.target = label;
    return ta_stencil(a, ST_tr_jcc, &p);
}
static int ta_resolve(TraceAsm *a) {
    if (a->failed) return 0;
    for (size_t i = 0U; i < a->nfix; i++) {
        unsigned label = a->fix[i].label;
        size_t disp = a->fix[i].disp;
        int64_t rel;
        int32_t r32;
        if (label >= sizeof a->labels / sizeof a->labels[0] || !a->label_set[label] ||
            disp > (size_t)INT64_MAX || a->labels[label] > (size_t)INT64_MAX) return 0;
        rel = (int64_t)a->labels[label] + a->fix[i].addend - (int64_t)disp;
        if (rel < INT32_MIN || rel > INT32_MAX) return 0;
        r32 = (int32_t)rel;
        memcpy(a->bytes + disp, &r32, sizeof r32);
    }
    return 1;
}

static int ta_local_type_guard(TraceAsm *a, uint32_t local, uint8_t expected_type) {
    TracePatch p = ta_patch();
    uint64_t d = (uint64_t)local * 16U;
    if (d > INT32_MAX) return 0;
    p.h[0] = (int32_t)d;
    p.b[0] = expected_type;
    p.target = TA_MISS;
    return ta_stencil(a, ST_tr_local_guard, &p);
}
static int ta_local_load_reg(TraceAsm *a, uint32_t local, uint8_t dst) {
    TracePatch p = ta_patch();
    uint64_t d = (uint64_t)local * 16U + 8U;
    if (d > INT32_MAX) return 0;
    p.h[0] = (int32_t)d;
    p.b[0] = (uint8_t)(0x49U | (dst >= 8U ? 0x04U : 0U));
    p.b[1] = (uint8_t)(0x84U | ((dst & 7U) << 3));
    return ta_stencil(a, ST_tr_local_load, &p);
}
static int ta_local_store_reg(TraceAsm *a, uint32_t local, uint8_t src) {
    TracePatch p = ta_patch();
    uint64_t d = (uint64_t)local * 16U + 8U;
    if (d > INT32_MAX) return 0;
    p.h[0] = (int32_t)d;
    p.b[0] = (uint8_t)(0x49U | (src >= 8U ? 0x04U : 0U));
    p.b[1] = (uint8_t)(0x84U | ((src & 7U) << 3));
    return ta_stencil(a, ST_tr_local_store, &p);
}
static int ta_emit_snapshot_stores(TraceAsm *a, const SpJitSnapshot *snapshot,
                                   const uint8_t *regs, uint32_t nvalues) {
    if (!a || !snapshot || !snapshot->map || !regs) return 0;
    for (uint16_t i = 0U; i < snapshot->map->entry_count; i++) {
        const SpJitSnapshotEntry *entry = &snapshot->map->entries[i];
        if (entry->source != (uint8_t)SP_JIT_SNAPSHOT_FROM_IR) continue;
        if (entry->value != 0U && entry->value <= nvalues && regs[entry->value] == TA_MEMREG) continue;   /* never changed: already in its slot */
        if (entry->value == 0U || entry->value > nvalues ||
            entry->slot >= snapshot->map->slot_count || regs[entry->value] == UINT8_MAX ||
            !ta_local_store_reg(a, (uint32_t)entry->slot, regs[entry->value])) return 0;
    }
    return 1;
}

static int ta_reg_mov(TraceAsm *a, uint8_t dst, uint8_t src) {
    TracePatch p = ta_patch();
    if (dst == src) return 1;
    p.b[0] = (uint8_t)(0x48U | (src >= 8U ? 0x04U : 0U) | (dst >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((src & 7U) << 3) | (dst & 7U));
    return ta_stencil(a, ST_tr_reg_mov, &p);
}

/* Resolve loop-carried PHI assignments as a parallel copy. Reference locals
 * can flow between PHIs, so emitting moves in source order could clobber a
 * value needed by a later assignment. r10 is intentionally outside the
 * allocator's GPR pool and is used only as a cycle-breaking temporary. */
static int ta_emit_phi_moves(const SpTraceIR *ir, const uint8_t *regs, TraceAsm *a) {
    uint8_t dst[256], src[256], active[256];
    size_t count = 0U, remaining;
    if (ir == NULL || regs == NULL || a == NULL || ir->nvalues > 256U) return 0;
    memset(active, 0, sizeof active);
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *phi = &ir->inst[i];
        if (phi->op != SP_TIR_PHI || phi->b == phi->dst) continue;
        if (phi->dst == 0U || phi->dst > ir->nvalues || phi->b == 0U ||
            phi->b > ir->nvalues || regs[phi->dst] == UINT8_MAX ||
            regs[phi->b] == UINT8_MAX || count >= sizeof dst) return 0;
        dst[count] = regs[phi->dst];
        src[count] = regs[phi->b];
        active[count] = 1U;
        count++;
    }
    remaining = count;
    while (remaining != 0U) {
        size_t safe = SIZE_MAX;
        for (size_t i = 0U; i < count; i++) {
            int destination_is_source = 0;
            if (active[i] == 0U) continue;
            for (size_t j = 0U; j < count; j++) {
                if (active[j] != 0U && src[j] == dst[i]) {
                    destination_is_source = 1;
                    break;
                }
            }
            if (!destination_is_source) { safe = i; break; }
        }
        if (safe != SIZE_MAX) {
            if (!ta_reg_mov(a, dst[safe], src[safe])) return 0;
            active[safe] = 0U;
            remaining--;
            continue;
        }
        /* A cycle remains. Save one destination's old value and redirect all
         * reads of it through the temporary before making another move. */
        size_t cycle = 0U;
        while (cycle < count && active[cycle] == 0U) cycle++;
        if (cycle == count || !ta_reg_mov(a, 10U, dst[cycle])) return 0;
        for (size_t j = 0U; j < count; j++)
            if (active[j] != 0U && src[j] == dst[cycle]) src[j] = 10U;
    }
    return 1;
}
static int ta_reg_imm(TraceAsm *a, uint8_t dst, uint64_t value) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (dst >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xb8U + (dst & 7U));
    p.q = value;
    return ta_stencil(a, ST_tr_reg_imm, &p);
}
static int ta_reg_binop(TraceAsm *a, uint8_t dst, uint8_t src, uint8_t opcode) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (src >= 8U ? 0x04U : 0U) | (dst >= 8U ? 0x01U : 0U));
    p.b[1] = opcode;
    p.b[2] = (uint8_t)(0xc0U | ((src & 7U) << 3) | (dst & 7U));
    return ta_stencil(a, ST_tr_reg_binop, &p);
}
static int ta_reg_imul(TraceAsm *a, uint8_t dst, uint8_t src) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (dst >= 8U ? 0x04U : 0U) | (src >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((dst & 7U) << 3) | (src & 7U));
    return ta_stencil(a, ST_tr_reg_imul, &p);
}
static int ta_reg_neg(TraceAsm *a, uint8_t dst) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (dst >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xd8U | (dst & 7U));
    return ta_stencil(a, ST_tr_reg_neg, &p);
}
static int ta_reg_cmp(TraceAsm *a, uint8_t left, uint8_t right) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (right >= 8U ? 0x04U : 0U) | (left >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((right & 7U) << 3) | (left & 7U));
    return ta_stencil(a, ST_tr_reg_cmp, &p);
}
static int ta_reg_setcc(TraceAsm *a, uint8_t dst, uint8_t cc) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x40U | (dst >= 8U ? 0x01U : 0U));
    p.b[1] = cc;
    p.b[2] = (uint8_t)(0xc0U | (dst & 7U));
    p.b[3] = (uint8_t)(0x48U | (dst >= 8U ? 0x05U : 0U));
    p.b[4] = (uint8_t)(0xc0U | ((dst & 7U) << 3) | (dst & 7U));
    return ta_stencil(a, ST_tr_reg_setcc, &p);
}
static int ta_reg_test(TraceAsm *a, uint8_t reg) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (reg >= 8U ? 0x05U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((reg & 7U) << 3) | (reg & 7U));
    return ta_stencil(a, ST_tr_reg_test, &p);
}
/* F64 payloads remain in GPRs; XMM0/XMM1 are short-lived execution temporaries. */
static int ta_gpr_to_xmm(TraceAsm *a, uint8_t xmm, uint8_t gpr) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (gpr >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((xmm & 7U) << 3) | (gpr & 7U));
    return ta_stencil(a, ST_tr_gpr_to_xmm, &p);
}
static int ta_xmm_to_gpr(TraceAsm *a, uint8_t gpr, uint8_t xmm) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (gpr >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((xmm & 7U) << 3) | (gpr & 7U));
    return ta_stencil(a, ST_tr_xmm_to_gpr, &p);
}
static int ta_f64_binop(TraceAsm *a, uint8_t dst, uint8_t src, uint8_t opcode) {
    TracePatch p = ta_patch();
    p.b[0] = opcode;
    return ta_gpr_to_xmm(a, 0U, dst) && ta_gpr_to_xmm(a, 1U, src) &&
           ta_stencil(a, ST_tr_f64_binop, &p) && ta_xmm_to_gpr(a, dst, 0U);
}
static int ta_f64_neg(TraceAsm *a, uint8_t dst) {
    return ta_reg_imm(a, 10U, UINT64_C(0x8000000000000000)) && ta_reg_binop(a, dst, 10U, 0x31U);
}
static int ta_f64_compare(TraceAsm *a, uint8_t left, uint8_t right) {
    TracePatch p = ta_patch();
    return ta_gpr_to_xmm(a, 0U, left) && ta_gpr_to_xmm(a, 1U, right) &&
           ta_stencil(a, ST_tr_f64_cmp, &p);
}
static int ta_fdiv_zero_guard(TraceAsm *a) {
    TracePatch p = ta_patch();
    p.target = TA_DEOPT;
    return ta_stencil(a, ST_tr_fdiv_guard, &p);
}
static int ta_div_guard(TraceAsm *a) {
    TracePatch p = ta_patch();
    p.target = TA_DEOPT;
    return ta_stencil(a, ST_tr_div_guard, &p);
}
static int ta_sar_imm(TraceAsm *a, uint8_t reg, uint8_t count) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (reg >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xf8U | (reg & 7U));
    p.b[2] = count;
    return ta_stencil(a, ST_tr_sar_imm, &p);
}
/* the value of an integer constant defined in this trace, for strength-reducing divisions by a constant */
static int ta_const_i64(const SpTraceIR *ir, SpTIRValue v, int64_t *out) {
    for (size_t i = 0U; i < ir->count; i++)
        if (ir->inst[i].dst == v && ir->inst[i].op == SP_TIR_CONST_I64) { *out = (int64_t)ir->inst[i].imm; return 1; }
    return 0;
}
/* ALU op `reg op= imm32`: ext 0 add, 5 sub, 7 cmp */
static int ta_alu_imm(TraceAsm *a, uint8_t reg, uint8_t ext, int32_t imm) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (reg >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((unsigned)ext << 3) | (reg & 7U));
    p.h[0] = imm;
    return ta_stencil(a, ST_tr_alu_imm, &p);
}
static int ta_imul_imm(TraceAsm *a, uint8_t dst, uint8_t src, int32_t imm) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (dst >= 8U ? 0x04U : 0U) | (src >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((dst & 7U) << 3) | (src & 7U));
    p.h[0] = imm;
    return ta_stencil(a, ST_tr_imul_imm, &p);
}
/* A constant used only as the right operand of + - * and integer comparisons (and small enough for an imm32) needs no register:
 * the operation takes it as an immediate. This saves registers and an instruction per use. */
static int ta_is_folded(const SpTraceIR *ir, SpTIRValue v) {
    const SpTIRInst *def = NULL;
    int uses = 0;
    for (size_t i = 0U; i < ir->count; i++)
        if (ir->inst[i].dst == v && ir->inst[i].op == SP_TIR_CONST_I64) { def = &ir->inst[i]; break; }
    if (def == NULL || (int64_t)def->imm < INT32_MIN || (int64_t)def->imm > INT32_MAX) return 0;
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        const int arith = in->op == SP_TIR_IADD || in->op == SP_TIR_ISUB || in->op == SP_TIR_IMUL ||
                          (in->op >= SP_TIR_ICMP_EQ && in->op <= SP_TIR_ICMP_GE);
        if (in->op == SP_TIR_PHI) { if (in->b == v || in->a == v) return 0; continue; }
        if (in->a == v || ((in->op == SP_TIR_ASTORE || in->op == SP_TIR_FSTORE) && in->aux == v)) return 0;
        if (in->b == v) { if (!arith) return 0; uses++; }
    }
    return uses > 0;
}
/* ---- loop-invariant integers kept in their slot ---------------------------------------------------------------------------
 * A loop-carried integer that the loop never changes (a range bound, the step, `n`) and that is used only as the right operand of
 * + - * and comparisons does not need a register: those operations take it as a memory operand [r12 + slot]. regs[] marks such
 * a value with TA_MEMREG; its entry guard stays, but there is nothing to load, and exits have nothing to store (the slot never
 * changed). */
static int ta_is_entry_cmp(const SpTraceIR *ir, size_t i);
static int ta_is_invariant_mem(const SpTraceIR *ir, SpTIRValue phi_dst) {
    const SpTIRInst *phi = NULL;
    int uses = 0;
    for (size_t i = 0U; i < ir->count; i++)
        if (ir->inst[i].op == SP_TIR_PHI && ir->inst[i].dst == phi_dst) { phi = &ir->inst[i]; break; }
    if (phi == NULL || phi->b != phi->dst || phi->type != SP_TIR_T_I64) return 0;
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        const int arith = in->op == SP_TIR_IADD || in->op == SP_TIR_ISUB || in->op == SP_TIR_IMUL ||
                          (in->op >= SP_TIR_ICMP_EQ && in->op <= SP_TIR_ICMP_GE);
        if (in->op == SP_TIR_PHI) { if (in != phi && (in->b == phi_dst || in->a == phi_dst)) return 0; continue; }
        if (in->a == phi_dst && in->op >= SP_TIR_ICMP_EQ && in->op <= SP_TIR_ICMP_GE && ta_is_entry_cmp(ir, (size_t)(in - ir->inst)) &&
            ta_is_folded(ir, in->b)) { uses++; continue; }   /* the entry guard reads the slot directly */
        if (in->a == phi_dst || ((in->op == SP_TIR_ASTORE || in->op == SP_TIR_FSTORE) && in->aux == phi_dst)) return 0;
        if (in->b == phi_dst) { if (!arith) return 0; uses++; }
    }
    return uses > 0;
}
static int ta_alu_mem(TraceAsm *a, uint8_t reg, uint8_t opcode, uint32_t slot) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)(slot * 16U + 8U);
    p.b[0] = (uint8_t)(0x49U | (reg >= 8U ? 0x04U : 0U));
    p.b[1] = opcode;
    p.b[2] = (uint8_t)(0x84U | ((reg & 7U) << 3));
    return ta_stencil(a, ST_tr_alu_mem, &p);
}
static int ta_imul_mem(TraceAsm *a, uint8_t reg, uint32_t slot) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)(slot * 16U + 8U);
    p.b[0] = (uint8_t)(0x49U | (reg >= 8U ? 0x04U : 0U));
    p.b[2] = (uint8_t)(0x84U | ((reg & 7U) << 3));
    return ta_stencil(a, ST_tr_imul_mem, &p);
}
/* ---- array element access (ALOAD / ASTORE): see the stencils tr_ab_* ------------------------------------------------------ */
static int ta_ab_bounds(TraceAsm *a, uint8_t ra, uint8_t rb) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x48U | (rb >= 8U ? 0x04U : 0U) | (ra >= 8U ? 0x01U : 0U));
    p.b[1] = (uint8_t)(0x80U | ((rb & 7U) << 3) | (ra & 7U));
    return ta_stencil(a, ST_tr_ab_bounds, &p);
}
static int ta_ab_addr(TraceAsm *a, uint8_t ra, uint8_t rb) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x49U | (rb >= 8U ? 0x04U : 0U));
    p.b[1] = (uint8_t)(0xc0U | ((rb & 7U) << 3) | 2U);
    p.b[2] = (uint8_t)(0x4cU | (ra >= 8U ? 0x01U : 0U));
    p.b[3] = (uint8_t)(0x90U | (ra & 7U));
    return ta_stencil(a, ST_tr_ab_addr, &p);
}
static int ta_ab_tag(TraceAsm *a, uint8_t tag) {
    TracePatch p = ta_patch();
    p.b[0] = tag;
    return ta_stencil(a, ST_tr_ab_tag, &p);
}
static int ta_ab_load(TraceAsm *a, uint8_t dst) {
    TracePatch p = ta_patch();
    p.b[0] = (uint8_t)(0x49U | (dst >= 8U ? 0x04U : 0U));
    p.b[1] = (uint8_t)(0x42U | ((dst & 7U) << 3));
    return ta_stencil(a, ST_tr_ab_load, &p);
}
static int ta_ab_store(TraceAsm *a, uint8_t tag, uint8_t src) {
    TracePatch p = ta_patch();
    TracePatch q = ta_patch();
    p.h[0] = (int32_t)tag;
    q.b[0] = (uint8_t)(0x49U | (src >= 8U ? 0x04U : 0U));
    q.b[1] = (uint8_t)(0x42U | ((src & 7U) << 3));
    return ta_stencil(a, ST_tr_ab_store_tag, &p) && ta_stencil(a, ST_tr_ab_store_val, &q);
}
/* ---- instance fields (FLOAD / FSTORE / CGUARD): [object + L_SINST_SLOTS + 16 * slot]: tag, then the payload 8 bytes later ---- */
static uint8_t ta_rex(uint8_t reg, uint8_t base) {
    return (uint8_t)(0x48U | (reg >= 8U ? 0x04U : 0U) | (base >= 8U ? 0x01U : 0U));
}
static int ta_field_tagcmp(TraceAsm *a, uint8_t ra, uint32_t slot, uint8_t tag) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)slot;
    p.b[0] = ta_rex(0U, ra); p.b[1] = (uint8_t)(0xb8U | (ra & 7U)); p.b[2] = tag;
    return ta_stencil(a, ST_tr_obj_tagcmp, &p);
}
static int ta_field_load(TraceAsm *a, uint8_t dst, uint8_t ra, uint32_t slot) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)(slot + 8U);
    p.b[0] = ta_rex(dst, ra); p.b[1] = (uint8_t)(0x80U | ((dst & 7U) << 3) | (ra & 7U));
    return ta_stencil(a, ST_tr_mem_load, &p);
}
static int ta_field_store(TraceAsm *a, uint8_t src, uint8_t ra, uint32_t slot, uint8_t tag) {
    TracePatch p = ta_patch(), q = ta_patch();
    p.h[0] = (int32_t)slot; p.h[1] = (int32_t)tag;
    p.b[0] = ta_rex(0U, ra); p.b[1] = (uint8_t)(0x80U | (ra & 7U));
    q.h[0] = (int32_t)(slot + 8U);
    q.b[0] = ta_rex(src, ra); q.b[1] = (uint8_t)(0x80U | ((src & 7U) << 3) | (ra & 7U));
    return ta_stencil(a, ST_tr_mem_store_tag, &p) && ta_stencil(a, ST_tr_mem_store_val, &q);
}
/* dst = [ra + off] (a raw 64-bit load) */
static int ta_mem_load(TraceAsm *a, uint8_t dst, uint8_t ra, uint32_t off) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)off;
    p.b[0] = ta_rex(dst, ra); p.b[1] = (uint8_t)(0x80U | ((dst & 7U) << 3) | (ra & 7U));
    return ta_stencil(a, ST_tr_mem_load, &p);
}
static int ta_ref_guard(TraceAsm *a, uint8_t ra, uint64_t ptr) {
    return ta_reg_imm(a, 10U, ptr) && ta_reg_binop(a, ra, 10U, 0x39U) && ta_jcc(a, 0x85U, TA_DEOPT);
}
static int ta_class_guard(TraceAsm *a, uint8_t ra, uint64_t cls) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)L_SINST_CLS;
    p.b[0] = ta_rex(10U, ra); p.b[1] = (uint8_t)(0x80U | (2U << 3) | (ra & 7U));
    return ta_reg_imm(a, 10U, cls) && ta_stencil(a, ST_tr_cmp_mem_reg, &p) && ta_jcc(a, 0x85U, TA_DEOPT);
}
static uint8_t trace_ir_runtime_type(const SpTraceIR *ir, SpTIRValue value);
/* the tag a stored value carries in the array: from its IR type, or the recorded runtime type of a reference */
static int ta_store_tag(const SpTraceIR *ir, const SpTIRInst *in, uint8_t *tag) {
    switch (in->type) {
    case SP_TIR_T_I64: *tag = (uint8_t)T_INT; return 1;
    case SP_TIR_T_F64: *tag = (uint8_t)T_FLOAT; return 1;
    case SP_TIR_T_BOOL: *tag = (uint8_t)T_BOOL; return 1;
    case SP_TIR_T_REF: *tag = trace_ir_runtime_type(ir, in->aux); return *tag != UINT8_MAX;
    default: return 0;
    }
}
/* The stores of an iteration are performed after its last point that can still deoptimise (a deopt re-runs the iteration, which
 * would apply a store twice): first every bounds check, then every write. */
static int ta_emit_pending_stores(const SpTraceIR *ir, const uint8_t *regs, const size_t *pending, size_t npending, TraceAsm *a) {
    for (size_t k = 0U; k < npending; k++) {
        const SpTIRInst *st = &ir->inst[pending[k]];
        if (st->op == SP_TIR_FSTORE) continue;
        if (regs[st->a] >= 16U || regs[st->b] >= 16U || !ta_ab_bounds(a, regs[st->a], regs[st->b]) || !ta_jcc(a, 0x83U, TA_DEOPT)) return 0;
    }
    for (size_t k = 0U; k < npending; k++) {
        const SpTIRInst *st = &ir->inst[pending[k]];
        uint8_t tag;
        if (st->op == SP_TIR_FSTORE) {
            if (regs[st->a] >= 16U || regs[st->aux] >= 16U || !ta_store_tag(ir, st, &tag) ||
                !ta_field_store(a, regs[st->aux], regs[st->a], (uint32_t)st->imm, tag)) return 0;
            continue;
        }
        if (regs[st->aux] >= 16U || !ta_store_tag(ir, st, &tag) || !ta_ab_addr(a, regs[st->a], regs[st->b]) ||
            !ta_ab_store(a, tag, regs[st->aux])) return 0;
    }
    return 1;
}
/* does instruction i, a comparison, feed an entry guard (a loop-invariant test performed once, before the loop label)? */
static int ta_is_entry_cmp(const SpTraceIR *ir, size_t i) {
    return i + 1U < ir->count && ir->inst[i + 1U].op == SP_TIR_GUARD_TRUE && ir->inst[i + 1U].a == ir->inst[i].dst &&
           (ir->inst[i + 1U].imm & SP_TIR_GUARD_ENTRY) != 0U;
}
static int ta_cmp_mem_imm(TraceAsm *a, uint32_t slot, int32_t imm) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)(slot * 16U + 8U);
    p.h[1] = imm;
    return ta_stencil(a, ST_tr_cmp_mem_imm, &p);
}
static int ta_plain(TraceAsm *a, int sid) {
    TracePatch p = ta_patch();
    return ta_stencil(a, sid, &p);
}
static int ta_fcmp_ne_guard(TraceAsm *a, unsigned target) {
    TracePatch p = ta_patch();
    p.target = target;
    return ta_stencil(a, ST_tr_fcmp_ne_guard, &p);
}
static int ta_f64_guard_false(TraceAsm *a, SpTIROp op, unsigned target) {
    /* UCOMISD sets PF for unordered operands. Preserve the VM's IEEE rules. */
    switch (op) {
    case SP_TIR_FCMP_EQ:
        return ta_jcc(a, 0x8aU, target) && ta_jcc(a, 0x85U, target);
    case SP_TIR_FCMP_NE:
        return ta_fcmp_ne_guard(a, target);
    case SP_TIR_FCMP_LT:
        return ta_jcc(a, 0x8aU, target) && ta_jcc(a, 0x83U, target);
    case SP_TIR_FCMP_LE:
        return ta_jcc(a, 0x8aU, target) && ta_jcc(a, 0x87U, target);
    case SP_TIR_FCMP_GT:
        return ta_jcc(a, 0x86U, target);
    case SP_TIR_FCMP_GE:
        return ta_jcc(a, 0x82U, target);
    case SP_TIR_PARAM: case SP_TIR_CONST_I64: case SP_TIR_CONST_F64:
    case SP_TIR_CONST_BOOL: case SP_TIR_PHI: case SP_TIR_IADD:
    case SP_TIR_ISUB: case SP_TIR_IMUL: case SP_TIR_IDIV:
    case SP_TIR_IMOD: case SP_TIR_INEG: case SP_TIR_FADD:
    case SP_TIR_FSUB: case SP_TIR_FMUL: case SP_TIR_FDIV:
    case SP_TIR_FNEG: case SP_TIR_ICMP_EQ: case SP_TIR_ICMP_NE:
    case SP_TIR_ICMP_LT: case SP_TIR_ICMP_LE: case SP_TIR_ICMP_GT:
    case SP_TIR_ICMP_GE: case SP_TIR_GUARD_TRUE: case SP_TIR_ALOAD: case SP_TIR_ASTORE: case SP_TIR_FLOAD: case SP_TIR_UCELL: case SP_TIR_FSTORE: case SP_TIR_CGUARD: case SP_TIR_LOOP:
    case SP_TIR_RETURN:
        return 0;
    default:
        return 0;
    }
}
static int ta_load_budget(TraceAsm *a) {
    TracePatch p = ta_patch();
    return ta_stencil(a, ST_tr_load_budget, &p);
}
static int ta_store_budget(TraceAsm *a) {
    TracePatch p = ta_patch();
    return ta_stencil(a, ST_tr_store_budget, &p);
}
static int ta_emit_prologue(TraceAsm *a, size_t frame_size) {
    TracePatch p = ta_patch();
    return frame_size == 16U && ta_stencil(a, ST_tr_prologue, &p);
}
static int ta_emit_epilogue(TraceAsm *a, size_t frame_size) {
    TracePatch p = ta_patch();
    return frame_size == 16U && ta_label(a, TA_EPILOGUE) && ta_stencil(a, ST_tr_epilogue, &p);
}
static int ta_return(TraceAsm *a, uint32_t token) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)token;
    p.target = TA_EPILOGUE;
    return ta_stencil(a, ST_tr_return, &p);
}
static int ta_trace_touch(TraceAsm *a, TraceRuntimeCells *runtime) {
    TracePatch p = ta_patch();
    p.q = (uint64_t)(uintptr_t)runtime;
    return ta_stencil(a, ST_tr_touch, &p);
}
static int ta_trace_exit(TraceAsm *a, uint32_t token, TraceRuntimeCells *runtime) {
    TracePatch p = ta_patch();
    p.h[0] = (int32_t)token;
    p.q = (uint64_t)(uintptr_t)runtime;
    p.target = TA_EPILOGUE;
    return ta_stencil(a, ST_tr_exit, &p);
}
static uint8_t ta_cmp_cc(SpTIROp op) {
    switch (op) {
    case SP_TIR_ICMP_EQ: return 0x94U;
    case SP_TIR_ICMP_NE: return 0x95U;
    case SP_TIR_ICMP_LT: return 0x9cU;
    case SP_TIR_ICMP_LE: return 0x9eU;
    case SP_TIR_ICMP_GT: return 0x9fU;
    case SP_TIR_ICMP_GE: return 0x9dU;
    case SP_TIR_PARAM: case SP_TIR_CONST_I64: case SP_TIR_CONST_F64: case SP_TIR_CONST_BOOL:
    case SP_TIR_PHI: case SP_TIR_IADD: case SP_TIR_ISUB: case SP_TIR_IMUL: case SP_TIR_IDIV:
    case SP_TIR_IMOD: case SP_TIR_INEG: case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL:
    case SP_TIR_FDIV: case SP_TIR_FNEG: case SP_TIR_FCMP_EQ: case SP_TIR_FCMP_NE:
    case SP_TIR_FCMP_LT: case SP_TIR_FCMP_LE: case SP_TIR_FCMP_GT: case SP_TIR_FCMP_GE:
    case SP_TIR_GUARD_TRUE: case SP_TIR_ALOAD: case SP_TIR_ASTORE: case SP_TIR_FLOAD: case SP_TIR_UCELL: case SP_TIR_FSTORE: case SP_TIR_CGUARD: case SP_TIR_LOOP: case SP_TIR_RETURN: return 0U;
    default: return 0U;
    }
}
static uint8_t ta_cmp_false_cc(SpTIROp op) {
    switch (op) {
    case SP_TIR_ICMP_EQ: return 0x85U; /* jne */
    case SP_TIR_ICMP_NE: return 0x84U; /* je */
    case SP_TIR_ICMP_LT: return 0x8dU; /* jge */
    case SP_TIR_ICMP_LE: return 0x8fU; /* jg */
    case SP_TIR_ICMP_GT: return 0x8eU; /* jle */
    case SP_TIR_ICMP_GE: return 0x8cU; /* jl */
    case SP_TIR_PARAM: case SP_TIR_CONST_I64: case SP_TIR_CONST_F64: case SP_TIR_CONST_BOOL:
    case SP_TIR_PHI: case SP_TIR_IADD: case SP_TIR_ISUB: case SP_TIR_IMUL: case SP_TIR_IDIV:
    case SP_TIR_IMOD: case SP_TIR_INEG: case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL:
    case SP_TIR_FDIV: case SP_TIR_FNEG: case SP_TIR_FCMP_EQ: case SP_TIR_FCMP_NE:
    case SP_TIR_FCMP_LT: case SP_TIR_FCMP_LE: case SP_TIR_FCMP_GT: case SP_TIR_FCMP_GE:
    case SP_TIR_GUARD_TRUE: case SP_TIR_ALOAD: case SP_TIR_ASTORE: case SP_TIR_FLOAD: case SP_TIR_UCELL: case SP_TIR_FSTORE: case SP_TIR_CGUARD: case SP_TIR_LOOP: case SP_TIR_RETURN: return 0U;
    default: return 0U;
    }
}
/* idiv works in rax and rdx. A trace that divides allocates them last (the pool order), and saves them around a division only if
 * some value was in fact assigned to one of them */
static int ta_has_div(const SpTraceIR *ir) {
    for (size_t i = 0U; i < ir->count; i++)
        if (ir->inst[i].op == SP_TIR_IDIV || ir->inst[i].op == SP_TIR_IMOD) return 1;
    return 0;
}
static const uint8_t TA_GPR_POOL_DIV[11] = {1U, 3U, 6U, 7U, 8U, 9U, 14U, 15U, 5U, 0U, 2U};
static int ta_uses_rax_rdx(const SpTraceIR *ir, const uint8_t *regs) {
    for (uint32_t v = 1U; v <= ir->nvalues; v++)
        if (regs[v] == 0U || regs[v] == 2U) return 1;
    return 0;
}

static int ta_alloc_regs(const SpTraceIR *ir, const int32_t *phi_local, uint8_t **regs_out) {
    size_t n = (size_t)ir->nvalues + 1U;
    uint8_t *regs = (uint8_t *)malloc(n);
    uint8_t *pinned = (uint8_t *)calloc(n, 1U);
    uint32_t *last = (uint32_t *)calloc(n, sizeof *last);
    JitRegBank bank;
    int ok = 0;
    if (!regs || !pinned || !last || !phi_local || !regs_out) goto done;
    if (ta_has_div(ir)) jit_ra_init(&bank, TA_GPR_POOL_DIV, sizeof TA_GPR_POOL_DIV / sizeof TA_GPR_POOL_DIV[0]);
    else jit_ra_init(&bank, JIT_TRACE_GPR_POOL, sizeof JIT_TRACE_GPR_POOL / sizeof JIT_TRACE_GPR_POOL[0]);
    memset(regs, UINT8_MAX, n);

    /* Loop-carried values and their entry parameters share one pinned register. */
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op == SP_TIR_PHI) {
            int picked;
            if (in->dst == 0U || in->dst > ir->nvalues || in->a == 0U || in->a > ir->nvalues ||
                phi_local[in->dst] < 0) goto done;
            if (ta_is_invariant_mem(ir, in->dst)) {
                regs[in->dst] = TA_MEMREG;
                regs[in->a] = TA_MEMREG;
                pinned[in->dst] = 1U;
                pinned[in->a] = 1U;
                continue;
            }
            picked = jit_ra_alloc(&bank, (int32_t)in->dst);
            if (picked < 0) goto done;
            regs[in->dst] = (uint8_t)picked;
            regs[in->a] = (uint8_t)picked;
            pinned[in->dst] = 1U;
            pinned[in->a] = 1U;
        }
    }

    /* Comparison operands are live across every trip, even though their SSA
     * uses appear only once in the linear instruction list. */
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op == SP_TIR_ICMP_EQ || in->op == SP_TIR_ICMP_NE || in->op == SP_TIR_ICMP_LT ||
            in->op == SP_TIR_ICMP_LE || in->op == SP_TIR_ICMP_GT || in->op == SP_TIR_ICMP_GE ||
            in->op == SP_TIR_FCMP_EQ || in->op == SP_TIR_FCMP_NE || in->op == SP_TIR_FCMP_LT ||
            in->op == SP_TIR_FCMP_LE || in->op == SP_TIR_FCMP_GT || in->op == SP_TIR_FCMP_GE) {
            SpTIRValue values[2] = {in->a, in->b};
            if (ta_is_entry_cmp(ir, i)) continue;   /* not the loop's test: its operands need no register for the whole loop */
            for (size_t j = 0U; j < 2U; j++) {
                SpTIRValue v = values[j];
                int picked;
                if (v == 0U || v > ir->nvalues || pinned[v] || regs[v] == TA_MEMREG || ta_is_folded(ir, v)) continue;
                picked = jit_ra_alloc(&bank, (int32_t)v);
                if (picked < 0) goto done;
                regs[v] = (uint8_t)picked;
                pinned[v] = 1U;
            }
            break;
        }
    }

    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op == SP_TIR_LOOP) {
            for (size_t k = 0U; k < ir->count; k++) {
                const SpTIRInst *phi = &ir->inst[k];
                if (phi->op == SP_TIR_PHI && phi->b > 0U && phi->b <= ir->nvalues)
                    last[phi->b] = (uint32_t)i;
            }
        } else {
            if (in->a > 0U && in->a <= ir->nvalues && in->op != SP_TIR_PHI)
                last[in->a] = (uint32_t)i;
            if (in->b > 0U && in->b <= ir->nvalues) last[in->b] = (uint32_t)i;
        }
    }

    /* The stores of an iteration happen at its end (ta_emit_pending_stores): their operands stay live until then, whatever later
     * instructions do with the same values (this must come after the pass above, which records the last ordinary use). */
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op != SP_TIR_ASTORE && in->op != SP_TIR_FSTORE) continue;
        if (in->a <= ir->nvalues) last[in->a] = (uint32_t)ir->count - 1U;
        if (in->b <= ir->nvalues) last[in->b] = (uint32_t)ir->count - 1U;
        if (in->aux > 0U && in->aux <= ir->nvalues) last[in->aux] = (uint32_t)ir->count - 1U;
    }

    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        for (uint32_t v = 1U; v <= ir->nvalues; v++) {
            if (!pinned[v] && regs[v] != UINT8_MAX && last[v] < (uint32_t)i) {
                uint8_t r = regs[v];
                if (jit_ra_owner(&bank, (int)r) == (int32_t)v) {
                    jit_ra_release(&bank, (int)r);
                }
            }
        }
        if (in->dst == 0U || in->op == SP_TIR_PARAM || in->op == SP_TIR_PHI) continue;
        if (in->op == SP_TIR_CONST_I64 && ta_is_folded(ir, in->dst)) continue;
        if ((in->op == SP_TIR_ICMP_EQ || in->op == SP_TIR_ICMP_NE || in->op == SP_TIR_ICMP_LT ||
             in->op == SP_TIR_ICMP_LE || in->op == SP_TIR_ICMP_GT || in->op == SP_TIR_ICMP_GE ||
             in->op == SP_TIR_FCMP_EQ || in->op == SP_TIR_FCMP_NE || in->op == SP_TIR_FCMP_LT ||
             in->op == SP_TIR_FCMP_LE || in->op == SP_TIR_FCMP_GT || in->op == SP_TIR_FCMP_GE) &&
            i + 1U < ir->count && ir->inst[i + 1U].op == SP_TIR_GUARD_TRUE &&
            ir->inst[i + 1U].a == in->dst) continue;
        if (in->dst > ir->nvalues) goto done;
        int chosen = -1;
        if (in->a > 0U && in->a <= ir->nvalues && !pinned[in->a] &&
            regs[in->a] != UINT8_MAX && last[in->a] == (uint32_t)i) {
            chosen = regs[in->a];
        } else {
            chosen = jit_ra_alloc(&bank, (int32_t)in->dst);
        }
        if (chosen < 0) goto done;
        if (jit_ra_owner(&bank, chosen) != (int32_t)in->dst &&
            !jit_ra_reassign(&bank, chosen, (int32_t)in->dst)) goto done;
        regs[in->dst] = (uint8_t)chosen;
    }
    *regs_out = regs;
    regs = NULL;
    ok = 1;
done:
    free(regs);
    free(pinned);
    free(last);
    return ok;
}

/* A trace keeps module variables in scratch slots above the frame's operand stack; on every exit the registers holding them are
 * stored there (the snapshot maps only describe the frame's own slots), and jit_trace_site copies them back to vm->slots. */
static int ta_emit_module_stores(const SpTraceIR *ir, const int32_t *phi_local, const uint8_t *regs, uint32_t slot0, TraceAsm *a) {
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op != SP_TIR_PHI || in->dst > ir->nvalues || phi_local[in->dst] < 0 || (uint32_t)phi_local[in->dst] < slot0) continue;
        if (regs[in->dst] == TA_MEMREG) continue;
        if (regs[in->dst] >= 16U || !ta_local_store_reg(a, (uint32_t)phi_local[in->dst], regs[in->dst])) return 0;
    }
    return 1;
}

static int ta_emit_trace_ir(const SpTraceIR *ir, const int32_t *phi_local, unsigned nmod,
                            const SpJitSnapshotSet *snapshot_set, uint8_t slot,
                            TraceRuntimeCells *runtime, TraceAsm *a, size_t *frame_size_out) {
    size_t frame_size = 16U;
    uint8_t *regs = NULL;
    size_t pending[16], npending = 0U;   /* ASTORE instructions deferred to the end of the iteration */
    uint32_t exit_token = 0U, deopt_token = 0U, miss_token = 0U, budget_token = 0U;
    int ok = 0;
    if (!snapshot_set ||
        !sp_jit_snapshot_make_token(slot, (uint8_t)SP_JIT_SNAPSHOT_EXIT, &exit_token) ||
        !sp_jit_snapshot_make_token(slot, (uint8_t)SP_JIT_SNAPSHOT_DEOPT, &deopt_token) ||
        !sp_jit_snapshot_make_token(slot, (uint8_t)SP_JIT_SNAPSHOT_MISS, &miss_token) ||
        !sp_jit_snapshot_make_token(slot, (uint8_t)SP_JIT_SNAPSHOT_BUDGET, &budget_token) ||
        ir->nvalues > 256U || !ta_alloc_regs(ir, phi_local, &regs) || !ta_emit_prologue(a, frame_size)) goto done;

    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        uint8_t dst = in->dst > 0U && in->dst <= ir->nvalues ? regs[in->dst] : UINT8_MAX;
        uint8_t ra = in->a > 0U && in->a <= ir->nvalues ? regs[in->a] : UINT8_MAX;
        uint8_t rb = in->b > 0U && in->b <= ir->nvalues ? regs[in->b] : UINT8_MAX;
        switch (in->op) {
        case SP_TIR_PARAM:
            if (dst == TA_MEMREG) {   /* loop-invariant: only the entry type guard */
                if (in->imm >= snapshot_set->loop_map.slot_count + nmod ||
                    !ta_local_type_guard(a, (uint32_t)in->imm, (uint8_t)T_INT)) goto done;
                break;
            }
            if (dst == UINT8_MAX || in->imm >= snapshot_set->loop_map.slot_count + nmod ||
                !ta_local_type_guard(a, (uint32_t)in->imm,
                    in->type == SP_TIR_T_I64 ? (uint8_t)T_INT :
                    in->type == SP_TIR_T_F64 ? (uint8_t)T_FLOAT :
                    in->type == SP_TIR_T_BOOL ? (uint8_t)T_BOOL : (uint8_t)in->aux) ||
                !ta_local_load_reg(a, (uint32_t)in->imm, dst)) goto done;
            break;
        case SP_TIR_PHI:
            /* The entry PARAM and loop-carried PHI share a pinned native register. */
            break;
        case SP_TIR_CONST_I64: case SP_TIR_CONST_F64:
            if (in->op == SP_TIR_CONST_I64 && ta_is_folded(ir, in->dst)) break;   /* used as an immediate */
            if (dst == UINT8_MAX || !ta_reg_imm(a, dst, in->imm)) goto done;
            break;
        case SP_TIR_CONST_BOOL:
            if (dst == UINT8_MAX || !ta_reg_imm(a, dst, in->imm)) goto done;
            break;
        case SP_TIR_GUARD_TRUE:
            if (ra != UINT8_MAX && (!ta_reg_test(a, ra) ||
                !ta_jcc(a, (in->imm & SP_TIR_GUARD_INVERT) ? 0x85U : 0x84U,
                        (in->imm & SP_TIR_GUARD_DEOPT) ? TA_DEOPT : TA_EXIT))) goto done;
            break;
        case SP_TIR_IADD: case SP_TIR_ISUB: case SP_TIR_IMUL:
            if (rb == UINT8_MAX && dst != UINT8_MAX && ra != UINT8_MAX && ta_is_folded(ir, in->b)) {
                int64_t kb = 0;
                if (!ta_const_i64(ir, in->b, &kb) || !ta_reg_mov(a, dst, ra)) goto done;
                if (in->op == SP_TIR_IMUL ? !ta_imul_imm(a, dst, dst, (int32_t)kb)
                                          : !ta_alu_imm(a, dst, in->op == SP_TIR_IADD ? 0U : 5U, (int32_t)kb)) goto done;
                if (!ta_jcc(a, 0x80U, TA_DEOPT)) goto done;
                break;
            }
            if (rb == TA_MEMREG && dst != UINT8_MAX && ra != UINT8_MAX && ra != TA_MEMREG && phi_local[in->b] >= 0) {
                if (!ta_reg_mov(a, dst, ra)) goto done;
                if (in->op == SP_TIR_IMUL ? !ta_imul_mem(a, dst, (uint32_t)phi_local[in->b])
                                          : !ta_alu_mem(a, dst, in->op == SP_TIR_IADD ? 0x03U : 0x2bU, (uint32_t)phi_local[in->b])) goto done;
                if (!ta_jcc(a, 0x80U, TA_DEOPT)) goto done;
                break;
            }
            if (dst == UINT8_MAX || ra == UINT8_MAX || rb == UINT8_MAX || ra == TA_MEMREG || rb == TA_MEMREG) goto done;
            if (!ta_reg_mov(a, dst, ra)) goto done;
            if (in->op == SP_TIR_IADD) {
                if (!ta_reg_binop(a, dst, rb, 0x01U)) goto done;
            } else if (in->op == SP_TIR_ISUB) {
                if (!ta_reg_binop(a, dst, rb, 0x29U)) goto done;
            } else if (!ta_reg_imul(a, dst, rb)) goto done;
            if (!ta_jcc(a, 0x80U, TA_DEOPT)) goto done;
            break;
        case SP_TIR_INEG:
            if (dst == UINT8_MAX || ra == UINT8_MAX || !ta_reg_mov(a, dst, ra) ||
                !ta_reg_neg(a, dst) || !ta_jcc(a, 0x80U, TA_DEOPT)) goto done;
            break;
        case SP_TIR_ICMP_EQ: case SP_TIR_ICMP_NE: case SP_TIR_ICMP_LT:
        case SP_TIR_ICMP_LE: case SP_TIR_ICMP_GT: case SP_TIR_ICMP_GE: {
            uint8_t cc = ta_cmp_false_cc(in->op);
            const int entry = ta_is_entry_cmp(ir, i);
            if (!entry && !a->label_set[TA_LOOP]) {
                /* Keep the VM's loop budget in a caller-saved register. The
                 * trace has no calls or GC points, so it is written back only
                 * on side exits or when the budget is exhausted. */
                if (!ta_load_budget(a) || !ta_label(a, TA_LOOP)) goto done;
            }
            if (ra == TA_MEMREG && entry && cc != 0U && phi_local[in->a] >= 0 && ta_is_folded(ir, in->b)) {
                int64_t kb = 0;
                if (!ta_const_i64(ir, in->b, &kb) || !ta_cmp_mem_imm(a, (uint32_t)phi_local[in->a], (int32_t)kb)) goto done;
            } else if (rb == TA_MEMREG && ra != UINT8_MAX && ra != TA_MEMREG && cc != 0U && phi_local[in->b] >= 0) {
                if (!ta_alu_mem(a, ra, 0x3bU, (uint32_t)phi_local[in->b])) goto done;
            } else if (rb == UINT8_MAX && ra != UINT8_MAX && cc != 0U && ta_is_folded(ir, in->b)) {
                int64_t kb = 0;
                if (!ta_const_i64(ir, in->b, &kb) || !ta_alu_imm(a, ra, 7U, (int32_t)kb)) goto done;
            } else if (ra == UINT8_MAX || rb == UINT8_MAX || ra == TA_MEMREG || rb == TA_MEMREG || cc == 0U || !ta_reg_cmp(a, ra, rb)) goto done;
            if (dst == UINT8_MAX) {
                if (i + 1U >= ir->count || ir->inst[i + 1U].op != SP_TIR_GUARD_TRUE ||
                    ir->inst[i + 1U].a != in->dst) goto done;
                {
                    const uint64_t gf = ir->inst[i + 1U].imm;
                    /* the guard leaves when the comparison is false (cc), or, inverted, when it is true (setcc code - 0x10 = jcc) */
                    const uint8_t gcc = (gf & SP_TIR_GUARD_INVERT) ? (uint8_t)(ta_cmp_cc(in->op) - 0x10U) : cc;
                    if (!ta_jcc(a, gcc, (gf & SP_TIR_GUARD_DEOPT) ? TA_DEOPT : TA_EXIT)) goto done;
                }
            } else {
                uint8_t truth_cc = ta_cmp_cc(in->op);
                if (truth_cc == 0U || !ta_reg_setcc(a, dst, truth_cc)) goto done;
            }
            break;
        }
        case SP_TIR_LOOP:
            if (!ta_emit_pending_stores(ir, regs, pending, npending, a)) goto done;
            if (!ta_emit_phi_moves(ir, regs, a)) goto done;
            {
                TracePatch patch = ta_patch();
                if (!ta_stencil(a, ST_tr_dec_r11, &patch) ||
                    !ta_jcc(a, 0x84U, TA_BUDGET) || !ta_jmp(a, TA_LOOP)) goto done;
            }
            break;
        case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL: case SP_TIR_FDIV:
            if (dst == UINT8_MAX || ra == UINT8_MAX || rb == UINT8_MAX) goto done;
            if (in->op == SP_TIR_FDIV) {
                /* Division by +/-0 must deopt before the VM raises its normal error. */
                if (!ta_gpr_to_xmm(a, 1U, rb) || !ta_fdiv_zero_guard(a)) goto done;
            }
            if (dst != ra && !ta_reg_mov(a, dst, ra)) goto done;
            if (!ta_f64_binop(a, dst, rb,
                    in->op == SP_TIR_FADD ? 0x58U : in->op == SP_TIR_FSUB ? 0x5cU :
                    in->op == SP_TIR_FMUL ? 0x59U : 0x5eU)) goto done;
            break;
        case SP_TIR_FNEG:
            if (dst == UINT8_MAX || ra == UINT8_MAX ||
                (dst != ra && !ta_reg_mov(a, dst, ra)) || !ta_f64_neg(a, dst)) goto done;
            break;
        case SP_TIR_FCMP_EQ: case SP_TIR_FCMP_NE: case SP_TIR_FCMP_LT:
        case SP_TIR_FCMP_LE: case SP_TIR_FCMP_GT: case SP_TIR_FCMP_GE:
            if (!a->label_set[TA_LOOP]) {
                if (!ta_load_budget(a) || !ta_label(a, TA_LOOP)) goto done;
            }
            if (ra == UINT8_MAX || rb == UINT8_MAX || dst != UINT8_MAX ||
                i + 1U >= ir->count || ir->inst[i + 1U].op != SP_TIR_GUARD_TRUE ||
                ir->inst[i + 1U].a != in->dst || (ir->inst[i + 1U].imm & SP_TIR_GUARD_INVERT) ||
                !ta_f64_compare(a, ra, rb) ||
                !ta_f64_guard_false(a, in->op, (ir->inst[i + 1U].imm & SP_TIR_GUARD_DEOPT) ? TA_DEOPT : TA_EXIT)) goto done;
            break;
        case SP_TIR_ALOAD:
            if (dst >= 16U || ra >= 16U || rb >= 16U || in->imm > 255U) goto done;
            if (!ta_ab_bounds(a, ra, rb) || !ta_jcc(a, 0x83U, TA_DEOPT) || !ta_ab_addr(a, ra, rb) ||
                !ta_ab_tag(a, (uint8_t)in->imm) || !ta_jcc(a, 0x85U, TA_DEOPT) || !ta_ab_load(a, dst)) goto done;
            break;
        case SP_TIR_FLOAD:
            if (dst >= 16U || ra >= 16U || in->imm > 255U) goto done;
            if (!ta_field_tagcmp(a, ra, in->aux, (uint8_t)in->imm) || !ta_jcc(a, 0x85U, TA_DEOPT) ||
                !ta_field_load(a, dst, ra, in->aux)) goto done;
            break;
        case SP_TIR_CGUARD:
            if (ra >= 16U || !(in->aux == 1U ? ta_ref_guard(a, ra, in->imm) : ta_class_guard(a, ra, in->imm))) goto done;
            break;
        case SP_TIR_UCELL:
            if (dst >= 16U || ra >= 16U || !ta_mem_load(a, dst, ra, (uint32_t)offsetof(SFunc, up)) ||
                !ta_mem_load(a, dst, dst, in->aux * 8U)) goto done;
            break;
        case SP_TIR_ASTORE: case SP_TIR_FSTORE:
            if (npending >= sizeof pending / sizeof pending[0]) goto done;
            pending[npending++] = i;
            break;
        case SP_TIR_IDIV: case SP_TIR_IMOD:
            /* floor division / modulo; a zero or -1 divisor deoptimises (the interpreter raises the error, and handles
             * INT64_MIN / -1 without the idiv trap). rax and rdx belong to the division (see ta_has_div). */
            if (dst == UINT8_MAX || ra == UINT8_MAX || rb == UINT8_MAX) goto done;
            {
                int64_t c;
                const int save = ta_uses_rax_rdx(ir, regs);
                if (ta_const_i64(ir, in->b, &c) && c > 0 && (c & (c - 1)) == 0) {
                    /* a power of two: floor division is an arithmetic shift, floor modulo a mask; no divide at all */
                    if (!ta_reg_mov(a, dst, ra)) goto done;
                    if (in->op == SP_TIR_IDIV) {
                        if (c > 1 && !ta_sar_imm(a, dst, (uint8_t)__builtin_ctzll((unsigned long long)c))) goto done;
                    } else if (!ta_reg_imm(a, 10U, (uint64_t)(c - 1)) || !ta_reg_binop(a, dst, 10U, 0x21U)) goto done;
                    break;
                }
                if (ta_const_i64(ir, in->b, &c) && c > 1 && c < ((int64_t)1 << 31)) {
                    /* another small constant divisor: multiply by its reciprocal (nothing to guard) */
                    TracePatch mp = ta_patch();
                    uint64_t magic;
                    int shift = jit_magic_of(c, &magic);
                    mp.q = magic; mp.h[0] = (int32_t)c; mp.b[0] = (uint8_t)shift;
                    if ((save && !ta_plain(a, ST_tr_div_save)) || !ta_reg_mov(a, 0U, ra) ||
                        !ta_stencil(a, in->op == SP_TIR_IDIV ? ST_tr_idiv_magic : ST_tr_imod_magic, &mp) ||
                        (save && !ta_plain(a, ST_tr_div_restore)) || !ta_reg_mov(a, dst, 10U)) goto done;
                    break;
                }
                if (ta_const_i64(ir, in->b, &c) && c > 1) {
                    /* another constant divisor: nothing to guard */
                    if (!ta_reg_imm(a, 10U, (uint64_t)c) || (save && !ta_plain(a, ST_tr_div_save)) || !ta_reg_mov(a, 0U, ra) ||
                        !ta_plain(a, in->op == SP_TIR_IDIV ? ST_tr_idiv_core : ST_tr_imod_core) ||
                        (save && !ta_plain(a, ST_tr_div_restore)) || !ta_reg_mov(a, dst, 10U)) goto done;
                    break;
                }
                if (!ta_reg_mov(a, 10U, rb) || !ta_div_guard(a) || (save && !ta_plain(a, ST_tr_div_save)) ||
                    !ta_reg_mov(a, 0U, ra) ||
                    !ta_plain(a, in->op == SP_TIR_IDIV ? ST_tr_idiv_core : ST_tr_imod_core) ||
                    (save && !ta_plain(a, ST_tr_div_restore)) || !ta_reg_mov(a, dst, 10U)) goto done;
            }
            break;
        case SP_TIR_RETURN:
            goto done;
        default:
            goto done;
        }
    }
    if (!a->label_set[TA_LOOP] || !ta_label(a, TA_EXIT)) goto done;
    if (!ta_emit_snapshot_stores(a, &snapshot_set->snapshots[SP_JIT_SNAPSHOT_EXIT], regs,
                                 ir->nvalues) ||
        !ta_emit_module_stores(ir, phi_local, regs, snapshot_set->loop_map.slot_count, a) ||
        !ta_store_budget(a) || !ta_trace_exit(a, exit_token, runtime)) goto done;
    if (!ta_label(a, TA_DEOPT)) goto done;
    if (!ta_emit_snapshot_stores(a, &snapshot_set->snapshots[SP_JIT_SNAPSHOT_DEOPT], regs,
                                 ir->nvalues) ||
        !ta_emit_module_stores(ir, phi_local, regs, snapshot_set->loop_map.slot_count, a) ||
        !ta_store_budget(a) || !ta_trace_touch(a, runtime) || !ta_return(a, deopt_token)) goto done;
    if (!ta_label(a, TA_MISS) || !ta_trace_touch(a, runtime) || !ta_return(a, miss_token) ||
        !ta_label(a, TA_BUDGET) ||
        !ta_emit_snapshot_stores(a, &snapshot_set->snapshots[SP_JIT_SNAPSHOT_BUDGET], regs,
                                 ir->nvalues) ||
        !ta_emit_module_stores(ir, phi_local, regs, snapshot_set->loop_map.slot_count, a) ||
        !ta_store_budget(a) || !ta_trace_touch(a, runtime) || !ta_return(a, budget_token) ||
        !ta_emit_epilogue(a, frame_size) || !ta_resolve(a)) goto done;
    *frame_size_out = frame_size;
    ok = 1;
done:
    free(regs);
    return ok;
}

typedef struct {
    uint8_t op;
    uint8_t type;
    uint16_t arg;
    uint64_t imm;
} TraceBodyOp;

static int trace_value_type(SpType runtime_type, SpTIRType *tir_type) {
    if (tir_type == NULL) return 0;
    switch (runtime_type) {
    case T_INT: *tir_type = SP_TIR_T_I64; return 1;
    case T_FLOAT: *tir_type = SP_TIR_T_F64; return 1;
    case T_BOOL: *tir_type = SP_TIR_T_BOOL; return 1;
    case T_NIL: case T_STRING: case T_ARRAY: case T_TABLE: case T_FUNCTION:
    case T_CLASS: case T_INSTANCE: case T_MODULE: case T_ITERATOR: case T_COROUTINE:
    case T_ERROR: case T_NATIVE: case T_CELL:
        *tir_type = SP_TIR_T_REF;
        return 1;
    case T_UNINIT:
        return 0;
    default:
        return 0;
    }
}

static uint8_t trace_ir_runtime_type(const SpTraceIR *ir, SpTIRValue value) {
    if (ir == NULL || value == 0U || value > ir->nvalues) return UINT8_MAX;
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->dst != value) continue;
        switch (in->op) {
        case SP_TIR_PARAM: return in->type == SP_TIR_T_REF ? (uint8_t)in->aux :
            (in->type == SP_TIR_T_I64 ? (uint8_t)T_INT :
             in->type == SP_TIR_T_F64 ? (uint8_t)T_FLOAT : (uint8_t)T_BOOL);
        case SP_TIR_PHI: return trace_ir_runtime_type(ir, in->a);
        case SP_TIR_CONST_I64: return (uint8_t)T_INT;
        case SP_TIR_CONST_F64: return (uint8_t)T_FLOAT;
        case SP_TIR_CONST_BOOL: return (uint8_t)T_BOOL;
        case SP_TIR_IADD: case SP_TIR_ISUB: case SP_TIR_IMUL: case SP_TIR_IDIV:
        case SP_TIR_IMOD: case SP_TIR_INEG: return (uint8_t)T_INT;
        case SP_TIR_FADD: case SP_TIR_FSUB: case SP_TIR_FMUL: case SP_TIR_FDIV:
        case SP_TIR_FNEG: return (uint8_t)T_FLOAT;
        case SP_TIR_ICMP_EQ: case SP_TIR_ICMP_NE: case SP_TIR_ICMP_LT:
        case SP_TIR_ICMP_LE: case SP_TIR_ICMP_GT: case SP_TIR_ICMP_GE:
        case SP_TIR_FCMP_EQ: case SP_TIR_FCMP_NE: case SP_TIR_FCMP_LT:
        case SP_TIR_FCMP_LE: case SP_TIR_FCMP_GT: case SP_TIR_FCMP_GE:
            return (uint8_t)T_BOOL;
        case SP_TIR_ALOAD: case SP_TIR_FLOAD: return (uint8_t)in->imm;
        case SP_TIR_UCELL: return (uint8_t)T_CELL;
        case SP_TIR_GUARD_TRUE: case SP_TIR_ASTORE: case SP_TIR_FSTORE: case SP_TIR_CGUARD: case SP_TIR_LOOP: case SP_TIR_RETURN:
            return UINT8_MAX;
        default:
            return UINT8_MAX;
        }
        return UINT8_MAX;
    }
    return UINT8_MAX;
}

static int trace_cmp_ir(int op, int is_float, SpTIROp *out) {
    switch (op) {
    case OP_EQ: *out = is_float ? SP_TIR_FCMP_EQ : SP_TIR_ICMP_EQ; return 1;
    case OP_NE: *out = is_float ? SP_TIR_FCMP_NE : SP_TIR_ICMP_NE; return 1;
    case OP_LT: *out = is_float ? SP_TIR_FCMP_LT : SP_TIR_ICMP_LT; return 1;
    case OP_LE: *out = is_float ? SP_TIR_FCMP_LE : SP_TIR_ICMP_LE; return 1;
    case OP_GT: *out = is_float ? SP_TIR_FCMP_GT : SP_TIR_ICMP_GT; return 1;
    case OP_GE: *out = is_float ? SP_TIR_FCMP_GE : SP_TIR_ICMP_GE; return 1;
    default: return 0;
    }
}

static size_t trace_index_hash(uint32_t header) {
    return (size_t)(((uint64_t)header * UINT64_C(11400714819323198485)) >> 57);
}

static int trace_index_insert(struct JitProto *jp, TraceRegion *region) {
    size_t first_tombstone = TRACE_INDEX_CAP;
    size_t start;
    if (!jp->trace_index) {
        jp->trace_index = calloc(TRACE_INDEX_CAP, sizeof *jp->trace_index);
        if (!jp->trace_index) return 0;
    }
    start = trace_index_hash(region->header);
    for (size_t probe = 0U; probe < TRACE_INDEX_CAP; probe++) {
        size_t at = (start + probe) & (TRACE_INDEX_CAP - 1U);
        struct TraceIndexSlot *slot = &jp->trace_index[at];
        if (slot->state == 1U && slot->header == region->header) {
            slot->region = region;
            return 1;
        }
        if (slot->state == 2U && first_tombstone == TRACE_INDEX_CAP) first_tombstone = at;
        if (slot->state == 0U) {
            if (first_tombstone != TRACE_INDEX_CAP) slot = &jp->trace_index[first_tombstone];
            slot->header = region->header;
            slot->region = region;
            slot->state = 1U;
            return 1;
        }
    }
    if (first_tombstone != TRACE_INDEX_CAP) {
        struct TraceIndexSlot *slot = &jp->trace_index[first_tombstone];
        slot->header = region->header;
        slot->region = region;
        slot->state = 1U;
        return 1;
    }
    return 0;
}

static void trace_index_remove(struct JitProto *jp, uint32_t header) {
    size_t start;
    if (!jp->trace_index) return;
    start = trace_index_hash(header);
    for (size_t probe = 0U; probe < TRACE_INDEX_CAP; probe++) {
        size_t at = (start + probe) & (TRACE_INDEX_CAP - 1U);
        struct TraceIndexSlot *slot = &jp->trace_index[at];
        if (slot->state == 0U) return;
        if (slot->state == 1U && slot->header == header) {
            slot->region = NULL;
            slot->state = 2U;
            return;
        }
    }
}

/* Demotion: a trace that keeps leaving through its deopt exit gains nothing, because every deopt re-runs an iteration in the
 * interpreter (an unpredictable branch made 23x worse than the region JIT in the first measurement). After TRACE_DEOPT_MIN
 * deopts, if fewer than TRACE_DEOPT_ITERS iterations ran per deopt on average, the loop goes back to the region JIT. */
enum { TRACE_DEOPT_MIN = 16, TRACE_DEOPT_ITERS = 512 };

static TraceRegion *trace_find(struct JitProto *jp, uint32_t header) {
    if (jp->trace_index) {
        size_t start = trace_index_hash(header);
        for (size_t probe = 0U; probe < TRACE_INDEX_CAP; probe++) {
            size_t at = (start + probe) & (TRACE_INDEX_CAP - 1U);
            const struct TraceIndexSlot *slot = &jp->trace_index[at];
            if (slot->state == 0U) return NULL;
            if (slot->state == 1U && slot->header == header) return slot->region;
        }
        return NULL;
    }
    for (TraceRegion *t = jp->traces; t; t = t->next)
        if (!t->is_side && t->header == header) return t;
    return NULL;
}

static void trace_mark_used(struct JitProto *jp, TraceRegion *tr) {
    uint64_t used = __atomic_add_fetch(&jp->trace_clock, UINT64_C(1), __ATOMIC_RELAXED);
    __atomic_store_n(&tr->runtime.last_used, used, __ATOMIC_RELAXED);
}

static void trace_update_incoming_links(struct JitProto *jp, TraceRegion *target,
                                        TraceEntry entry) {
    if (jp == NULL || target == NULL) return;
    for (TraceRegion *tr = jp->traces; tr; tr = tr->next) {
        if (tr->link == target)
            __atomic_store_n(&tr->runtime.link_entry, entry, __ATOMIC_RELEASE);
    }
}

static uint64_t trace_signature_hash(const TraceRegion *tr, const SpValue *base,
                                     uint32_t stack_depth) {
    const SpJitSnapshotMap *map;
    uint64_t hash = UINT64_C(1469598103934665603);
    if (tr == NULL || base == NULL) return 0U;
    map = &tr->snapshot_set.loop_map;
    if (map->entry_count == 0U || map->entries == NULL || map->stack_depth != stack_depth) return 0U;
    hash ^= stack_depth;
    hash *= UINT64_C(1099511628211);
    for (uint16_t i = 0U; i < map->entry_count; i++) {
        const SpJitSnapshotEntry *entry = &map->entries[i];
        if (entry->source != (uint8_t)SP_JIT_SNAPSHOT_FROM_IR) continue;
        if (entry->slot >= map->slot_count) return 0U;
        hash ^= ((uint64_t)entry->slot << 8U) | (uint64_t)base[entry->slot].type;
        hash *= UINT64_C(1099511628211);
    }
    return hash == 0U ? UINT64_C(1) : hash;
}

static int trace_signature_matches(const TraceRegion *tr, const SpValue *base,
                                   uint32_t stack_depth) {
    uint64_t hash;
    if (tr == NULL || base == NULL) return 0;
    hash = trace_signature_hash(tr, base, stack_depth);
    if (hash == 0U || hash != tr->signature_hash) return 0;
    const SpJitSnapshotMap *map = &tr->snapshot_set.loop_map;
    for (uint16_t i = 0U; i < map->entry_count; i++) {
        const SpJitSnapshotEntry *entry = &map->entries[i];
        if (entry->source == (uint8_t)SP_JIT_SNAPSHOT_FROM_IR &&
            (entry->slot >= map->slot_count || base[entry->slot].type != entry->runtime_type)) return 0;
    }
    return 1;
}

static TraceRegion *trace_find_signature(TraceRegion *parent, const SpValue *base,
                                         uint32_t stack_depth) {
    if (parent == NULL) return NULL;
    if (trace_signature_matches(parent, base, stack_depth)) return parent;
    for (uint8_t i = 0U; i < parent->side_count; i++) {
        TraceRegion *found = trace_find_signature(parent->sides[i], base, stack_depth);
        if (found != NULL) return found;
    }
    return NULL;
}

/* Side traces form a bounded tree. Keep the total number of descendants per
 * root bounded as well as the per-parent fan-out, so Side-of-Side cannot
 * multiply cache pressure beyond the original four-side budget. */
static unsigned trace_side_total(const TraceRegion *root) {
    unsigned total = 0U;
    if (root == NULL) return 0U;
    for (uint8_t i = 0U; i < root->side_count; i++) {
        const TraceRegion *child = root->sides[i];
        if (child != NULL) total += 1U + trace_side_total(child);
    }
    return total;
}

static TraceRegion *trace_root_region(TraceRegion *region) {
    while (region != NULL && region->parent != NULL) region = region->parent;
    return region;
}

static TraceRegion *trace_choose_miss_parent(TraceRegion *node, uint32_t stack_depth) {
    TraceRegion *best = NULL;
    if (node == NULL) return NULL;
    const SpJitSnapshotMap *map = &node->snapshot_set.loop_map;
    if (map->stack_depth == stack_depth && node->depth < TRACE_SIDE_DEPTH_MAX &&
        node->side_count < TRACE_SIDE_MAX) best = node;
    for (uint8_t i = 0U; i < node->side_count; i++) {
        TraceRegion *candidate = trace_choose_miss_parent(node->sides[i], stack_depth);
        if (candidate != NULL &&
            (best == NULL || candidate->depth > best->depth ||
             (candidate->depth == best->depth &&
              __atomic_load_n(&candidate->runtime.last_used, __ATOMIC_RELAXED) >
              __atomic_load_n(&best->runtime.last_used, __ATOMIC_RELAXED)))) {
            best = candidate;
        }
    }
    return best;
}

static int trace_side_attempted(const TraceRegion *root, uint64_t hash) {
    if (root == NULL || hash == 0U) return 0;
    for (uint8_t i = 0U; i < root->side_attempt_count; i++) {
        if (root->side_attempts[i] == hash) return 1;
    }
    return 0;
}

static int trace_side_attempt_add(TraceRegion *root, uint64_t hash) {
    if (root == NULL || hash == 0U || trace_side_attempted(root, hash) ||
        root->side_attempt_count >= TRACE_SIDE_ATTEMPT_MAX) return 0;
    root->side_attempts[root->side_attempt_count++] = hash;
    return 1;
}

static void trace_side_attempt_remove(TraceRegion *root, uint64_t hash) {
    if (root == NULL || hash == 0U) return;
    for (uint8_t i = 0U; i < root->side_attempt_count; i++) {
        if (root->side_attempts[i] == hash) {
            for (uint8_t j = i; j + 1U < root->side_attempt_count; j++)
                root->side_attempts[j] = root->side_attempts[j + 1U];
            root->side_attempt_count--;
            root->side_attempts[root->side_attempt_count] = 0U;
            return;
        }
    }
}

static int trace_side_attach(TraceRegion *root, TraceRegion *side) {
    TraceRegion *tree_root = trace_root_region(root);
    if (root == NULL || side == NULL || !side->is_side ||
        root->side_count >= TRACE_SIDE_MAX || root->depth >= TRACE_SIDE_DEPTH_MAX ||
        tree_root == NULL || trace_side_total(tree_root) >= TRACE_SIDE_MAX ||
        side->parent != root || side->depth != (uint8_t)(root->depth + 1U) ||
        side->signature_hash == 0U) return 0;
    for (uint8_t i = 0U; i < root->side_count; i++) {
        if (root->sides[i] == NULL || root->sides[i]->signature_hash == side->signature_hash)
            return 0;
    }
    root->sides[root->side_count++] = side;
    (void)trace_side_attempt_add(root, side->signature_hash);
    return 1;
}

static int trace_slot_candidate(struct JitProto *jp, const TraceRegion *protect,
                                uint8_t *slot_out) {
    TraceRegion *oldest = NULL;
    uint64_t oldest_used = UINT64_MAX;
    if (!jp || !slot_out) return 0;
    for (uint8_t i = 0U; i < (uint8_t)SP_JIT_SNAPSHOT_SLOT_COUNT; i++) {
        if (jp->trace_slots[i] == NULL) {
            *slot_out = i;
            return 1;
        }
    }
    for (TraceRegion *tr = jp->traces; tr; tr = tr->next) {
        uint64_t used;
        if (tr == protect) continue;
        used = __atomic_load_n(&tr->runtime.last_used, __ATOMIC_RELAXED);
        if (used < oldest_used) {
            oldest_used = used;
            oldest = tr;
        }
    }
    if (!oldest) return 0;
    *slot_out = oldest->slot;
    return 1;
}

static int trace_cache_evict_slot(struct JitProto *jp, uint8_t slot) {
    TraceRegion *victim;
    TraceRegion **link;
    if (!jp || slot >= SP_JIT_SNAPSHOT_SLOT_COUNT) return 0;
    victim = jp->trace_slots[slot];
    if (victim == NULL) return 1;
    /* A root owns a bounded set of side traces. Evict children first because
     * each child may precede its parent in the global LRU list. */
    {
        while (victim->side_count != 0U) {
            TraceRegion *child = victim->sides[victim->side_count - 1U];
            if (child == NULL || !trace_cache_evict_slot(jp, child->slot)) return 0;
        }
    }
    for (link = &jp->traces; *link && *link != victim; link = &(*link)->next) {}
    if (*link != victim) return 0;
    *link = victim->next;
    jp->trace_slots[slot] = NULL;
    if (victim->is_side) {
        TraceRegion *parent = victim->parent;
        if (parent != NULL) {
            for (uint8_t i = 0U; i < parent->side_count; i++) {
                if (parent->sides[i] == victim) {
                    for (uint8_t j = i; j + 1U < parent->side_count; j++)
                        parent->sides[j] = parent->sides[j + 1U];
                    parent->side_count--;
                    parent->sides[parent->side_count] = NULL;
                    break;
                }
            }
            trace_side_attempt_remove(parent, victim->signature_hash);
            if (parent->side_count == 0U)
                trace_update_incoming_links(jp, parent, parent->entry);
        }
    } else {
        trace_index_remove(jp, victim->header);
    }
    for (TraceRegion *tr = jp->traces; tr; tr = tr->next) {
        if (tr->link == victim) {
            tr->link = NULL;
            __atomic_store_n(&tr->runtime.link_entry, (TraceEntry)NULL, __ATOMIC_RELEASE);
        }
    }
    if (victim->msize <= SIZE_MAX - victim->meta_size) {
        size_t released = victim->msize + victim->meta_size;
        if (jp->trace_bytes >= released) jp->trace_bytes -= released;
        else jp->trace_bytes = 0U;
    } else jp->trace_bytes = 0U;
    if (jp->trace_count > 0U) jp->trace_count--;
    jit_code_unmap(victim->mem, victim->msize);
    sp_jit_snapshot_set_destroy(&victim->snapshot_set);
    free(victim);
    return 1;
}

static int trace_cache_evict_lru(struct JitProto *jp) {
    TraceRegion *oldest = NULL;
    uint64_t oldest_used = UINT64_MAX;
    if (!jp) return 0;
    for (TraceRegion *tr = jp->traces; tr; tr = tr->next) {
        uint64_t used = __atomic_load_n(&tr->runtime.last_used, __ATOMIC_RELAXED);
        if (used < oldest_used) {
            oldest_used = used;
            oldest = tr;
        }
    }
    return oldest ? trace_cache_evict_slot(jp, oldest->slot) : 0;
}

static int trace_cache_make_room(struct JitProto *jp, size_t bytes) {
    if (!jp || bytes > (size_t)TRACE_CACHE_MAX_BYTES) return 0;
    while (jp->trace_count >= (unsigned)TRACE_CACHE_MAX_REGIONS ||
           jp->trace_bytes > (size_t)TRACE_CACHE_MAX_BYTES - bytes) {
        if (!trace_cache_evict_lru(jp)) return 0;
    }
    return 1;
}

/* SPRINT_TRACE_JIT_DEBUG is consulted on hot paths (every loop back edge): read it once */
static const char *trace_debug_env(void) {
    static int state = -1;
    static const char *value;
    if (state < 0) { value = getenv("SPRINT_TRACE_JIT_DEBUG"); state = 1; }
    return value;
}

/* The part every builder shares once the loop body is in the IR: verify, optimise, verify again, apply the f64 gate and map every
 * PHI to its local slot. On failure the caller destroys the IR. */
static int trace_finish_ir(SpTraceIR *ir, uint32_t slot_count, int32_t **phi_local_out) {
    char verify_message[128];
    int32_t *phi_local = NULL;
    if (!sp_tir_verify(ir, verify_message, sizeof verify_message)) {
        if (trace_debug_env()) fprintf(stderr, "trace-jit: initial IR verify: %s\n", verify_message);
        return 0;
    }
    if (!sp_tir_optimize(ir, NULL, NULL)) {
        if (trace_debug_env()) fprintf(stderr, "trace-jit: IR optimize rejected\n");
        return 0;
    }
    if (!sp_tir_verify(ir, verify_message, sizeof verify_message)) {
        if (trace_debug_env()) fprintf(stderr, "trace-jit: optimized IR verify: %s\n", verify_message);
        return 0;
    }
    /* The TraceJIT backend keeps f64 values in general registers and moves them through XMM0/XMM1 around every operation,
     * which measured 2x slower than the region JIT on float loops. Until f64 values are register-allocated in XMM registers
     * (docs/design/tiered-jit.md, phase 1) such loops are left to the region JIT. SPRINT_TRACE_JIT_F64=1 lifts the gate for
     * backend development and the trace regression tests. */
    {
        static int f64_gate = -1;
        if (f64_gate < 0) { const char *e = getenv("SPRINT_TRACE_JIT_F64"); f64_gate = !(e && e[0] && e[0] != '0'); }
        if (f64_gate) {
            for (size_t i = 0U; i < ir->count; i++) {
                const SpTIROp o = ir->inst[i].op;
                if (o == SP_TIR_FADD || o == SP_TIR_FSUB || o == SP_TIR_FMUL || o == SP_TIR_FDIV || o == SP_TIR_FNEG) {
                    if (trace_debug_env()) fprintf(stderr, "trace-jit: f64 trace left to the region JIT (slower in the trace backend)\n");
                    goto fail;
                }
            }
        }
    }

    phi_local = (int32_t *)malloc(((size_t)ir->nvalues + 1U) * sizeof *phi_local);
    if (!phi_local) goto fail;
    for (uint32_t i = 0U; i <= ir->nvalues; i++) phi_local[i] = -1;
    for (size_t i = 0U; i < ir->count; i++) {
        const SpTIRInst *in = &ir->inst[i];
        if (in->op == SP_TIR_PHI) {
            uint32_t param_id = in->a;
            const SpTIRInst *pin = NULL;
            for (size_t k = 0U; k < ir->count; k++) if (ir->inst[k].dst == param_id && ir->inst[k].op == SP_TIR_PARAM) { pin = &ir->inst[k]; break; }
            if (!pin || pin->imm >= (uint64_t)slot_count) goto fail;
            phi_local[in->dst] = (int32_t)pin->imm;
        }
    }
    *phi_local_out = phi_local;
    return 1;
fail:
    free(phi_local);
    return 0;
}

static int trace_build_ir(Proto *p, const SpValue *locals, uint32_t stack_depth,
                          uint32_t header, const TraceStep *steps, unsigned count,
                          SpTraceIR *ir, int32_t **phi_local_out,
                          uint32_t *exit_pc_out, uint32_t *backedge_pc_out) {
    const uint8_t *code = p->ocode ? p->ocode : p->code;
    TraceBodyOp body[256];
    uint8_t *used = NULL;
    SpTIRValue *param = NULL, *phi = NULL, *current = NULL;
    SpTIRValue *stack = NULL;
    size_t stack_capacity;
    uint32_t slot_count;
    int32_t *phi_local = NULL;
    unsigned nbody = 0U, depth = 0U;
    uint32_t pc = header, body_pc = 0U, exit_pc = 0U, backedge_pc = 0U;
    unsigned left_local, right_local = 0U;
    int right_is_local = 0;
    uint64_t right_const = 0U;
    int is_float = 0;
    SpTIROp cmp;
    SpTIRValue cond, rhs;
    int ok = 0;
    int build_stage = 1;

    if (!p || !locals || !code || !steps || count < 2U || count > 256U ||
        p->nlocals <= 0 || p->nlocals > 512 || stack_depth > UINT16_MAX - (uint32_t)p->nlocals) return 0;
    slot_count = (uint32_t)p->nlocals + stack_depth;
    stack_capacity = (size_t)stack_depth + (size_t)count + 4U;
    if (steps[0].proto != p || steps[0].pc >= p->code_len) return 0;
    for (unsigned i = 0U; i < count; i++) {
        if (steps[i].proto != p || steps[i].pc < header || steps[i].pc >= p->code_len ||
            (i != 0U && steps[i].pc <= steps[i - 1U].pc)) return 0;
    }
    build_stage = 2;
    used = (uint8_t *)calloc((size_t)slot_count, sizeof *used);
    param = (SpTIRValue *)calloc((size_t)slot_count, sizeof *param);
    phi = (SpTIRValue *)calloc((size_t)slot_count, sizeof *phi);
    current = (SpTIRValue *)calloc((size_t)slot_count, sizeof *current);
    stack = (SpTIRValue *)calloc(stack_capacity, sizeof *stack);
    if (!used || !param || !phi || !current || !stack) goto done;
    depth = (unsigned)stack_depth;
    /* Entry Operand Stack cells are SSA loop values too.  They may be popped,
     * duplicated, transformed, and restored as long as the backedge height
     * matches the entry height. */
    for (uint32_t i = 0U; i < stack_depth; i++) {
        uint32_t slot = (uint32_t)p->nlocals + i;
        SpTIRType stack_type;
        if (!trace_value_type((SpType)locals[slot].type, &stack_type)) goto done;
        used[slot] = 1U;
    }

    build_stage = 3;
    /* This first TraceJIT tier intentionally specializes the canonical two-operand loop guard. */
    if (pc + 3U > p->code_len || code[pc] != OP_LOAD_LOCAL) goto done;
    left_local = rd16(code + pc + 1U);
    if (left_local >= (unsigned)p->nlocals) goto done;
    if (locals[left_local].type != T_INT && locals[left_local].type != T_FLOAT) goto done;
    is_float = locals[left_local].type == T_FLOAT;
    used[left_local] = 1U;
    pc += 3U;
    if (pc >= p->code_len) goto done;
    if (code[pc] == OP_LOAD_LOCAL) {
        if (pc + 3U > p->code_len) goto done;
        right_local = rd16(code + pc + 1U);
        if (right_local >= (unsigned)p->nlocals) goto done;
        if (locals[right_local].type != locals[left_local].type) goto done;
        used[right_local] = 1U; right_is_local = 1; pc += 3U;
    } else if (code[pc] == OP_SMALLINT) {
        if (pc + 3U > p->code_len) goto done;
        if (is_float) {
            double value = (double)(int16_t)rd16(code + pc + 1U);
            memcpy(&right_const, &value, sizeof right_const);
        } else {
            right_const = (uint64_t)(int64_t)(int16_t)rd16(code + pc + 1U);
        }
        pc += 3U;
    } else if (code[pc] == OP_CONST) {
        unsigned ci;
        if (pc + 3U > p->code_len) goto done;
        ci = rd16(code + pc + 1U);
        if (ci >= (unsigned)p->nconsts) goto done;
        if (is_float) {
            double value;
            if (p->consts[ci].type == T_FLOAT) value = p->consts[ci].as.f;
            else if (p->consts[ci].type == T_INT) value = (double)p->consts[ci].as.i;
            else goto done;
            memcpy(&right_const, &value, sizeof right_const);
        } else {
            if (p->consts[ci].type != T_INT) goto done;
            right_const = (uint64_t)p->consts[ci].as.i;
        }
        pc += 3U;
    } else goto done;
    if (pc >= p->code_len || !trace_cmp_ir(code[pc], is_float, &cmp)) goto done;
    pc++;
    if (pc + 5U > p->code_len || code[pc] != OP_JUMP_IF_FALSE) goto done;
    {
        int32_t off = rd32s(code + pc + 1U);
        int64_t target = (int64_t)pc + 5 + off;
        if (off <= 0 || target <= (int64_t)(pc + 5U) || target >= (int64_t)p->code_len) goto done;
        exit_pc = (uint32_t)target;
    }
    pc += 5U;
    body_pc = pc;
    build_stage = 4;
    /* Depending on the quickened condition form, the recorder can start at
     * the loop header or immediately after the guard.  Both describe the
     * same single-entry loop and the bytecode decoder below remains canonical. */
    if ((steps[0].pc != body_pc && steps[0].pc != header) ||
        steps[count - 1U].pc < body_pc) goto done;

    build_stage = 5;
    while (pc < p->code_len) {
        int op = code[pc];
        int len = op_len(op);
        if (len <= 0 || pc + (uint32_t)len > p->code_len) goto done;
        if (op == OP_JUMP) {
            int32_t off = rd32s(code + pc + 1U);
            int64_t target = (int64_t)pc + 5 + off;
            if (off >= 0 || target != (int64_t)header) goto done;
            backedge_pc = pc;
            pc += 5U;
            break;
        }
        if (nbody >= 256U) goto done;
        body[nbody].op = (uint8_t)op;
        body[nbody].arg = 0U;
        body[nbody].imm = 0;
        switch (op) {
        case OP_LOAD_LOCAL: case OP_STORE_LOCAL:
            body[nbody].arg = (uint16_t)rd16(code + pc + 1U);
            if (body[nbody].arg >= (unsigned)p->nlocals) goto done;
            {
                SpTIRType local_type;
                if (!trace_value_type((SpType)locals[body[nbody].arg].type, &local_type)) goto done;
            }
            used[body[nbody].arg] = 1U;
            break;
        case OP_SMALLINT:
            if (is_float) {
                double value = (double)(int16_t)rd16(code + pc + 1U);
                memcpy(&body[nbody].imm, &value, sizeof body[nbody].imm);
                body[nbody].type = (uint8_t)T_FLOAT;
            } else {
                body[nbody].imm = (uint64_t)(int64_t)(int16_t)rd16(code + pc + 1U);
                body[nbody].type = (uint8_t)T_INT;
            }
            break;
        case OP_CONST: {
            unsigned ci = rd16(code + pc + 1U);
            if (ci >= (unsigned)p->nconsts) goto done;
            if (is_float) {
                double value;
                if (p->consts[ci].type == T_FLOAT) value = p->consts[ci].as.f;
                else if (p->consts[ci].type == T_INT) value = (double)p->consts[ci].as.i;
                else goto done;
                memcpy(&body[nbody].imm, &value, sizeof body[nbody].imm);
                body[nbody].type = (uint8_t)T_FLOAT;
            } else {
                if (p->consts[ci].type != T_INT) goto done;
                body[nbody].imm = (uint64_t)p->consts[ci].as.i;
                body[nbody].type = (uint8_t)T_INT;
            }
            break;
        }
        case OP_NOP: case OP_POP: case OP_DUP: case OP_DUP2:
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_NEG:
        case OP_DIV:
            if (op == OP_DIV && !is_float) goto done;
            break;
        case OP_MOD: case OP_FLOOR_DIV:
            if (is_float) goto done;
            break;
        default:
            goto done;
        }
        nbody++;
        pc += (uint32_t)len;
    }
    if (backedge_pc == 0U || pc != backedge_pc + 5U || nbody == 0U || steps[count - 1U].pc != backedge_pc) goto done;

    build_stage = 6;
    sp_tir_init(ir);
    build_stage = 61;
    for (uint32_t i = 0U; i < slot_count; i++) {
        SpTIRType slot_type;
        if (used[i]) {
            if (!trace_value_type((SpType)locals[i].type, &slot_type) ||
                !sp_tir_emit_param_ex(ir, slot_type, i,
                    slot_type == SP_TIR_T_REF ? locals[i].type : 0U, &param[i])) goto done;
        }
    }
    for (uint32_t i = 0U; i < slot_count; i++) {
        if (used[i]) {
            if (!sp_tir_emit_phi(ir, ir->value_types[param[i]], param[i], &phi[i])) goto done;
            current[i] = phi[i];
        }
    }
    for (uint32_t i = 0U; i < stack_depth; i++)
        stack[i] = phi[(uint32_t)p->nlocals + i];

    build_stage = 62;
    if (right_is_local) rhs = phi[right_local];
    else if (is_float) {
        double value;
        memcpy(&value, &right_const, sizeof value);
        if (!sp_tir_emit_const_f64(ir, value, &rhs)) goto done;
    } else if (!sp_tir_emit_const_i64(ir, (int64_t)right_const, &rhs)) goto done;
    if (!sp_tir_emit_binary(ir, cmp, phi[left_local], rhs, &cond) ||
        !sp_tir_emit_guard_true(ir, cond, exit_pc)) goto done;

    build_stage = 63;
    for (unsigned i = 0U; i < nbody; i++) {
        const TraceBodyOp *op = &body[i];
        SpTIRValue a, b, result;
        switch (op->op) {
        case OP_NOP:
            break;
        case OP_LOAD_LOCAL:
            if ((size_t)depth >= stack_capacity || !current[op->arg]) goto done;
            stack[depth++] = current[op->arg];
            break;
        case OP_STORE_LOCAL:
            if (depth == 0U) goto done;
            current[op->arg] = stack[--depth];
            if (ir->value_types[current[op->arg]] != ir->value_types[phi[op->arg]] ||
                trace_ir_runtime_type(ir, current[op->arg]) != locals[op->arg].type) goto done;
            break;
        case OP_SMALLINT: case OP_CONST:
            if ((size_t)depth >= stack_capacity) goto done;
            if (op->type == (uint8_t)T_FLOAT) {
                double value;
                memcpy(&value, &op->imm, sizeof value);
                if (!sp_tir_emit_const_f64(ir, value, &result)) goto done;
            } else if (!sp_tir_emit_const_i64(ir, (int64_t)op->imm, &result)) goto done;
            stack[depth++] = result;
            break;
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV:
            if (depth < 2U) goto done;
            b = stack[--depth]; a = stack[--depth];
            if (ir->value_types[a] == SP_TIR_T_F64 && ir->value_types[b] == SP_TIR_T_F64) {
                if (!sp_tir_emit_binary(ir,
                    op->op == OP_ADD ? SP_TIR_FADD : op->op == OP_SUB ? SP_TIR_FSUB :
                    op->op == OP_MUL ? SP_TIR_FMUL : SP_TIR_FDIV, a, b, &result)) goto done;
            } else if (ir->value_types[a] == SP_TIR_T_I64 && ir->value_types[b] == SP_TIR_T_I64 &&
                       op->op != OP_DIV) {
                if (!sp_tir_emit_binary(ir,
                    op->op == OP_ADD ? SP_TIR_IADD : op->op == OP_SUB ? SP_TIR_ISUB : SP_TIR_IMUL,
                    a, b, &result)) goto done;
            } else goto done;
            stack[depth++] = result;
            break;
        case OP_MOD: case OP_FLOOR_DIV:
            if (depth < 2U) goto done;
            b = stack[--depth]; a = stack[--depth];
            if (ir->value_types[a] != SP_TIR_T_I64 || ir->value_types[b] != SP_TIR_T_I64 ||
                !sp_tir_emit_binary(ir, op->op == OP_MOD ? SP_TIR_IMOD : SP_TIR_IDIV, a, b, &result)) goto done;
            stack[depth++] = result;
            break;
        case OP_NEG:
            if (depth == 0U) goto done;
            a = stack[--depth];
            if (ir->value_types[a] == SP_TIR_T_F64) {
                if (!sp_tir_emit_unary(ir, SP_TIR_FNEG, a, &result)) goto done;
            } else if (ir->value_types[a] == SP_TIR_T_I64) {
                if (!sp_tir_emit_unary(ir, SP_TIR_INEG, a, &result)) goto done;
            } else goto done;
            stack[depth++] = result;
            break;
        case OP_POP:
            if (depth == 0U) goto done;
            depth--;
            break;
        case OP_DUP:
            if (depth == 0U || (size_t)depth >= stack_capacity) goto done;
            stack[depth] = stack[depth - 1U]; depth++;
            break;
        case OP_DUP2:
            if (depth < 2U || (size_t)depth + 2U > stack_capacity) goto done;
            stack[depth] = stack[depth - 2U]; stack[depth + 1U] = stack[depth - 1U]; depth += 2U;
            break;
        default:
            goto done;
        }
    }
    if (depth != stack_depth) goto done;
    for (uint32_t i = 0U; i < slot_count; i++) {
        if (used[i] && !sp_tir_set_phi_backedge(ir, phi[i], current[i])) goto done;
    }
    build_stage = 64;
    if (!sp_tir_emit_loop(ir)) goto done;
    build_stage = 65;
    if (!trace_finish_ir(ir, slot_count, &phi_local)) goto done;
    *phi_local_out = phi_local; phi_local = NULL;
    *exit_pc_out = exit_pc;
    *backedge_pc_out = backedge_pc;
    ok = 1;
    p->trace_any = 1;
done:
    if (!ok) {
        const char *debug_env = trace_debug_env();
        if (debug_env && debug_env[0] && debug_env[0] != '0')
            (void)fprintf(stderr, "trace-jit: IR build stage=%d header=%u pc=%u body=%u backedge=%u count=%u nbody=%u depth=%u first=%u last=%u op=%u\n",
                          build_stage, header, pc, body_pc, backedge_pc, count, nbody, depth,
                          count ? steps[0].pc : 0U, count ? steps[count - 1U].pc : 0U,
                          pc < p->code_len ? (unsigned)code[pc] : 0U);
    }
    if (used) free(used);
    if (param) free(param);
    if (phi) free(phi);
    if (current) free(current);
    if (stack) free(stack);
    if (phi_local) free(phi_local);
    if (!ok) sp_tir_destroy(ir);
    return ok;
}

/* ---- general path builder ---------------------------------------------------------------------------------------------
 * trace_build_ir above only understands "while LOCAL <cmp> LOCAL/CONST" with a straight-line body of one numeric type. This builder
 * follows the path the recorder actually executed instead: it walks the pristine bytecode from the loop header, decides every
 * conditional branch from the next recorded step, and turns each one into a guard in the direction that was observed. Locals are
 * loop-carried SSA values exactly as before. A guard that fails leaves through the deopt exit (the iteration-start state is
 * restored and the interpreter re-runs the iteration, which is sound because an iteration only changes locals), except the first
 * guard of an iteration when it leaves the loop: that one uses the loop exit and resumes right after the loop.
 * Supported: LOAD/STORE_LOCAL, int and float constants, + - * (same type), float /, int // and %, unary -, comparisons that feed a
 * conditional jump, forward JUMP / JUMP_IF_FALSE / JUMP_IF_TRUE, POP / DUP / DUP2. Anything else rejects the trace. */
typedef struct {
    uint32_t pc;
    uint32_t target;  /* conditional jumps: where the jump goes */
    uint16_t arg;
    uint8_t op, taken;
    uint8_t lvl;          /* inlining depth: 0 = the loop's own function */
    Proto *proto;         /* the function the instruction belongs to */
    Proto *callee;        /* OP_CALL: the inlined callee */
} PathOp;

/* Pending field writes of the iteration (object value + byte offset -> value): later reads of the same location take the
 * written value; a read or write of the same offset through another object might alias, so the trace is refused. */
typedef struct {
    SpTIRValue obj[16], val[16];
    uint32_t off[16];
    unsigned n;
} FieldState;
static int trace_field_access(SpTraceIR *ir, FieldState *fs, int is_set, SpTIRValue obj, uint32_t off, SpTIRValue v,
                              SpTIRType fty, uint8_t tag, SpTIRValue *out) {
    if (is_set) {
        for (unsigned k = 0U; k < fs->n; k++) if (fs->off[k] == off && fs->obj[k] != obj) return 0;
        if (fs->n >= 16U || !sp_tir_emit_fstore(ir, obj, off, v)) return 0;
        fs->obj[fs->n] = obj; fs->off[fs->n] = off; fs->val[fs->n] = v; fs->n++;
        return 1;
    }
    for (unsigned k = 0U; k < fs->n; k++) {
        if (fs->off[k] != off) continue;
        if (fs->obj[k] != obj) return 0;
        *out = fs->val[k];
        return 1;
    }
    return sp_tir_emit_fload(ir, fty, tag, obj, off, out);
}

static int trace_build_ir_path(Proto *p, const SpValue *locals, const SpValue *mslots, uint32_t stack_depth, uint32_t header,
                               const TraceStep *steps, unsigned count, SpTraceIR *ir,
                               int32_t **phi_local_out, uint32_t *exit_pc_out, uint32_t *backedge_pc_out,
                               unsigned *nmod_out, uint16_t *mod_idx_out) {
    const uint8_t *code = p->ocode ? p->ocode : p->code;
    PathOp path[256];
    unsigned np = 0U;
    uint8_t *used = NULL;
    SpTIRValue *param = NULL, *phi = NULL, *current = NULL, *stack = NULL;
    int32_t *phi_local = NULL;
    uint32_t slot_count, backedge = 0U, exit_pc = 0U;
    size_t stack_capacity;
    unsigned depth;
    int have_exit = 0, stored = 0, array_stored = 0, ok = 0;
    /* Module variables: the trace keeps them in scratch slots just above the frame's operand stack (slot_count + k); jit_trace_site
     * copies them in from vm->slots before the trace runs and back afterwards. LOAD_MODULE / STORE_MODULE become local accesses
     * of those scratch slots. */
    uint16_t mod_idx[8];
    unsigned nmod = 0U, slot_total;
#define SLOTV(I) ((I) < slot_count ? locals[(I)] : mslots[mod_idx[(I) - slot_count]])
    const SArray **vhint = NULL;   /* per SSA value: the array object it held when the trace was recorded (element types come from it) */
    FieldState fs;
    const SFunc **fhint = NULL;       /* per SSA value: the closure it held at recording time (identity guarded when called) */
    SpTIRValue fl[4][64];             /* locals of the inlined frames (index = inlining depth) */
    const SFunc *ffh[4];
    SpTIRValue ffn[4];
    unsigned fbase[4], blvl = 0U;
    struct { SpTIRValue fn, cell; uint32_t idx; } ucm[16];
    unsigned nucm = 0U;
    const SInstance **ihint = NULL;   /* per SSA value: the instance it held at recording time (its class is guarded in the trace) */
    const char *why = "path builder: unsupported";

    if (!p || !locals || !code || !steps || count < 2U || count > 256U || p->nlocals <= 0 || p->nlocals > 512 ||
        stack_depth > UINT16_MAX - (uint32_t)p->nlocals || steps[0].proto != p) return 0;
    slot_count = (uint32_t)p->nlocals + stack_depth;
    {
        uint32_t last_root = 0U;
        int have_root = 0;
        for (unsigned i = 0U; i < count; i++) {   /* steps of inlined callees are checked when the path is walked */
            if (steps[i].proto != p) continue;
            if (i > 0U && steps[i - 1U].proto == p && steps[i - 1U].pc == steps[i].pc) continue;   /* a re-dispatched call */
            if (steps[i].pc < header || steps[i].pc >= p->code_len || (have_root && steps[i].pc <= last_root)) return 0;
            last_root = steps[i].pc; have_root = 1;
        }
        if (steps[count - 1U].proto != p) return 0;
    }

    /* 1. follow the executed path through the bytecode */
    {
        uint32_t pc = header, saved_pc[4];
        Proto *wp = p, *saved_p[4];
        const uint8_t *wc = code;
        unsigned lvl = 0U, cur = 0U;
        for (;;) {
            int op, len;
            PathOp *po;
            if (pc >= wp->code_len || np >= 256U) { why = "path too long"; goto done; }
            op = wc[pc];
            len = op_len(op);
            if (len <= 0 || pc + (uint32_t)len > wp->code_len) { why = "bad instruction"; goto done; }
            po = &path[np++];
            po->pc = pc; po->op = (uint8_t)op; po->lvl = (uint8_t)lvl; po->proto = wp; po->callee = NULL; po->arg = 0U; po->taken = 0U; po->target = 0U;
            switch (op) {
            case OP_JUMP: {
                int32_t off = rd32s(wc + pc + 1U);
                int64_t t = (int64_t)pc + 5 + off;
                if (lvl > 0U) { why = "jump in an inlined callee"; goto done; }
                if (off < 0) {
                    if (t != (int64_t)header) { why = "backward jump is not the loop edge"; goto done; }
                    backedge = pc;
                    goto walked;
                }
                if (t >= (int64_t)wp->code_len) goto done;
                pc = (uint32_t)t;
                continue;
            }
            case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE: {
                int32_t off = rd32s(wc + pc + 1U);
                int64_t t = (int64_t)pc + 5 + off;
                uint32_t next = UINT32_MAX;
                if (lvl > 0U) { why = "branch in an inlined callee"; goto done; }
                if (off <= 0 || t >= (int64_t)wp->code_len) goto done;
                for (unsigned k = 0U; k < count; k++)
                    if (steps[k].proto == p && steps[k].pc > pc && steps[k].pc < next) next = steps[k].pc;
                if (next == (uint32_t)t) po->taken = 1U;
                else if (next != pc + 5U) { why = "cannot tell the branch direction"; goto done; }
                po->target = (uint32_t)t;
                pc = po->taken ? (uint32_t)t : pc + 5U;
                continue;
            }
            case OP_LOAD_LOCAL: case OP_STORE_LOCAL:
                po->arg = (uint16_t)rd16(wc + pc + 1U);
                if (po->arg >= (unsigned)wp->nlocals) goto done;
                break;
            case OP_LOAD_MODULE: case OP_STORE_MODULE: {
                unsigned idx = rd16(wc + pc + 1U), k;
                if (mslots == NULL || lvl > 0U) goto done;
                for (k = 0U; k < nmod && mod_idx[k] != idx; k++) {}
                if (k == nmod) {
                    if (nmod >= 8U) { why = "too many module variables"; goto done; }
                    mod_idx[nmod++] = (uint16_t)idx;
                }
                po->op = op == OP_LOAD_MODULE ? (uint8_t)OP_LOAD_LOCAL : (uint8_t)OP_STORE_LOCAL;
                po->arg = (uint16_t)(slot_count + k);
                break;
            }
            case OP_RANGE_NEXT: {
                if (lvl > 0U) goto done;   /* for i in range(...): state in locals arg, arg+1, arg+2 = cur, stop, step */
                int32_t off = rd32s(wc + pc + 3U);
                int64_t t = (int64_t)pc + 7 + off;
                po->arg = (uint16_t)rd16(wc + pc + 1U);
                if (off <= 0 || t >= (int64_t)wp->code_len || (unsigned)po->arg + 2U >= (unsigned)wp->nlocals) goto done;
                po->target = (uint32_t)t;
                break;
            }
            case OP_SMALLINT:
                po->arg = (uint16_t)rd16(wc + pc + 1U);
                break;
            case OP_CONST:
                po->arg = (uint16_t)rd16(wc + pc + 1U);
                if (po->arg >= (unsigned)wp->nconsts || (wp->consts[po->arg].type != T_INT && wp->consts[po->arg].type != T_FLOAT)) goto done;
                break;
            case OP_GET_MEMBER: case OP_SET_MEMBER:
                po->arg = (uint16_t)rd16(wc + pc + 1U);
                if (po->arg >= (unsigned)wp->nconsts || wp->consts[po->arg].type != T_STRING) goto done;
                break;
            case OP_LOAD_UPVAL: case OP_STORE_UPVAL:
                po->arg = (uint16_t)rd16(wc + pc + 1U);
                if (lvl == 0U) goto done;
                break;
            case OP_CALL: {
                unsigned k = cur;
                Proto *cp;
                if (lvl >= 3U || pc + 2U > wp->code_len) { why = "call nesting"; goto done; }
                po->arg = (uint16_t)wc[pc + 1U];
                while (k < count && !(steps[k].proto == wp && steps[k].pc == pc)) k++;
                while (k < count && steps[k].proto == wp && steps[k].pc == pc) k++;
                if (k >= count || steps[k].pc != 0U) { why = "call did not enter a function"; goto done; }
                cp = (Proto *)(uintptr_t)steps[k].proto;
                if (cp == NULL || cp->nlocals > 64 || cp->nparams != (int)po->arg || cp->has_rest || cp->ndefaults != 0 ||
                    cp->nrequired != cp->nparams || cp->nlocals < cp->nparams) { why = "callee shape"; goto done; }
                po->callee = cp;
                saved_pc[lvl] = pc + 2U; saved_p[lvl] = wp;
                lvl++;
                wp = cp; wc = cp->ocode ? cp->ocode : cp->code; pc = 0U; cur = k;
                continue;
            }
            case OP_RETURN:
                if (lvl == 0U) goto done;
                lvl--;
                wp = saved_p[lvl]; wc = wp->ocode ? wp->ocode : wp->code; pc = saved_pc[lvl];
                continue;
            case OP_NOP: case OP_POP: case OP_DUP: case OP_DUP2:
            case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_FLOOR_DIV: case OP_MOD: case OP_NEG:
            case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE:
            case OP_GET_INDEX: case OP_SET_INDEX: case OP_TRUE: case OP_FALSE:
                break;
            default:
                why = "unsupported bytecode";
                goto done;
            }
            pc += (uint32_t)len;
        }
    }
walked:
    /* the walk must be the recorded path: every recorded step is an instruction of it, and the last one is the back edge */
    if (steps[count - 1U].pc != backedge) { why = "path does not end at the back edge"; goto done; }
    for (unsigned k = 0U; k < count; k++) {
        int found = 0;
        for (unsigned i = 0U; i < np && !found; i++) found = path[i].pc == steps[k].pc && path[i].proto == steps[k].proto;
        if (!found) { why = "walked path differs from the recorded one"; goto done; }
    }

    /* 2. which slots are loop-carried */
    stack_capacity = (size_t)stack_depth + (size_t)np + 4U;
    slot_total = slot_count + nmod;
    used = (uint8_t *)calloc((size_t)slot_total, sizeof *used);
    param = (SpTIRValue *)calloc((size_t)slot_total, sizeof *param);
    phi = (SpTIRValue *)calloc((size_t)slot_total, sizeof *phi);
    current = (SpTIRValue *)calloc((size_t)slot_total, sizeof *current);
    stack = (SpTIRValue *)calloc(stack_capacity, sizeof *stack);
    fhint = (const SFunc **)calloc((size_t)slot_total * 2U + (size_t)np * 3U + 16U, sizeof *fhint);
    ihint = (const SInstance **)calloc((size_t)slot_total * 2U + (size_t)np * 3U + 16U, sizeof *ihint);
    vhint = (const SArray **)calloc((size_t)slot_total * 2U + (size_t)np * 3U + 16U, sizeof *vhint);
    if (!used || !param || !phi || !current || !stack || !vhint || !ihint || !fhint) goto done;
    memset(&fs, 0, sizeof fs);
    memset(fl, 0, sizeof fl);
    for (uint32_t i = 0U; i < stack_depth; i++) {
        SpTIRType t;
        if (!trace_value_type((SpType)locals[(uint32_t)p->nlocals + i].type, &t)) goto done;
        used[(uint32_t)p->nlocals + i] = 1U;
    }
    for (unsigned i = 0U; i < np; i++) {
        if (path[i].lvl == 0U && (path[i].op == OP_LOAD_LOCAL || path[i].op == OP_STORE_LOCAL)) {
            SpTIRType t;
            if (!trace_value_type((SpType)SLOTV(path[i].arg).type, &t)) goto done;
            used[path[i].arg] = 1U;
        }
        if (path[i].op == OP_RANGE_NEXT) {
            for (unsigned k = 0U; k < 3U; k++) {
                if (locals[path[i].arg + k].type != T_INT) { why = "range state is not an int"; goto done; }
                used[path[i].arg + k] = 1U;
            }
            if (locals[path[i].arg + 2U].as.i == 0) goto done;
        }
    }

    /* 3. parameters, phis, then the body in path order */
    sp_tir_init(ir);
    for (uint32_t i = 0U; i < slot_total; i++) {
        SpTIRType t;
        if (!used[i]) continue;
        if (!trace_value_type((SpType)SLOTV(i).type, &t) ||
            !sp_tir_emit_param_ex(ir, t, i, t == SP_TIR_T_REF ? SLOTV(i).type : 0U, &param[i])) goto done;
    }
    for (uint32_t i = 0U; i < slot_total; i++) {
        if (!used[i]) continue;
        if (!sp_tir_emit_phi(ir, ir->value_types[param[i]], param[i], &phi[i])) goto done;
        current[i] = phi[i];
        if (SLOTV(i).type == T_ARRAY) vhint[phi[i]] = AS_ARRAY(SLOTV(i));
        if (SLOTV(i).type == T_INSTANCE) ihint[phi[i]] = AS_INSTANCE(SLOTV(i));
        if (SLOTV(i).type == T_FUNCTION) fhint[phi[i]] = AS_FUNC(SLOTV(i));
    }
    depth = stack_depth;
    for (uint32_t i = 0U; i < stack_depth; i++) stack[i] = phi[(uint32_t)p->nlocals + i];

    for (unsigned i = 0U; i < np; i++) {
        const PathOp *po = &path[i];
        SpTIRValue a = 0U, b = 0U, r = 0U;
        switch (po->op) {
        case OP_JUMP: case OP_NOP: break;
        case OP_LOAD_LOCAL:
            if (blvl > 0U) {
                if (depth >= stack_capacity || !fl[blvl][po->arg]) goto done;
                stack[depth++] = fl[blvl][po->arg];
                break;
            }
            if (depth >= stack_capacity || !current[po->arg]) goto done;
            stack[depth++] = current[po->arg];
            break;
        case OP_STORE_LOCAL:
            if (depth == 0U) goto done;
            if (blvl > 0U) { fl[blvl][po->arg] = stack[--depth]; stored = 1; break; }
            current[po->arg] = stack[--depth];
            if (ir->value_types[current[po->arg]] != ir->value_types[phi[po->arg]] ||
                trace_ir_runtime_type(ir, current[po->arg]) != SLOTV(po->arg).type) { why = "a local changes type"; goto done; }
            stored = 1;
            break;
        case OP_SMALLINT:
            if (depth >= stack_capacity || !sp_tir_emit_const_i64(ir, (int64_t)(int16_t)po->arg, &r)) goto done;
            stack[depth++] = r;
            break;
        case OP_CONST:
            if (depth >= stack_capacity) goto done;
            if (po->proto->consts[po->arg].type == T_FLOAT ? !sp_tir_emit_const_f64(ir, po->proto->consts[po->arg].as.f, &r)
                                                           : !sp_tir_emit_const_i64(ir, po->proto->consts[po->arg].as.i, &r)) goto done;
            stack[depth++] = r;
            break;
        case OP_TRUE: case OP_FALSE:
            if (depth >= stack_capacity || !sp_tir_emit_const_bool(ir, po->op == OP_TRUE, &r)) goto done;
            stack[depth++] = r;
            break;
        case OP_POP:
            if (depth == 0U) goto done;
            depth--;
            break;
        case OP_DUP:
            if (depth == 0U || depth >= stack_capacity) goto done;
            stack[depth] = stack[depth - 1U]; depth++;
            break;
        case OP_DUP2:
            if (depth < 2U || (size_t)depth + 2U > stack_capacity) goto done;
            stack[depth] = stack[depth - 2U]; stack[depth + 1U] = stack[depth - 1U]; depth += 2U;
            break;
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_FLOOR_DIV: case OP_MOD: {
            SpTIRType ta, tb;
            int isf;
            if (depth < 2U) goto done;
            b = stack[--depth]; a = stack[--depth];
            ta = ir->value_types[a]; tb = ir->value_types[b];
            if (ta != tb || (ta != SP_TIR_T_I64 && ta != SP_TIR_T_F64)) { why = "mixed or non-numeric operands"; goto done; }
            isf = ta == SP_TIR_T_F64;
            if (po->op == OP_DIV ? !isf : (po->op == OP_FLOOR_DIV || po->op == OP_MOD) ? isf : 0) goto done;
            if (!sp_tir_emit_binary(ir,
                    po->op == OP_ADD ? (isf ? SP_TIR_FADD : SP_TIR_IADD) :
                    po->op == OP_SUB ? (isf ? SP_TIR_FSUB : SP_TIR_ISUB) :
                    po->op == OP_MUL ? (isf ? SP_TIR_FMUL : SP_TIR_IMUL) :
                    po->op == OP_DIV ? SP_TIR_FDIV : po->op == OP_FLOOR_DIV ? SP_TIR_IDIV : SP_TIR_IMOD, a, b, &r)) goto done;
            stack[depth++] = r;
            break;
        }
        case OP_NEG:
            if (depth == 0U) goto done;
            a = stack[--depth];
            if (ir->value_types[a] == SP_TIR_T_F64 ? !sp_tir_emit_unary(ir, SP_TIR_FNEG, a, &r)
              : ir->value_types[a] == SP_TIR_T_I64 ? !sp_tir_emit_unary(ir, SP_TIR_INEG, a, &r) : 1) goto done;
            stack[depth++] = r;
            break;
        case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE: {
            SpTIROp cmp;
            SpTIRType ta, tb;
            if (depth < 2U || i + 1U >= np ||
                (path[i + 1U].op != OP_JUMP_IF_FALSE && path[i + 1U].op != OP_JUMP_IF_TRUE)) { why = "comparison not feeding a branch"; goto done; }
            b = stack[--depth]; a = stack[--depth];
            ta = ir->value_types[a]; tb = ir->value_types[b];
            if (ta != tb || (ta != SP_TIR_T_I64 && ta != SP_TIR_T_F64) ||
                !trace_cmp_ir(po->op, ta == SP_TIR_T_F64, &cmp) || !sp_tir_emit_binary(ir, cmp, a, b, &r)) goto done;
            stack[depth++] = r;
            break;
        }
        case OP_GET_INDEX: {
            const SArray *h;
            SpTIRType ety;
            uint8_t etag;
            SpValue e0;
            if (depth < 2U) goto done;
            b = stack[--depth]; a = stack[--depth];
            h = (a <= ir->nvalues + 0U && a < (uint32_t)slot_total * 2U + (uint32_t)np * 3U + 16U) ? vhint[a] : NULL;
            if (ir->value_types[a] != SP_TIR_T_REF || trace_ir_runtime_type(ir, a) != (uint8_t)T_ARRAY ||
                ir->value_types[b] != SP_TIR_T_I64 || h == NULL || h->len <= 0) { why = "array read: unknown array or index type"; goto done; }
            if (array_stored) { why = "array read after a write in the same iteration"; goto done; }
            e0 = h->items[0];
            switch (e0.type) {
            case T_INT: ety = SP_TIR_T_I64; break;
            case T_FLOAT: ety = SP_TIR_T_F64; break;
            case T_BOOL: ety = SP_TIR_T_BOOL; break;
            case T_ARRAY: ety = SP_TIR_T_REF; break;
            case T_NIL: case T_STRING: case T_TABLE: case T_FUNCTION: case T_CLASS: case T_INSTANCE: case T_MODULE:
            case T_ITERATOR: case T_COROUTINE: case T_ERROR: case T_NATIVE: case T_CELL: case T_UNINIT:
                why = "array element type"; goto done;
            default: why = "array element type"; goto done;
            }
            etag = (uint8_t)e0.type;
            if (!sp_tir_emit_aload(ir, ety, etag, a, b, &r)) goto done;
            if (e0.type == T_ARRAY && r < (uint32_t)slot_total * 2U + (uint32_t)np * 3U + 16U) vhint[r] = AS_ARRAY(e0);
            stack[depth++] = r;
            break;
        }
        case OP_GET_MEMBER: case OP_SET_MEMBER: {
            const SInstance *h;
            SpValue sv;
            SpTIRValue v = 0U;
            SpTIRType fty = SP_TIR_T_I64;
            uint32_t foff;
            const int is_set = po->op == OP_SET_MEMBER;
            if (depth < (is_set ? 2U : 1U)) goto done;
            if (is_set) v = stack[--depth];
            a = stack[--depth];
            h = a < (uint32_t)slot_total * 2U + (uint32_t)np * 3U + 16U ? ihint[a] : NULL;
            if (h == NULL || ir->value_types[a] != SP_TIR_T_REF || trace_ir_runtime_type(ir, a) != (uint8_t)T_INSTANCE) {
                why = "member access: receiver is not a known instance"; goto done;
            }
            if (!table_get_sstr(h->cls->fields, AS_STR(po->proto->consts[po->arg]), &sv) || sv.as.i < 0 || sv.as.i >= h->nslots) {
                why = "member access: not a field"; goto done;
            }
            foff = (uint32_t)(offsetof(SInstance, slots) + (size_t)sv.as.i * sizeof(SpValue));
            if (!sp_tir_emit_cguard(ir, a, (uint64_t)(uintptr_t)h->cls)) goto done;
            if (is_set) {
                if (ir->value_types[v] == SP_TIR_T_REF) { why = "member write of a reference"; goto done; }
                if (!trace_field_access(ir, &fs, 1, a, foff, v, fty, 0U, NULL)) { why = "field write"; goto done; }
                array_stored = 1;
            } else {
                switch (h->slots[sv.as.i].type) {
                case T_INT: fty = SP_TIR_T_I64; break;
                case T_FLOAT: fty = SP_TIR_T_F64; break;
                case T_BOOL: fty = SP_TIR_T_BOOL; break;
                default: why = "member read: field type"; goto done;
                }
                if (!trace_field_access(ir, &fs, 0, a, foff, 0U, fty, (uint8_t)h->slots[sv.as.i].type, &r)) {
                    why = "member read may alias a pending write"; goto done;
                }
                stack[depth++] = r;
            }
            break;
        }
        case OP_LOAD_UPVAL: case OP_STORE_UPVAL: {
            const SCell *cell;
            SpTIRValue cv = 0U, v = 0U;
            SpTIRType fty = SP_TIR_T_I64;
            unsigned k;
            const int is_set = po->op == OP_STORE_UPVAL;
            if (blvl == 0U || ffh[blvl] == NULL || po->arg >= (unsigned)ffh[blvl]->nup) goto done;
            cell = ffh[blvl]->up[po->arg];
            if (cell == NULL) goto done;
            for (k = 0U; k < nucm; k++) if (ucm[k].fn == ffn[blvl] && ucm[k].idx == po->arg) { cv = ucm[k].cell; break; }
            if (cv == 0U) {
                if (nucm >= 16U || !sp_tir_emit_ucell(ir, ffn[blvl], po->arg, &cv)) goto done;
                ucm[nucm].fn = ffn[blvl]; ucm[nucm].idx = po->arg; ucm[nucm].cell = cv; nucm++;
            }
            if (is_set) {
                if (depth == 0U) goto done;
                v = stack[--depth];
                if (ir->value_types[v] == SP_TIR_T_REF) { why = "upvalue write of a reference"; goto done; }
                if (!trace_field_access(ir, &fs, 1, cv, (uint32_t)offsetof(SCell, v), v, fty, 0U, NULL)) { why = "upvalue write"; goto done; }
                array_stored = 1;
            } else {
                if (depth >= stack_capacity) goto done;
                switch (cell->v.type) {
                case T_INT: fty = SP_TIR_T_I64; break;
                case T_FLOAT: fty = SP_TIR_T_F64; break;
                case T_BOOL: fty = SP_TIR_T_BOOL; break;
                default: why = "upvalue type"; goto done;
                }
                if (!trace_field_access(ir, &fs, 0, cv, (uint32_t)offsetof(SCell, v), 0U, fty, (uint8_t)cell->v.type, &r)) {
                    why = "upvalue read may alias a pending write"; goto done;
                }
                stack[depth++] = r;
            }
            break;
        }
        case OP_CALL: {
            SpTIRValue args[16], fv;
            const SFunc *fh;
            unsigned n = po->arg;
            if (n > 16U || depth < n + 1U || blvl >= 3U) goto done;
            for (unsigned k = n; k > 0U; k--) args[k - 1U] = stack[--depth];
            fv = stack[--depth];
            fh = fv < (uint32_t)slot_total * 2U + (uint32_t)np * 3U + 16U ? fhint[fv] : NULL;
            if (fh == NULL || ir->value_types[fv] != SP_TIR_T_REF || trace_ir_runtime_type(ir, fv) != (uint8_t)T_FUNCTION ||
                fh->proto != po->callee) { why = "call: callee is not a known closure"; goto done; }
            if (!sp_tir_emit_rguard(ir, fv, (uint64_t)(uintptr_t)fh)) goto done;
            blvl++;
            ffn[blvl] = fv; ffh[blvl] = fh; fbase[blvl] = depth;
            memset(fl[blvl], 0, sizeof fl[blvl]);
            for (unsigned k = 0U; k < n; k++) fl[blvl][k] = args[k];
            break;
        }
        case OP_RETURN:
            if (blvl == 0U || depth == 0U || depth <= fbase[blvl]) goto done;
            r = stack[depth - 1U];
            depth = fbase[blvl];
            stack[depth++] = r;
            blvl--;
            break;
        case OP_SET_INDEX: {
            SpTIRValue v;
            if (depth < 3U) goto done;
            v = stack[--depth]; b = stack[--depth]; a = stack[--depth];
            if (ir->value_types[a] != SP_TIR_T_REF || trace_ir_runtime_type(ir, a) != (uint8_t)T_ARRAY ||
                ir->value_types[b] != SP_TIR_T_I64) { why = "array write: array or index type"; goto done; }
            if (ir->value_types[v] == SP_TIR_T_REF && trace_ir_runtime_type(ir, v) == UINT8_MAX) goto done;
            if (!sp_tir_emit_astore(ir, a, b, v)) goto done;
            array_stored = 1;
            break;
        }
        case OP_RANGE_NEXT: {
            const int64_t stepv = locals[po->arg + 2U].as.i;
            SpTIRValue cur = current[po->arg], stop = current[po->arg + 1U], step = current[po->arg + 2U], kstep, eq, nx, cond;
            unsigned flags = SP_TIR_GUARD_DEOPT;
            if (depth >= stack_capacity || !cur || !stop || !step) goto done;
            /* continue while cur < stop (step > 0) or cur > stop (step < 0); the sign of the step is a property of this trace,
             * so the step itself is checked below. The test leaves the loop, hence the loop exit when it is the iteration's
             * first guard */
            /* the step is a property of this trace: checked once on entry (the guard is loop-invariant), after which the counter
             * advances by a constant */
            if (!sp_tir_emit_const_i64(ir, stepv, &kstep) || !sp_tir_emit_binary(ir, SP_TIR_ICMP_EQ, step, kstep, &eq) ||
                !sp_tir_emit_guard(ir, eq, i + 1U, SP_TIR_GUARD_DEOPT | SP_TIR_GUARD_ENTRY)) goto done;
            if (!sp_tir_emit_binary(ir, stepv > 0 ? SP_TIR_ICMP_LT : SP_TIR_ICMP_GT, cur, stop, &cond)) goto done;
            if (!have_exit && !stored && !array_stored && blvl == 0U && depth == stack_depth && po->target > backedge) {
                flags = 0U;
                exit_pc = po->target;
                have_exit = 1;
            }
            if (!sp_tir_emit_guard(ir, cond, i + 1U, flags)) goto done;
            stack[depth++] = cur;
            if (!sp_tir_emit_binary(ir, SP_TIR_IADD, cur, kstep, &nx)) goto done;   /* an overflow deoptimises: the interpreter ends the loop */
            current[po->arg] = nx;
            stored = 1;
            break;
        }
        case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE: {
            SpTIRValue cond;
            const SpTIRInst *last;
            int need_true, is_float_cmp;
            unsigned flags = SP_TIR_GUARD_DEOPT;
            uint32_t leave;
            if (depth == 0U || ir->count == 0U) goto done;
            cond = stack[--depth];
            last = &ir->inst[ir->count - 1U];
            if (last->dst != cond) { why = "branch condition is not the preceding comparison"; goto done; }
            is_float_cmp = last->op >= SP_TIR_FCMP_EQ && last->op <= SP_TIR_FCMP_GE;
            need_true = (po->op == OP_JUMP_IF_FALSE) != (po->taken != 0U);
            if (!need_true) flags |= SP_TIR_GUARD_INVERT;
            if (!need_true && is_float_cmp) { why = "inverted float guard"; goto done; }
            leave = po->taken ? po->pc + 5U : po->target;   /* where the other direction would go */
            if (!have_exit && !stored && !array_stored && blvl == 0U && depth == stack_depth && leave > backedge) {
                flags &= ~(unsigned)SP_TIR_GUARD_DEOPT;     /* the iteration's first test leaves the loop */
                exit_pc = leave;
                have_exit = 1;
            }
            if (!sp_tir_emit_guard(ir, cond, i + 1U, flags)) goto done;
            break;
        }
        default:
            goto done;
        }
    }
    if (depth != stack_depth) { why = "stack height changes"; goto done; }
    if (!have_exit) exit_pc = backedge + 5U;

    /* the loop label is planted at the first comparison, and only its operands live across trips: that comparison must sit at the
     * start of the iteration, with nothing but its own constants before it */
    {
        size_t first_cmp = ir->count, last_phi = 0U;
        for (size_t i = 0U; i < ir->count; i++) {
            const SpTIROp o = ir->inst[i].op;
            if (o == SP_TIR_PHI) last_phi = i;
            if (first_cmp == ir->count && o >= SP_TIR_ICMP_EQ && o <= SP_TIR_FCMP_GE && !ta_is_entry_cmp(ir, i)) first_cmp = i;
        }
        if (first_cmp == ir->count) { why = "no comparison"; goto done; }
        for (size_t i = last_phi + 1U; i < first_cmp; i++) {
            const SpTIRInst *in = &ir->inst[i];
            int entry_part = (in->op >= SP_TIR_ICMP_EQ && in->op <= SP_TIR_ICMP_GE && ta_is_entry_cmp(ir, i)) ||
                             (in->op == SP_TIR_GUARD_TRUE && (in->imm & SP_TIR_GUARD_ENTRY) != 0U);
            if (!entry_part && ((in->op != SP_TIR_CONST_I64 && in->op != SP_TIR_CONST_F64) ||
                                (in->dst != ir->inst[first_cmp].a && in->dst != ir->inst[first_cmp].b) ) ) {
                /* a constant belonging to an entry guard is fine as well */
                int used_by_entry = 0;
                for (size_t k = last_phi + 1U; k < first_cmp; k++)
                    if (ir->inst[k].op >= SP_TIR_ICMP_EQ && ir->inst[k].op <= SP_TIR_ICMP_GE && ta_is_entry_cmp(ir, k) &&
                        (ir->inst[k].b == in->dst || ir->inst[k].a == in->dst)) used_by_entry = 1;
                if (!used_by_entry || (in->op != SP_TIR_CONST_I64 && in->op != SP_TIR_CONST_F64)) { why = "work before the first comparison"; goto done; }
            }
        }
        for (int side = 0; side < 2; side++) {
            SpTIRValue v = side ? ir->inst[first_cmp].b : ir->inst[first_cmp].a;
            int def_ok = 0;
            for (size_t i = 0U; i < first_cmp && !def_ok; i++)
                def_ok = ir->inst[i].dst == v && (ir->inst[i].op == SP_TIR_PHI || ir->inst[i].op == SP_TIR_CONST_I64 ||
                                                  ir->inst[i].op == SP_TIR_CONST_F64);
            if (!def_ok) { why = "first comparison operand is computed"; goto done; }
        }
    }

    for (uint32_t i = 0U; i < slot_total; i++)
        if (used[i] && !sp_tir_set_phi_backedge(ir, phi[i], current[i])) goto done;
    if (!sp_tir_emit_loop(ir) || !trace_finish_ir(ir, slot_total, &phi_local)) goto done;
    *phi_local_out = phi_local; phi_local = NULL;
    *nmod_out = nmod;
    for (unsigned k = 0U; k < nmod; k++) mod_idx_out[k] = mod_idx[k];
    *exit_pc_out = exit_pc;
    *backedge_pc_out = backedge;
    ok = 1;
    p->trace_any = 1;
done:
    if (!ok && trace_debug_env()) (void)fprintf(stderr, "trace-jit: path builder rejected %s@%u: %s\n", p->name ? p->name : "?", header, why);
    free(used); free(param); free(phi); free(current); free(stack); free(phi_local); free(vhint); free(ihint); free(fhint);
    if (!ok) sp_tir_destroy(ir);
    return ok;
#undef SLOTV
}

int jit_trace_compile(VM *vm, Proto *p, uint32_t header, const TraceStep *steps, unsigned count,
                      uint32_t stack_depth, int is_side, uint8_t parent_slot) {
    struct JitProto *jp;
    TraceRegion *tr = NULL;
    TraceRegion *parent = NULL;
    SpTraceIR ir;
    int32_t *phi_local = NULL;
    uint32_t exit_pc = 0U, backedge_pc = 0U;
    unsigned nmod = 0U;
    uint16_t mod_idx[8] = {0};
    TraceAsm *as = NULL;
    size_t frame_size = 0U, map_size = 0U, cache_bytes = 0U;
    uint8_t slot = 0U;
    void *mem = NULL;
    SpValue *trace_base = NULL;
    int ok = 0;
    const char *debug;
    const char *fail_reason = "unknown";

    if (!vm || !p || !vm->jit_on || !steps || count == 0U || !p->ocode ||
        p->code_len > 0x7fffffffU || (is_side != 0 && is_side != 1)) return 0;
    jp = jit_proto(p);
    if (!jp) return 0;
    if (is_side) {
        if (parent_slot >= SP_JIT_SNAPSHOT_SLOT_COUNT) return 0;
        parent = jp->trace_slots[parent_slot];
        TraceRegion *tree_root = trace_root_region(parent);
        if (!parent || parent->header != header || parent->side_count >= TRACE_SIDE_MAX ||
            parent->depth >= TRACE_SIDE_DEPTH_MAX || tree_root == NULL ||
            trace_side_total(tree_root) >= TRACE_SIDE_MAX) return 0;
        trace_mark_used(jp, parent);
    } else if (trace_find(jp, header) != NULL) {
        return 0;
    }
    if (!trace_slot_candidate(jp, parent, &slot)) return 0;
    sp_tir_init(&ir);
    if (vm->nframes <= 0 || vm->frames[vm->nframes - 1].fn == NULL ||
        vm->frames[vm->nframes - 1].fn->proto != p) { fail_reason = "invalid active frame"; goto done; }
    trace_base = vm->frames[vm->nframes - 1].base;
    if (!trace_build_ir(p, trace_base, stack_depth,
                        header, steps, count,
                        &ir, &phi_local, &exit_pc, &backedge_pc)) {
        /* the narrow builder refused (it destroyed its IR): try the general path builder */
        sp_tir_init(&ir);
        if (!trace_build_ir_path(p, trace_base, is_side ? NULL : vm->slots, stack_depth, header, steps, count,
                                 &ir, &phi_local, &exit_pc, &backedge_pc, &nmod, mod_idx)) { fail_reason = "trace IR build rejected path"; goto done; }
    }
    as = (TraceAsm *)calloc(1U, sizeof *as);
    tr = (TraceRegion *)calloc(1U, sizeof *tr);
    if (!as || !tr) { fail_reason = "out of memory allocating trace"; goto done; }
    tr->runtime.clock = &jp->trace_clock;
    tr->slot = slot;
    tr->nmod = (uint8_t)nmod;
    for (unsigned k = 0U; k < nmod; k++) tr->mod_idx[k] = mod_idx[k];
    tr->mod_slot0 = (uint32_t)p->nlocals + stack_depth;
    tr->is_side = (uint8_t)(is_side != 0);
    tr->parent = parent;
    tr->depth = parent != NULL ? (uint8_t)(parent->depth + 1U) : 0U;
    if (!sp_jit_snapshot_set_init(&tr->snapshot_set, &ir, phi_local, trace_base,
                                  (uint32_t)p->nlocals, stack_depth,
                                  header, exit_pc, backedge_pc)) {
        fail_reason = "snapshot map construction failed"; goto done;
    }
    tr->signature_hash = trace_signature_hash(tr, trace_base, stack_depth);
    if (tr->signature_hash == 0U) { fail_reason = "invalid trace entry signature"; goto done; }
    if (is_side && trace_side_attempted(parent, tr->signature_hash) == 0) {
        fail_reason = "side trace signature was not requested"; goto done;
    }
    for (uint8_t k = 0U; k < (uint8_t)SP_JIT_SNAPSHOT_KIND_COUNT; k++) {
        if (!sp_jit_snapshot_validate(&tr->snapshot_set.snapshots[k], p)) {
            fail_reason = "snapshot verification failed"; goto done;
        }
    }
    if (!ta_emit_trace_ir(&ir, phi_local, nmod, &tr->snapshot_set, slot,
                          &tr->runtime, as, &frame_size)) {
            fail_reason = "native trace emission rejected IR";
            if (trace_debug_env()) {
                unsigned phis = 0U;
                for (size_t k = 0U; k < ir.count; k++) phis += ir.inst[k].op == SP_TIR_PHI;
                (void)fprintf(stderr, "trace-jit: emission rejected: %zu instructions, %u values, %u loop-carried\n", ir.count, (unsigned)ir.nvalues, phis);
            }
            goto done; }
    (void)frame_size;
    if (as->len == 0U || as->len > sizeof as->bytes) { fail_reason = "invalid native trace size"; goto done; }
    mem = jit_code_publish(as->bytes, as->len, &map_size);
    if (!mem) { fail_reason = "code publication failed"; goto done; }
    if (tr->snapshot_set.bytes < sizeof tr->snapshot_set ||
        tr->snapshot_set.bytes - sizeof tr->snapshot_set > SIZE_MAX - sizeof *tr) {
        fail_reason = "trace metadata size overflow"; goto done;
    }
    tr->meta_size = sizeof *tr + tr->snapshot_set.bytes - sizeof tr->snapshot_set;
    if (map_size > SIZE_MAX - tr->meta_size) { fail_reason = "trace metadata size overflow"; goto done; }
    cache_bytes = map_size + tr->meta_size;
    if (jp->trace_slots[slot] != NULL && !trace_cache_evict_slot(jp, slot)) {
        fail_reason = "snapshot slot admission failed"; goto done;
    }
    if (!trace_cache_make_room(jp, cache_bytes)) { fail_reason = "code cache admission failed"; goto done; }
    tr->header = header;
    tr->exit_pc = exit_pc;
    tr->backedge_pc = backedge_pc;
    tr->mem = mem;
    tr->msize = map_size;
    if (sizeof tr->entry != sizeof mem) goto done;
    memcpy(&tr->entry, &mem, sizeof tr->entry);
    tr->next = jp->traces;
    jp->traces = tr;
    jp->trace_slots[slot] = tr;
    if (is_side) {
        if (!trace_side_attach(parent, tr)) {
            /* The code has not become externally reachable yet. Roll back the
             * just-inserted cache node without publishing a stale side link. */
            jp->traces = tr->next;
            jp->trace_slots[slot] = NULL;
            if (jp->trace_count > 0U) jp->trace_count--;
            if (jp->trace_bytes >= cache_bytes) jp->trace_bytes -= cache_bytes;
            fail_reason = "side trace attachment rejected";
            goto done;
        }
        trace_update_incoming_links(jp, parent, (TraceEntry)NULL);
    } else if (!trace_index_insert(jp, tr)) {
        free(jp->trace_index);
        jp->trace_index = NULL;
    }
    jp->trace_count++;
    jp->trace_bytes += cache_bytes;
    trace_mark_used(jp, tr);
    mem = MAP_FAILED;
    tr = NULL;
    debug = trace_debug_env();
    if (debug && debug[0] && debug[0] != '0') {
        (void)fprintf(stderr, "trace-jit: %s %s@%u depth=%u parent=%u body=%u exit=%u code=%zuB ir=%zu cache=%u/%zuB%s\n",
                      is_side ? "side-compiled" : "compiled", p->name ? p->name : "?",
                      header, is_side ? (unsigned)(parent->depth + 1U) : 0U,
                      is_side ? (unsigned)parent->slot : 0U, backedge_pc, exit_pc, as->len, ir.count,
                      jp->trace_count, jp->trace_bytes,
                      is_side ? " (alternate entry signature)" : "");
        (void)sp_tir_dump(&ir, stderr);
    }
    ok = 1;
done:
    if (!ok) {
        debug = trace_debug_env();
        if (debug && debug[0] && debug[0] != '0')
            (void)fprintf(stderr, "trace-jit: rejected %s@%u: %s\n", p->name ? p->name : "?", header, fail_reason);
    }
    jit_code_unmap(mem, map_size);
    if (as) free(as);
    if (tr) sp_jit_snapshot_set_destroy(&tr->snapshot_set);
    if (tr) free(tr);
    free(phi_local);
    sp_tir_destroy(&ir);
    return ok;
}

int jit_trace_site(VM *vm, Proto *p, const uint8_t *hdr, SpValue *base, SpValue *sp,
                   uint8_t *side_parent_slot_out) {
    struct JitProto *jp;
    TraceRegion *root, *first, *next, *miss_parent;
    uint32_t header, result;
    uint32_t stack_depth;
    uint64_t requested_signature;
    uint8_t snapshot_slot, snapshot_kind;
    const char *debug;
    Frame *fr;
    if (side_parent_slot_out != NULL) *side_parent_slot_out = 0U;
    if (!vm || !p || !vm->jit_on || !p->jit || !hdr || !base || !sp ||
        vm->nframes <= 0 || sp < base + p->nlocals ||
        (size_t)(sp - (base + p->nlocals)) > UINT16_MAX) return 0;
    stack_depth = (uint32_t)(sp - (base + p->nlocals));
    fr = &vm->frames[vm->nframes - 1];
    if (!fr->fn || fr->fn->proto != p || fr->base != base) return 0;
    jp = p->jit;
    header = (uint32_t)(hdr - p->code);
    root = trace_find(jp, header);
    if (!root || !root->entry || root->dead) return 0;
    debug = trace_debug_env();
    if (debug && debug[0] && debug[0] != '0') {
        (void)fprintf(stderr, "trace-jit: site %s@%u locals=", p->name ? p->name : "?", header);
        for (uint16_t i = 0U; i < root->snapshot_set.loop_map.entry_count; i++) {
            const SpJitSnapshotEntry *entry = &root->snapshot_set.loop_map.entries[i];
            (void)fprintf(stderr, "%s%u:%u/%u", i ? "," : "", (unsigned)entry->slot,
                          (unsigned)entry->type, (unsigned)base[entry->slot].type);
        }
        (void)fputc('\n', stderr);
    }

    /* Prefer an exact known signature. For a new signature, run the deepest
     * compatible trace's entry guards once; its MISS snapshot then becomes
     * the parent of a Side-of-Side. The total descendant budget remains four
     * per root, with a maximum nesting depth of three. */
    first = trace_find_signature(root, base, stack_depth);
    if (first == NULL) {
        if (trace_side_total(root) >= TRACE_SIDE_MAX) return 0;
        first = trace_choose_miss_parent(root, stack_depth);
        if (first == NULL) return 0;
    }
    trace_mark_used(jp, first);

    /* A linked exit is a native tail jump.  The final side exit returns here
     * with the exact bytecode PC and the VM budget already materialized. */
    const uint64_t budget_before = vm->ileft;
    /* module variables travel through scratch slots above the operand stack: copied in here, written back right after the run */
    if (first->nmod != 0U) {
        if (base + first->mod_slot0 + first->nmod + 8U > vm->stack_end) return 0;
        for (unsigned k = 0U; k < first->nmod; k++) base[first->mod_slot0 + k] = vm->slots[first->mod_idx[k]];
    }
    result = first->entry(base, &vm->ileft);
    if (first->nmod != 0U)
        for (unsigned k = 0U; k < first->nmod; k++) vm->slots[first->mod_idx[k]] = base[first->mod_slot0 + k];
    if (result == UINT32_MAX ||
        !sp_jit_snapshot_decode_token(result, &snapshot_slot, &snapshot_kind)) return 0;
    TraceRegion *owner = jp->trace_slots[snapshot_slot];
    if (debug && debug[0] && debug[0] != '0')
        (void)fprintf(stderr, "trace-jit: result slot=%u kind=%u owner=%s@%u\n",
                      (unsigned)snapshot_slot, (unsigned)snapshot_kind,
                      owner && owner->is_side ? "side" : (p->name ? p->name : "?"),
                      owner ? owner->header : 0U);
    if (!owner || !owner->mem || owner->snapshot_set.snapshots[snapshot_kind].kind != snapshot_kind) return 0;
    if (snapshot_kind == SP_JIT_SNAPSHOT_DEOPT) {
        TraceRegion *rt = trace_root_region(owner);
        if (rt != NULL) {
            rt->deopts++;
            rt->deopt_iters += budget_before >= vm->ileft ? budget_before - vm->ileft : 0U;
            if (rt->deopts >= (uint64_t)TRACE_DEOPT_MIN && rt->deopt_iters < rt->deopts * (uint64_t)TRACE_DEOPT_ITERS) {
                rt->dead = 1;
                if (trace_debug_env())
                    (void)fprintf(stderr, "trace-jit: demoted %s@%u to the region JIT (%llu deopts, %llu iterations)\n",
                                  p->name ? p->name : "?", rt->header, (unsigned long long)rt->deopts,
                                  (unsigned long long)rt->deopt_iters);
            }
        }
    }
    miss_parent = owner;
    SpValue *restored_sp = NULL;
    const uint8_t *restored_pc = NULL;
    if (!sp_jit_snapshot_restore(&owner->snapshot_set.snapshots[snapshot_kind],
                                 p, fr, base, &restored_sp, &restored_pc)) return 0;
    if (debug && debug[0] && debug[0] != '0')
        (void)fprintf(stderr, "trace-jit: snapshot slot=%u kind=%u resume=%u locals=%u mapped=%u\n",
                      (unsigned)snapshot_slot, (unsigned)snapshot_kind,
                      (unsigned)(restored_pc - p->code), owner->snapshot_set.loop_map.local_count,
                      (unsigned)owner->snapshot_set.snapshots[snapshot_kind].map->entry_count);

    /* Publish the edge after the source trace has executed at least once.
     * Its Copy-and-Patch exit stencil reads this cell on subsequent runs. */
    next = trace_find(jp, first->exit_pc);
    if (next == first || (next && (!next->entry || next->dead))) next = NULL;
    TraceEntry link_target = next && next->side_count == 0U && first->nmod == 0U && next->nmod == 0U &&
        next->snapshot_set.loop_map.stack_depth == first->snapshot_set.loop_map.stack_depth &&
        next->snapshot_set.loop_map.local_count == first->snapshot_set.loop_map.local_count ?
        next->entry : (TraceEntry)NULL;
    if (first->link != next ||
        __atomic_load_n(&first->runtime.link_entry, __ATOMIC_ACQUIRE) != link_target) {
        first->link = next;
        __atomic_store_n(&first->runtime.link_entry, link_target, __ATOMIC_RELEASE);
        debug = trace_debug_env();
        if (link_target != NULL && debug && debug[0] && debug[0] != '0')
            (void)fprintf(stderr, "trace-jit: native-link %s@%u -> @%u\n",
                          p->name ? p->name : "?", first->header, next->header);
    }

    fr->pc = restored_pc;
    vm->sp = restored_sp;
    requested_signature = miss_parent != NULL ?
        trace_signature_hash(miss_parent, base, stack_depth) : 0U;
    if (snapshot_kind == SP_JIT_SNAPSHOT_MISS && miss_parent != NULL &&
        miss_parent->nmod == 0U && miss_parent->side_count < TRACE_SIDE_MAX && miss_parent->depth < TRACE_SIDE_DEPTH_MAX &&
        trace_side_total(trace_root_region(miss_parent)) < TRACE_SIDE_MAX &&
        side_parent_slot_out != NULL && requested_signature != 0U &&
        trace_side_attempt_add(miss_parent, requested_signature)) {
        *side_parent_slot_out = miss_parent->slot;
        if (debug && debug[0] && debug[0] != '0')
            (void)fprintf(stderr, "trace-jit: side-record-request %s@%u parent-slot=%u depth=%u sig=%016llx sides=%u\n",
                          p->name ? p->name : "?", miss_parent->header, (unsigned)miss_parent->slot,
                          (unsigned)miss_parent->depth, (unsigned long long)requested_signature,
                          (unsigned)miss_parent->side_count);
        return 2;
    }
    if (first->is_side && snapshot_kind == SP_JIT_SNAPSHOT_MISS) {
        return 1;
    }
    if (first->is_side && debug && debug[0] && debug[0] != '0')
        (void)fprintf(stderr, "trace-jit: side-hit %s@%u slot=%u\n",
                      p->name ? p->name : "?", first->header, (unsigned)first->slot);
    return 1;
}

void jit_trace_free_all(struct JitProto *jp) {
    TraceRegion *tr;
    if (!jp) return;
    tr = jp->traces;
    while (tr) {
        TraceRegion *next = tr->next;
        jit_code_unmap(tr->mem, tr->msize);
        sp_jit_snapshot_set_destroy(&tr->snapshot_set);
        free(tr);
        tr = next;
    }
    jp->traces = NULL;
    memset(jp->trace_slots, 0, sizeof jp->trace_slots);
    jp->trace_count = 0U;
    jp->trace_bytes = 0U;
    free(jp->trace_index);
    jp->trace_index = NULL;
}
#else
typedef int sprint_jit_trace_disabled_translation_unit;
#endif
