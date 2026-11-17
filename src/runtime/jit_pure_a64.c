/* AArch64 version of the pure-function JIT (see jit_pure.c for the idea): a pure self-recursive integer function (fib, tak, ackermann ...)
 * becomes a native function with its arguments in registers and no VM frames.  An overflow, the instruction budget, or a recursion that
 * gets too deep abandons the run and the interpreter simply performs the call itself.
 *
 * Registers (AAPCS64):  x19 x20 x21 = parameters 0..2 (callee-saved, they survive the recursive calls)
 *                       x23 = instruction budget left,  x24 = lowest sp the recursion may reach,  x25 = the state block,  x26 = the entry sp
 *                       x9 .. x15 = the operand stack of the bytecode,  x16 x17 = scratch,  x0 x1 x2 = arguments, x0 = the result */
#include "../sp.h"

#if SP_JIT_A64

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* a translation that gives up: SPRINT_PURE_DEBUG=1 says where */
#define REFUSE do { if (getenv("SPRINT_PURE_DEBUG")) (void)fprintf(stderr, "pure a64: refused at line %d\n", __LINE__); goto fail; } while (0)

typedef struct JitPure {
    void *mem;
    size_t msize;
    int (*stub)(int64_t, int64_t, int64_t, uint64_t *);   /* 1 = done, 0 = abandoned, 2 = out of budget */
    unsigned self_idx;
    int nparams;
    int fails;
} JitPure;

#define PURE_STACK 7
static const uint8_t SREG[PURE_STACK] = {9, 10, 11, 12, 13, 14, 15};
static const uint8_t LREG[3] = {19, 20, 21};
#define PURE_EXTRA ((uint64_t)1 << 26)
#define PURE_MAX_RECURSION_BYTES (512u * 1024u)
#define SCR0 16u
#define SCR1 17u

enum { CC_EQ = 0, CC_NE = 1, CC_LO = 3, CC_VS = 6, CC_GE = 10, CC_LT = 11, CC_GT = 12, CC_LE = 13 };

typedef struct { uint32_t *w; size_t n, cap; int ok; } Buf;
static size_t emit(Buf *c, uint32_t ins) {
    if (c->n >= c->cap) { c->ok = 0; return 0; }
    c->w[c->n] = ins;
    return c->n++;
}
static void mov_rr(Buf *c, unsigned d, unsigned s) { if (d != s) (void)emit(c, 0xAA0003E0u | (s << 16) | d); }          /* orr xd, xzr, xs */
static void mov_ri(Buf *c, unsigned d, int64_t v) {
    const uint64_t u = (uint64_t)v;
    int first = 1;
    for (unsigned h = 0; h < 4; h++) {
        const uint32_t part = (uint32_t)((u >> (16 * h)) & 0xffffu);
        if (part == 0 && !(h == 3 && first)) continue;
        if (first) { (void)emit(c, 0xD2800000u | (h << 21) | (part << 5) | d); first = 0; }       /* movz */
        else (void)emit(c, 0xF2800000u | (h << 21) | (part << 5) | d);                              /* movk */
    }
    if (first) (void)emit(c, 0xD2800000u | d);                                                       /* movz xd, #0 */
}
static void alu_rr(Buf *c, uint32_t base, unsigned d, unsigned n, unsigned m) { (void)emit(c, base | (m << 16) | (n << 5) | d); }
static void adds_rr(Buf *c, unsigned d, unsigned n, unsigned m) { alu_rr(c, 0xAB000000u, d, n, m); }
static void subs_rr(Buf *c, unsigned d, unsigned n, unsigned m) { alu_rr(c, 0xEB000000u, d, n, m); }
static void cmp_rr(Buf *c, unsigned n, unsigned m) { subs_rr(c, 31, n, m); }
static void push_r(Buf *c, unsigned r) { (void)emit(c, 0xF81F0FE0u | r); }            /* str xr, [sp, #-16]! */
static void pop_r(Buf *c, unsigned r) { (void)emit(c, 0xF84107E0u | r); }             /* ldr xr, [sp], #16 */
static void mov_from_sp(Buf *c, unsigned d) { (void)emit(c, 0x910003E0u | d); }       /* add xd, sp, #0 */
static void mov_to_sp(Buf *c, unsigned s) { (void)emit(c, 0x9100001Fu | (s << 5)); }   /* add sp, xs, #0 */
static void stp_off(Buf *c, unsigned t1, unsigned t2, int off) { (void)emit(c, 0xA9000000u | ((uint32_t)(off / 8) & 0x7fu) << 15 | (t2 << 10) | (31u << 5) | t1); }
static void ldp_off(Buf *c, unsigned t1, unsigned t2, int off) { (void)emit(c, 0xA9400000u | ((uint32_t)(off / 8) & 0x7fu) << 15 | (t2 << 10) | (31u << 5) | t1); }

typedef struct { size_t at; size_t target_pc; int kind; unsigned cc; } Fix;   /* kind: 0 = a bytecode target, 1 = the failure stub, 2 = the budget stub; cc < 16: b.cond, else b */
#define MAX_FIX 512
typedef enum { E_IMM, E_LOCAL, E_REG, E_SELF } EKind;
typedef struct { EKind k; int64_t v; } Ent;
static int fits32(int64_t v) { return v >= INT32_MIN && v <= INT32_MAX; }
#define NOCC 99u

JitPure *jit_pure_compile(VM *vm, Proto *p) {
    const uint8_t *code = p->ocode ? p->ocode : p->code;
    const uint32_t n = p->code_len;
    const int np = p->nparams;
    Ent st[PURE_STACK + 1];
    int depth = 0;
    Fix fix[MAX_FIX];
    int nfix = 0;
    uint32_t *lab = NULL;
    uint8_t *istart = NULL, *target = NULL;
    Buf c;
    JitPure *jp = NULL;
    size_t body_at, fail_stub, budget_stub, budget_out = 0, call_at = 0, jout_at = 0, reachable = 1;
    int self_idx = -1;
    uint8_t *mem = NULL;
    size_t msize = 0, page;

    c.w = NULL;
    if (np < 1 || np > 3 || p->nlocals != np || p->has_rest || p->ndefaults != 0 || p->nrequired != np || n == 0 || n > 4096) return NULL;
    lab = (uint32_t *)calloc((size_t)n + 1U, sizeof *lab);
    istart = (uint8_t *)calloc((size_t)n + 1U, 1U);
    target = (uint8_t *)calloc((size_t)n + 1U, 1U);
    c.cap = 8192; c.n = 0; c.ok = 1;
    c.w = (uint32_t *)malloc(c.cap * sizeof *c.w);
    if (!lab || !istart || !target || !c.w) REFUSE;

    for (uint32_t pc = 0; pc < n;) {   /* pass 1: instruction starts and jump targets; anything the translation does not know is refused */
        int op = code[pc], len = op_len(op);
        if (len <= 0 || pc + (uint32_t)len > n) REFUSE;
        istart[pc] = 1;
        switch (op) {
        case OP_JUMP: case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE: {
            int32_t off = (int32_t)((uint32_t)code[pc + 1] | ((uint32_t)code[pc + 2] << 8) | ((uint32_t)code[pc + 3] << 16) | ((uint32_t)code[pc + 4] << 24));
            int64_t t = (int64_t)pc + 5 + off;
            if (off <= 0 || t >= (int64_t)n) REFUSE;
            target[t] = 1;
            break;
        }
        case OP_LOAD_LOCAL: case OP_SMALLINT: case OP_CONST: case OP_LOAD_MODULE: case OP_CALL: case OP_NOP: case OP_POP:
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE:
        case OP_RETURN: case OP_RETURN_NIL:
            break;
        default: REFUSE;
        }
        pc += (uint32_t)len;
    }

    /* stub: int stub(a0, a1, a2, state*) with state = {budget, result, limit}; 1 on success, 0 when the run is abandoned, 2 when the budget ran out */
    (void)emit(&c, 0xA9BA7BFDu);                                        /* stp x29, x30, [sp, #-96]! */
    stp_off(&c, 19, 20, 16); stp_off(&c, 21, 22, 32); stp_off(&c, 23, 24, 48); stp_off(&c, 25, 26, 64);
    mov_rr(&c, 25, 3);                                                  /* x25 = the state block */
    (void)emit(&c, 0xF9400000u | (25u << 5) | 23u);                     /* ldr x23, [x25]: the budget */
    (void)emit(&c, 0xF9400000u | (2u << 10) | (25u << 5) | SCR0);       /* ldr x16, [x25, #16]: the depth limit in bytes */
    mov_from_sp(&c, SCR1);
    alu_rr(&c, 0xCB000000u, 24, SCR1, SCR0);                            /* x24 = sp - limit */
    mov_from_sp(&c, 26);                                                /* x26 = the entry sp */
    call_at = emit(&c, 0x94000000u);                                    /* bl body (patched) */
    (void)emit(&c, 0xF9000000u | (1u << 10) | (25u << 5) | 0u);         /* str x0, [x25, #8]: the result */
    (void)emit(&c, 0xF9000000u | (25u << 5) | 23u);                     /* str x23, [x25]: the budget left */
    (void)emit(&c, 0x52800000u | (1u << 5) | 0u);                       /* mov w0, #1 */
    jout_at = emit(&c, 0x14000000u);                                    /* b out (patched) */
    budget_stub = c.n;
    mov_to_sp(&c, 26);
    (void)emit(&c, 0x52800000u | (2u << 5) | 0u);                       /* mov w0, #2 */
    budget_out = emit(&c, 0x14000000u);                                 /* b out (patched) */
    fail_stub = c.n;
    mov_to_sp(&c, 26);
    (void)emit(&c, 0x52800000u | 0u);                                   /* mov w0, #0 */
    c.w[jout_at] = 0x14000000u | (uint32_t)((c.n - jout_at) & 0x3ffffffu);
    c.w[budget_out] = 0x14000000u | (uint32_t)((c.n - budget_out) & 0x3ffffffu);
    ldp_off(&c, 19, 20, 16); ldp_off(&c, 21, 22, 32); ldp_off(&c, 23, 24, 48); ldp_off(&c, 25, 26, 64);
    (void)emit(&c, 0xA8C67BFDu);                                        /* ldp x29, x30, [sp], #96 */
    (void)emit(&c, 0xD65F03C0u);                                        /* ret */

    body_at = c.n;
    c.w[call_at] = 0x94000000u | (uint32_t)((body_at - call_at) & 0x3ffffffu);
    push_r(&c, 30);
    for (int i = 0; i < np; i++) push_r(&c, LREG[i]);
    for (int i = 0; i < np; i++) mov_rr(&c, LREG[i], (unsigned)i);

#define FIXUP(KIND, CC, TPC) do { if (nfix >= MAX_FIX) REFUSE; fix[nfix].at = c.n; fix[nfix].kind = (KIND); fix[nfix].cc = (CC); fix[nfix].target_pc = (TPC); nfix++; } while (0)
#define FAILJ_CC(CC, KIND) do { FIXUP(KIND, CC, 0); (void)emit(&c, 0x54000000u | (CC)); } while (0)
#define EPILOGUE() do { for (int i_ = np - 1; i_ >= 0; i_--) pop_r(&c, LREG[i_]); pop_r(&c, 30); (void)emit(&c, 0xD65F03C0u); } while (0)
#define MAT(i) do { Ent *e_ = &st[i]; if (e_->k == E_IMM) mov_ri(&c, SREG[i], e_->v); else if (e_->k == E_LOCAL) mov_rr(&c, SREG[i], LREG[e_->v]); else if (e_->k == E_SELF) REFUSE; e_->k = E_REG; } while (0)

    for (uint32_t pc = 0; pc < n;) {
        int op = code[pc], len = op_len(op);
        lab[pc] = (uint32_t)c.n;
        if (target[pc]) { if (depth != 0) REFUSE; reachable = 1; }
        if (!reachable) { pc += (uint32_t)len; continue; }
        switch (op) {
        case OP_NOP: break;
        case OP_LOAD_LOCAL: {
            unsigned k = (unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8);
            if (k >= (unsigned)np || depth >= PURE_STACK) REFUSE;
            st[depth].k = E_LOCAL; st[depth].v = (int64_t)k; depth++;
            break;
        }
        case OP_SMALLINT: {
            int16_t v = (int16_t)((unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8));
            if (depth >= PURE_STACK) REFUSE;
            st[depth].k = E_IMM; st[depth].v = v; depth++;
            break;
        }
        case OP_CONST: {
            unsigned k = (unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8);
            if (k >= (unsigned)p->nconsts || p->consts[k].type != T_INT || !fits32(p->consts[k].as.i) || depth >= PURE_STACK) REFUSE;
            st[depth].k = E_IMM; st[depth].v = p->consts[k].as.i; depth++;
            break;
        }
        case OP_LOAD_MODULE: {
            unsigned k = (unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8);
            if (depth >= PURE_STACK || k >= (unsigned)(vm->prog ? vm->prog->nslots : 0) || vm->slots[k].type != T_FUNCTION || AS_FUNC(vm->slots[k])->proto != p ||
                (self_idx >= 0 && self_idx != (int)k)) REFUSE;
            self_idx = (int)k;
            st[depth].k = E_SELF; st[depth].v = 0; depth++;
            break;
        }
        case OP_POP:
            if (depth == 0) REFUSE;
            depth--;
            break;
        case OP_ADD: case OP_SUB: case OP_MUL: {
            Ent b;
            int da;
            unsigned rb, rd;
            if (depth < 2) REFUSE;
            b = st[--depth]; da = depth - 1;
            if (st[da].k == E_SELF || b.k == E_SELF) REFUSE;
            MAT(da);
            rd = SREG[da];
            if (b.k == E_LOCAL) rb = LREG[b.v];
            else if (b.k == E_IMM && op != OP_MUL && b.v >= 0 && b.v < 4096) {     /* adds / subs with a 12-bit immediate */
                (void)emit(&c, (op == OP_ADD ? 0xB1000000u : 0xF1000000u) | ((uint32_t)b.v << 10) | (rd << 5) | rd);
                FAILJ_CC(CC_VS, 1);
                st[da].k = E_REG;
                break;
            } else {
                if (b.k == E_IMM) { mov_ri(&c, SREG[da + 1], b.v); rb = SREG[da + 1]; } else rb = SREG[da + 1];
            }
            if (op == OP_MUL) {
                alu_rr(&c, 0x9B007C00u, SCR0, rd, rb);                              /* mul x16, rd, rb */
                alu_rr(&c, 0x9B407C00u, SCR1, rd, rb);                              /* smulh x17, rd, rb */
                (void)emit(&c, 0xEB000000u | (2u << 22) | (SCR0 << 16) | (63u << 10) | (SCR1 << 5) | 31u);   /* cmp x17, x16, asr #63 */
                FAILJ_CC(CC_NE, 1);
                mov_rr(&c, rd, SCR0);
            } else {
                if (op == OP_ADD) adds_rr(&c, rd, rd, rb); else subs_rr(&c, rd, rd, rb);
                FAILJ_CC(CC_VS, 1);
            }
            st[da].k = E_REG;
            break;
        }
        case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE: {
            uint32_t npc = pc + (uint32_t)len;
            int nop_;
            int32_t off;
            int64_t t;
            Ent b, a;
            unsigned cc;
            if (npc >= n || (code[npc] != OP_JUMP_IF_FALSE && code[npc] != OP_JUMP_IF_TRUE) || target[npc] || depth < 2) REFUSE;
            nop_ = code[npc];
            off = (int32_t)((uint32_t)code[npc + 1] | ((uint32_t)code[npc + 2] << 8) | ((uint32_t)code[npc + 3] << 16) | ((uint32_t)code[npc + 4] << 24));
            t = (int64_t)npc + 5 + off;
            b = st[--depth]; a = st[--depth];
            if (depth != 0 || a.k == E_SELF || b.k == E_SELF) REFUSE;
            {
                unsigned ra;
                if (a.k == E_LOCAL) ra = LREG[a.v];
                else { st[0] = a; MAT(0); ra = SREG[0]; }
                if (b.k == E_IMM && b.v >= 0 && b.v < 4096) (void)emit(&c, 0xF100001Fu | ((uint32_t)b.v << 10) | (ra << 5));   /* cmp xra, #imm */
                else {
                    unsigned rb;
                    if (b.k == E_LOCAL) rb = LREG[b.v];
                    else { if (b.k == E_IMM) mov_ri(&c, SREG[1], b.v); rb = SREG[1]; }
                    cmp_rr(&c, ra, rb);
                }
            }
            switch (op) {   /* the jump is taken when the condition is false (JUMP_IF_FALSE) or true (JUMP_IF_TRUE) */
            case OP_LT: cc = nop_ == OP_JUMP_IF_FALSE ? CC_GE : CC_LT; break;
            case OP_LE: cc = nop_ == OP_JUMP_IF_FALSE ? CC_GT : CC_LE; break;
            case OP_GT: cc = nop_ == OP_JUMP_IF_FALSE ? CC_LE : CC_GT; break;
            case OP_GE: cc = nop_ == OP_JUMP_IF_FALSE ? CC_LT : CC_GE; break;
            case OP_EQ: cc = nop_ == OP_JUMP_IF_FALSE ? CC_NE : CC_EQ; break;
            default:    cc = nop_ == OP_JUMP_IF_FALSE ? CC_EQ : CC_NE; break;
            }
            FIXUP(0, cc, (size_t)t);
            (void)emit(&c, 0x54000000u | cc);
            lab[npc] = (uint32_t)c.n;
            pc = npc + 5;
            continue;
        }
        case OP_JUMP: {
            int32_t off = (int32_t)((uint32_t)code[pc + 1] | ((uint32_t)code[pc + 2] << 8) | ((uint32_t)code[pc + 3] << 16) | ((uint32_t)code[pc + 4] << 24));
            if (depth != 0) REFUSE;
            FIXUP(0, NOCC, (size_t)((int64_t)pc + 5 + off));
            (void)emit(&c, 0x14000000u);
            reachable = 0;
            break;
        }
        case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE: REFUSE;
        case OP_RETURN: {
            Ent r;
            if (depth != 1) REFUSE;
            r = st[--depth];
            if (r.k == E_SELF) REFUSE;
            if (r.k == E_IMM) mov_ri(&c, 0, r.v);
            else if (r.k == E_LOCAL) mov_rr(&c, 0, LREG[r.v]);
            else mov_rr(&c, 0, SREG[0]);
            EPILOGUE();
            reachable = 0;
            break;
        }
        case OP_RETURN_NIL: REFUSE;
        case OP_CALL: {
            int nargs = code[pc + 1], m;
            if (nargs != np || depth < nargs + 1) REFUSE;
            m = depth - nargs - 1;
            if (st[m].k != E_SELF) REFUSE;
            for (int i = m + 1; i < depth; i++) if (st[i].k == E_SELF) REFUSE;
            for (int i = 0; i < m; i++) if (st[i].k == E_REG) push_r(&c, SREG[i]);   /* a pending callee marker (E_SELF) of an enclosing call has no register to save */
            for (int i = 0; i < nargs; i++) {            /* the argument registers x0..x2 never overlap the operand or parameter registers */
                Ent a = st[m + 1 + i];
                if (a.k == E_IMM) mov_ri(&c, (unsigned)i, a.v);
                else if (a.k == E_LOCAL) mov_rr(&c, (unsigned)i, LREG[a.v]);
                else mov_rr(&c, (unsigned)i, SREG[m + 1 + i]);
            }
            (void)emit(&c, 0xF1000400u | (23u << 5) | 23u);                  /* subs x23, x23, #1: one tick per call */
            FAILJ_CC(CC_LO, 2);                                              /* the budget ran out */
            mov_from_sp(&c, SCR0);
            cmp_rr(&c, SCR0, 24);                                            /* a floor under the recursion depth */
            FAILJ_CC(CC_LO, 1);
            FIXUP(0, NOCC, 0); fix[nfix - 1].kind = 3;                       /* bl body */
            (void)emit(&c, 0x94000000u);
            mov_rr(&c, SREG[m], 0);
            for (int i = m - 1; i >= 0; i--) if (st[i].k == E_REG) pop_r(&c, SREG[i]);
            st[m].k = E_REG; st[m].v = 0; depth = m + 1;
            break;
        }
        default: REFUSE;
        }
        pc += (uint32_t)len;
    }
    if (!c.ok || self_idx < 0) REFUSE;
    for (int i = 0; i < nfix; i++) {
        int64_t tw;
        int32_t rel;
        if (fix[i].kind == 3) tw = (int64_t)body_at;
        else if (fix[i].kind == 2) tw = (int64_t)budget_stub;
        else if (fix[i].kind == 1) tw = (int64_t)fail_stub;
        else {
            if (fix[i].target_pc >= n || !istart[fix[i].target_pc]) REFUSE;
            tw = (int64_t)lab[fix[i].target_pc];
        }
        rel = (int32_t)(tw - (int64_t)fix[i].at);
        if (fix[i].kind == 3) c.w[fix[i].at] = 0x94000000u | ((uint32_t)rel & 0x3ffffffu);
        else if (fix[i].cc == NOCC) c.w[fix[i].at] = 0x14000000u | ((uint32_t)rel & 0x3ffffffu);
        else {
            if (rel < -(1 << 18) || rel >= (1 << 18)) REFUSE;
            c.w[fix[i].at] = 0x54000000u | (((uint32_t)rel & 0x7ffffu) << 5) | fix[i].cc;
        }
    }
    page = (size_t)sysconf(_SC_PAGESIZE);
    msize = ((c.n * 4 + page - 1) / page) * page;
    mem = (uint8_t *)mmap(NULL, msize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) { mem = NULL; REFUSE; }
    memcpy(mem, c.w, c.n * 4);
    if (mprotect(mem, msize, PROT_READ | PROT_EXEC) != 0) { (void)munmap(mem, msize); REFUSE; }
    __builtin___clear_cache((char *)mem, (char *)mem + c.n * 4);
    jp = (JitPure *)calloc(1, sizeof *jp);
    if (!jp) { (void)munmap(mem, msize); REFUSE; }
    jp->mem = mem; jp->msize = msize;
    memcpy(&jp->stub, &mem, sizeof mem);
    jp->self_idx = (unsigned)self_idx;
    jp->nparams = np;
    free(lab); free(istart); free(target); free(c.w);
    return jp;
fail:
    free(lab); free(istart); free(target); free(c.w);
    return NULL;
}

struct JitLeaf *jit_leaf_compile(VM *vm, Proto *p) { (void)vm; (void)p; return NULL; }
void *jit_leaf_fn(const struct JitLeaf *jl) { (void)jl; return NULL; }
int jit_leaf_is_bool(const struct JitLeaf *jl) { (void)jl; return 0; }
void jit_leaf_free(struct JitLeaf *jl) { (void)jl; }

void jit_pure_free(Proto *p) {
    JitPure *jp = p->pure;
    if (!jp) return;
    if (jp->mem) (void)munmap(jp->mem, jp->msize);
    free(jp);
    p->pure = NULL;
}

/* Run the call natively (the contract of jit_pure_enter in jit_pure.c). */
int jit_pure_enter(VM *vm, Proto *p, const SpValue *args, uint64_t *left, int64_t *out) {
    JitPure *jp = p->pure;
    struct { uint64_t budget; int64_t result; uint64_t limit; } state;
    int64_t a[3] = {0, 0, 0};
    int r;
    if (jp->fails >= 8) return 0;
    for (int i = 0; i < jp->nparams; i++) {
        if (args[i].type != T_INT) return 0;
        a[i] = args[i].as.i;
    }
    if (jp->self_idx >= (unsigned)(vm->prog ? vm->prog->nslots : 0) || vm->slots[jp->self_idx].type != T_FUNCTION || AS_FUNC(vm->slots[jp->self_idx])->proto != p) return 0;
    {
        uint64_t take = PURE_EXTRA, total, rem, used;
        if (vm->ibank != UINT64_MAX && vm->ibank < take) take = vm->ibank;
        total = *left > UINT64_MAX - take ? UINT64_MAX : *left + take;
        state.budget = total;
        state.result = 0;
        {   /* never let the native recursion go deeper than the interpreter would allow; an arm64 frame is at least 16 * (parameters + 2) bytes */
            int64_t room = (int64_t)vm->max_frames - (int64_t)vm->nframes - 2;
            uint64_t fmin = 16U * ((uint64_t)jp->nparams + 2U);
            if (room < 1) return 0;
            state.limit = (uint64_t)room * fmin;
            if (state.limit > PURE_MAX_RECURSION_BYTES) state.limit = PURE_MAX_RECURSION_BYTES;
        }
        r = jp->stub(a[0], a[1], a[2], &state.budget);
        if (r != 1) {
            if (r == 0) jp->fails++;
            return 0;
        }
        rem = state.budget;
        used = total - rem;
        if (used <= *left) *left -= used;
        else {
            uint64_t over = used - *left;
            *left = 0;
            if (vm->ibank != UINT64_MAX) vm->ibank -= over < vm->ibank ? over : vm->ibank;
        }
        *out = state.result;
    }
    return 1;
}

#else
typedef int jit_pure_a64_unused;   /* this translation unit is empty on other targets */
#endif
