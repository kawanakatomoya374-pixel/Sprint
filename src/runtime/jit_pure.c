/* Pure self-recursive integer functions (fib, tak, ackermann ...) as native code.
 *
 * A function whose body is straight integer arithmetic, comparisons that feed branches, returns and calls of itself (through a
 * module variable) has no side effects at all.  It is compiled to a real native function -- arguments in registers, the result
 * in rax, no VM frames -- and entered from the interpreter's call path.  Anything unusual during the run (an overflow, the
 * instruction budget, too deep a recursion) abandons the whole native run and the interpreter simply performs the call
 * itself: with no side effects that is always correct.
 *
 * Register plan:  rbx rbp r15 = parameters 0..2 (callee-saved, so they survive the recursive calls)
 *                 r12 = the stack pointer at entry (the failure path resets rsp to it)
 *                 r13 = instruction budget left,  r14 = lowest rsp the recursion may reach
 *                 rax rcx rdx rsi rdi r8 r9 = the operand stack of the bytecode
 */
#include "../sp.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if SP_JIT

enum { R_AX = 0, R_CX = 1, R_DX = 2, R_BX = 3, R_SP = 4, R_BP = 5, R_SI = 6, R_DI = 7, R_8 = 8, R_9 = 9, R_12 = 12, R_13 = 13, R_14 = 14, R_15 = 15 };

typedef struct JitPure {
    void *mem;
    size_t msize;
    int (*stub)(int64_t, int64_t, int64_t, uint64_t *);   /* 1 = done, 0 = abandoned, 2 = out of budget */
    unsigned self_idx;   /* the module variable that holds the function */
    int nparams;
    int fails;           /* runs abandoned: after a few the function is left to the interpreter */
} JitPure;

#define PURE_STACK 7
static const uint8_t SREG[PURE_STACK] = {R_AX, R_CX, R_DX, R_SI, R_DI, R_8, R_9};
static const uint8_t LREG[3] = {R_BX, R_BP, R_15};
static const uint8_t AREG[3] = {R_DI, R_SI, R_DX};
#define PURE_EXTRA ((uint64_t)1 << 26)
#define PURE_MAX_RECURSION_BYTES (512u * 1024u)

typedef struct {
    uint8_t *b;
    size_t n, cap;
    int ok;
} Buf;
static void put(Buf *c, unsigned v) {
    if (c->n >= c->cap) { c->ok = 0; return; }
    c->b[c->n++] = (uint8_t)v;
}
static void put32(Buf *c, int32_t v) {
    for (int i = 0; i < 4; i++) put(c, (unsigned)((uint32_t)v >> (8 * i)) & 0xffU);
}
/* REX.W + opcode + modrm(reg, rm) register-register form */
static void rr(Buf *c, unsigned op, int reg, int rm) {
    put(c, 0x48U | (unsigned)(((reg >> 3) & 1) << 2) | (unsigned)((rm >> 3) & 1));
    put(c, op);
    put(c, 0xc0U | (unsigned)((reg & 7) << 3) | (unsigned)(rm & 7));
}
static void mov_rr(Buf *c, int dst, int src) { if (dst != src) rr(c, 0x89, src, dst); }
static void mov_ri(Buf *c, int dst, int64_t v) {
    if (v >= INT32_MIN && v <= INT32_MAX) {
        put(c, 0x48U | (unsigned)((dst >> 3) & 1)); put(c, 0xc7); put(c, 0xc0U | (unsigned)(dst & 7)); put32(c, (int32_t)v);
    } else {
        put(c, 0x48U | (unsigned)((dst >> 3) & 1)); put(c, 0xb8U | (unsigned)(dst & 7));
        for (int i = 0; i < 8; i++) put(c, (unsigned)((uint64_t)v >> (8 * i)) & 0xffU);
    }
}
static void alu_ri(Buf *c, unsigned ext, int dst, int32_t v) {   /* ext: 0 add, 5 sub, 7 cmp */
    put(c, 0x48U | (unsigned)((dst >> 3) & 1)); put(c, 0x81); put(c, 0xc0U | (ext << 3) | (unsigned)(dst & 7)); put32(c, v);
}
static void push_r(Buf *c, int r) { if (r >= 8) put(c, 0x41); put(c, 0x50U | (unsigned)(r & 7)); }
static void pop_r(Buf *c, int r) { if (r >= 8) put(c, 0x41); put(c, 0x58U | (unsigned)(r & 7)); }
static void push_i(Buf *c, int32_t v) { put(c, 0x68); put32(c, v); }

typedef struct { size_t at; size_t target_pc; int is_fail; } Fix;   /* is_fail: 1 = the failure stub, 2 = the budget stub */
#define MAX_FIX 512

typedef enum { E_IMM, E_LOCAL, E_REG, E_SELF } EKind;
typedef struct { EKind k; int64_t v; } Ent;

static int fits32(int64_t v) { return v >= INT32_MIN && v <= INT32_MAX; }

JitPure *jit_pure_compile(VM *vm, Proto *p) {
    const uint8_t *code = p->ocode ? p->ocode : p->code;
    uint32_t n = p->code_len;
    const int np = p->nparams;
    Ent st[PURE_STACK + 1];
    int depth = 0;
    Fix fix[MAX_FIX];
    int nfix = 0;
    uint32_t *lab = NULL;   /* code offset of each bytecode pc */
    uint8_t *istart = NULL, *target = NULL;
    Buf c;
    JitPure *jp = NULL;
    size_t body_at, fail_at_stub, fail_budget_at, reachable = 1, call_at = 0, jout_at = 0;
    int self_idx = -1;
    uint8_t *mem = NULL;
    size_t msize = 0, page;

    if (np < 1 || np > 3 || p->nlocals != np || p->has_rest || p->ndefaults != 0 || p->nrequired != np || n == 0 || n > 4096) return NULL;
    lab = (uint32_t *)calloc((size_t)n + 1U, sizeof *lab);
    istart = (uint8_t *)calloc((size_t)n + 1U, 1U);
    target = (uint8_t *)calloc((size_t)n + 1U, 1U);
    c.cap = 16384; c.n = 0; c.ok = 1;
    c.b = (uint8_t *)malloc(c.cap);
    if (!lab || !istart || !target || !c.b) goto fail;

    /* pass 1: instruction starts and jump targets; reject anything the translation does not know */
    for (uint32_t pc = 0; pc < n;) {
        int op = code[pc], len = op_len(op);
        if (len <= 0 || pc + (uint32_t)len > n) goto fail;
        istart[pc] = 1;
        switch (op) {
        case OP_JUMP: case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE: {
            int32_t off = (int32_t)((uint32_t)code[pc + 1] | ((uint32_t)code[pc + 2] << 8) | ((uint32_t)code[pc + 3] << 16) | ((uint32_t)code[pc + 4] << 24));
            int64_t t = (int64_t)pc + 5 + off;
            if (off <= 0 || t >= (int64_t)n) goto fail;
            target[t] = 1;
            break;
        }
        case OP_LOAD_LOCAL: case OP_SMALLINT: case OP_CONST: case OP_LOAD_MODULE: case OP_CALL: case OP_NOP: case OP_POP:
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE:
        case OP_RETURN: case OP_RETURN_NIL:
            break;
        default: goto fail;
        }
        pc += (uint32_t)len;
    }

    /* stub: callable from C as int stub(a0, a1, a2, state*) with state = {budget, result}; returns 1 on success, 0 when the run is abandoned */
    push_r(&c, R_BX); push_r(&c, R_BP); push_r(&c, R_12); push_r(&c, R_13); push_r(&c, R_14); push_r(&c, R_15);
    push_r(&c, R_CX);                                   /* the state pointer */
    mov_rr(&c, R_12, R_SP);
    put(&c, 0x4c); put(&c, 0x8b); put(&c, 0x29);        /* mov r13, [rcx] */
    mov_rr(&c, R_14, R_SP);                             /* r14 = rsp - state.limit: the lowest rsp the recursion may reach */
    put(&c, 0x4c); put(&c, 0x2b); put(&c, 0x71); put(&c, 0x10);   /* sub r14, [rcx+16] */
    put(&c, 0xe8); call_at = c.n; put32(&c, 0);  /* call body */
    pop_r(&c, R_CX);
    put(&c, 0x48); put(&c, 0x89); put(&c, 0x41); put(&c, 0x08);   /* mov [rcx+8], rax */
    put(&c, 0x4c); put(&c, 0x89); put(&c, 0x29);        /* mov [rcx], r13 */
    put(&c, 0xb8); put32(&c, 1);                        /* mov eax, 1 */
    put(&c, 0xeb); jout_at = c.n; put(&c, 0);    /* jmp out */
    fail_budget_at = c.n;                               /* the budget ran out: unwind to the entry rsp, result 2 */
    mov_rr(&c, R_SP, R_12);
    pop_r(&c, R_CX);
    put(&c, 0xb8); put32(&c, 2);                        /* mov eax, 2 */
    put(&c, 0xeb); put(&c, 6);                          /* jmp out (skips the next block: mov rsp,r12 / pop rcx / xor eax,eax = 6 bytes) */
    fail_at_stub = c.n;                                 /* any other failure: unwind, result 0 */
    mov_rr(&c, R_SP, R_12);
    pop_r(&c, R_CX);
    put(&c, 0x31); put(&c, 0xc0);                       /* xor eax, eax */
    c.b[jout_at] = (uint8_t)(c.n - (jout_at + 1));
    pop_r(&c, R_15); pop_r(&c, R_14); pop_r(&c, R_13); pop_r(&c, R_12); pop_r(&c, R_BP); pop_r(&c, R_BX);
    put(&c, 0xc3);

    /* body */
    body_at = c.n;
    { int32_t rel = (int32_t)(body_at - (call_at + 4)); memcpy(c.b + call_at, &rel, 4); }
    for (int i = 0; i < np; i++) push_r(&c, LREG[i]);
    for (int i = 0; i < np; i++) mov_rr(&c, LREG[i], AREG[i]);

#define FAILJ2(cc, KIND) do { put(&c, 0x0f); put(&c, cc); if (nfix >= MAX_FIX) goto fail; fix[nfix].at = c.n; fix[nfix].is_fail = (KIND); fix[nfix].target_pc = 0; nfix++; put32(&c, 0); } while (0)
#define FAILJ(cc) FAILJ2(cc, 1)
#define EPILOGUE() do { for (int i_ = np - 1; i_ >= 0; i_--) pop_r(&c, LREG[i_]); put(&c, 0xc3); } while (0)
#define MAT(i) do { Ent *e_ = &st[i]; if (e_->k == E_IMM) mov_ri(&c, SREG[i], e_->v); else if (e_->k == E_LOCAL) mov_rr(&c, SREG[i], LREG[e_->v]); else if (e_->k == E_SELF) goto fail; e_->k = E_REG; } while (0)

    for (uint32_t pc = 0; pc < n;) {
        int op = code[pc], len = op_len(op);
        lab[pc] = (uint32_t)c.n;
        if (target[pc]) { if (depth != 0) goto fail; reachable = 1; }
        if (!reachable) { pc += (uint32_t)len; continue; }
        switch (op) {
        case OP_NOP: break;
        case OP_LOAD_LOCAL: {
            unsigned k = (unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8);
            if (k >= (unsigned)np || depth >= PURE_STACK) goto fail;
            st[depth].k = E_LOCAL; st[depth].v = (int64_t)k; depth++;
            break;
        }
        case OP_SMALLINT: {
            int16_t v = (int16_t)((unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8));
            if (depth >= PURE_STACK) goto fail;
            st[depth].k = E_IMM; st[depth].v = v; depth++;
            break;
        }
        case OP_CONST: {
            unsigned k = (unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8);
            if (k >= (unsigned)p->nconsts || p->consts[k].type != T_INT || !fits32(p->consts[k].as.i) || depth >= PURE_STACK) goto fail;
            st[depth].k = E_IMM; st[depth].v = p->consts[k].as.i; depth++;
            break;
        }
        case OP_LOAD_MODULE: {
            unsigned k = (unsigned)code[pc + 1] | ((unsigned)code[pc + 2] << 8);
            if (depth >= PURE_STACK || k >= (unsigned)(vm->prog ? vm->prog->nslots : 0) || vm->slots[k].type != T_FUNCTION || AS_FUNC(vm->slots[k])->proto != p ||
                (self_idx >= 0 && self_idx != (int)k)) goto fail;
            self_idx = (int)k;
            st[depth].k = E_SELF; st[depth].v = 0; depth++;
            break;
        }
        case OP_POP:
            if (depth == 0) goto fail;
            depth--;
            break;
        case OP_ADD: case OP_SUB: case OP_MUL: {
            Ent b;
            int da;
            if (depth < 2) goto fail;
            b = st[--depth]; da = depth - 1;
            if (st[da].k == E_SELF || b.k == E_SELF) goto fail;
            MAT(da);
            if (b.k == E_IMM && fits32(b.v)) {
                if (op == OP_MUL) { put(&c, 0x48U | (unsigned)(((SREG[da] >> 3) & 1) << 2) | (unsigned)((SREG[da] >> 3) & 1)); put(&c, 0x69); put(&c, 0xc0U | (unsigned)((SREG[da] & 7) << 3) | (unsigned)(SREG[da] & 7)); put32(&c, (int32_t)b.v); }
                else alu_ri(&c, op == OP_ADD ? 0U : 5U, SREG[da], (int32_t)b.v);
            } else {
                int rb;
                if (b.k == E_LOCAL) rb = LREG[b.v];
                else { if (b.k == E_IMM) mov_ri(&c, SREG[da + 1], b.v); rb = SREG[da + 1]; }
                if (op == OP_MUL) { put(&c, 0x48U | (unsigned)(((SREG[da] >> 3) & 1) << 2) | (unsigned)((rb >> 3) & 1)); put(&c, 0x0f); put(&c, 0xaf); put(&c, 0xc0U | (unsigned)((SREG[da] & 7) << 3) | (unsigned)(rb & 7)); }
                else rr(&c, op == OP_ADD ? 0x01U : 0x29U, rb, SREG[da]);
            }
            FAILJ(0x80);   /* jo */
            st[da].k = E_REG;
            break;
        }
        case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE: {
            /* only as the test of the branch that follows */
            uint32_t npc = pc + (uint32_t)len;
            int nop_;
            int32_t off;
            int64_t t;
            Ent b, a;
            unsigned cc;
            if (npc >= n || (code[npc] != OP_JUMP_IF_FALSE && code[npc] != OP_JUMP_IF_TRUE) || target[npc] || depth < 2) goto fail;
            nop_ = code[npc];
            off = (int32_t)((uint32_t)code[npc + 1] | ((uint32_t)code[npc + 2] << 8) | ((uint32_t)code[npc + 3] << 16) | ((uint32_t)code[npc + 4] << 24));
            t = (int64_t)npc + 5 + off;
            b = st[--depth]; a = st[--depth];
            if (depth != 0 || a.k == E_SELF || b.k == E_SELF) goto fail;
            {   /* a is compared in a register: its own local register, or the bottom operand register */
                int ra;
                if (a.k == E_LOCAL) ra = LREG[a.v];
                else { st[0] = a; MAT(0); ra = SREG[0]; }
                if (b.k == E_IMM && fits32(b.v)) alu_ri(&c, 7U, ra, (int32_t)b.v);
                else {
                    int rb;
                    if (b.k == E_LOCAL) rb = LREG[b.v];
                    else { if (b.k == E_IMM) mov_ri(&c, SREG[1], b.v); rb = SREG[1]; }
                    rr(&c, 0x39, rb, ra);
                }
            }
            /* the jump is taken when the condition is false (JUMP_IF_FALSE) or true (JUMP_IF_TRUE) */
            switch (op) {
            case OP_LT: cc = nop_ == OP_JUMP_IF_FALSE ? 0x8dU : 0x8cU; break;   /* jge / jl */
            case OP_LE: cc = nop_ == OP_JUMP_IF_FALSE ? 0x8fU : 0x8eU; break;   /* jg / jle */
            case OP_GT: cc = nop_ == OP_JUMP_IF_FALSE ? 0x8eU : 0x8fU; break;   /* jle / jg */
            case OP_GE: cc = nop_ == OP_JUMP_IF_FALSE ? 0x8cU : 0x8dU; break;   /* jl / jge */
            case OP_EQ: cc = nop_ == OP_JUMP_IF_FALSE ? 0x85U : 0x84U; break;   /* jne / je */
            default:    cc = nop_ == OP_JUMP_IF_FALSE ? 0x84U : 0x85U; break;   /* NE: je / jne */
            }
            put(&c, 0x0f); put(&c, cc);
            if (nfix >= MAX_FIX) goto fail;
            fix[nfix].at = c.n; fix[nfix].is_fail = 0; fix[nfix].target_pc = (size_t)t; nfix++;
            put32(&c, 0);
            lab[npc] = (uint32_t)c.n;
            pc = npc + 5;
            continue;
        }
        case OP_JUMP: {
            int32_t off = (int32_t)((uint32_t)code[pc + 1] | ((uint32_t)code[pc + 2] << 8) | ((uint32_t)code[pc + 3] << 16) | ((uint32_t)code[pc + 4] << 24));
            if (depth != 0 || nfix >= MAX_FIX) goto fail;
            put(&c, 0xe9);
            fix[nfix].at = c.n; fix[nfix].is_fail = 0; fix[nfix].target_pc = (size_t)((int64_t)pc + 5 + off); nfix++;
            put32(&c, 0);
            reachable = 0;
            break;
        }
        case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE: goto fail;   /* a branch not fed by a comparison */
        case OP_RETURN: {
            Ent r;
            if (depth != 1) goto fail;
            r = st[--depth];
            if (r.k == E_SELF) goto fail;
            if (r.k == E_IMM) mov_ri(&c, R_AX, r.v);
            else if (r.k == E_LOCAL) mov_rr(&c, R_AX, LREG[r.v]);
            else mov_rr(&c, R_AX, SREG[0]);
            EPILOGUE();
            reachable = 0;
            break;
        }
        case OP_RETURN_NIL: goto fail;   /* a nil result is not an integer */
        case OP_CALL: {
            int nargs = code[pc + 1], m;
            if (nargs != np || depth < nargs + 1) goto fail;
            m = depth - nargs - 1;
            if (st[m].k != E_SELF) goto fail;
            for (int i = m + 1; i < depth; i++) if (st[i].k == E_SELF) goto fail;
            for (int i = 0; i < m; i++) { if (st[i].k == E_SELF) goto fail; if (st[i].k == E_REG) push_r(&c, SREG[i]); }
            if (nargs == 1) {
                Ent a = st[m + 1];
                if (a.k == E_IMM) mov_ri(&c, R_DI, a.v);
                else if (a.k == E_LOCAL) mov_rr(&c, R_DI, LREG[a.v]);
                else mov_rr(&c, R_DI, SREG[m + 1]);
            } else {
                for (int i = 0; i < nargs; i++) {
                    Ent a = st[m + 1 + i];
                    if (a.k == E_IMM) push_i(&c, (int32_t)a.v);
                    else if (a.k == E_LOCAL) push_r(&c, LREG[a.v]);
                    else push_r(&c, SREG[m + 1 + i]);
                    if (a.k == E_IMM && !fits32(a.v)) goto fail;
                }
                for (int i = nargs - 1; i >= 0; i--) pop_r(&c, AREG[i]);
            }
            /* one tick per call, and a floor under the recursion depth */
            put(&c, 0x49); put(&c, 0x83); put(&c, 0xed); put(&c, 0x01);   /* sub r13, 1 */
            FAILJ2(0x82, 2);                                                /* jb: budget */
            put(&c, 0x4c); put(&c, 0x39); put(&c, 0xf4);                    /* cmp rsp, r14 */
            FAILJ(0x82);
            put(&c, 0xe8);
            { int32_t rel = (int32_t)((int64_t)body_at - (int64_t)(c.n + 4)); put32(&c, rel); }
            depth = m;
            if (SREG[m] != R_AX) mov_rr(&c, SREG[m], R_AX);
            for (int i = m - 1; i >= 0; i--) if (st[i].k == E_REG) pop_r(&c, SREG[i]);
            st[m].k = E_REG; st[m].v = 0; depth = m + 1;
            break;
        }
        default: goto fail;
        }
        pc += (uint32_t)len;
    }
    if (!c.ok || self_idx < 0) goto fail;
    for (int i = 0; i < nfix; i++) {
        int64_t tgt;
        int32_t rel;
        if (fix[i].is_fail == 2) tgt = (int64_t)fail_budget_at;
        else if (fix[i].is_fail) tgt = (int64_t)fail_at_stub;
        else {
            if (fix[i].target_pc >= n || !istart[fix[i].target_pc]) goto fail;
            tgt = (int64_t)lab[fix[i].target_pc];
        }
        rel = (int32_t)(tgt - (int64_t)(fix[i].at + 4));
        memcpy(c.b + fix[i].at, &rel, 4);
    }
    page = (size_t)sysconf(_SC_PAGESIZE);
    msize = ((c.n + page - 1) / page) * page;
    mem = (uint8_t *)mmap(NULL, msize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) { mem = NULL; goto fail; }
    memcpy(mem, c.b, c.n);
    if (mprotect(mem, msize, PROT_READ | PROT_EXEC) != 0) { (void)munmap(mem, msize); goto fail; }
    jp = (JitPure *)calloc(1, sizeof *jp);
    if (!jp) { (void)munmap(mem, msize); goto fail; }
    jp->mem = mem; jp->msize = msize;
    memcpy(&jp->stub, &mem, sizeof mem);
    jp->self_idx = (unsigned)self_idx;
    jp->nparams = np;
    free(lab); free(istart); free(target); free(c.b);
    return jp;
fail:
    free(lab); free(istart); free(target); free(c.b);
    return NULL;
}

void jit_pure_free(Proto *p) {
    JitPure *jp = p->pure;
    if (!jp) return;
    if (jp->mem) (void)munmap(jp->mem, jp->msize);
    free(jp);
    p->pure = NULL;
}

/* Run the call natively: args are the already-evaluated arguments (n == nparams).  1 = done (*out is the result, *left the budget
 * remaining); 0 = nothing happened, the interpreter does the call. */
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
    /* The interpreter's budget comes in chunks; a native run takes up to PURE_EXTRA more ticks (about a third of a second) from the
     * instruction bank, so deadlines and interrupts are still noticed, and a longer run is abandoned for the interpreter. */
    {
        uint64_t take = PURE_EXTRA, total, rem, used;
        if (vm->ibank != UINT64_MAX && vm->ibank < take) take = vm->ibank;
        total = *left > UINT64_MAX - take ? UINT64_MAX : *left + take;
        state.budget = total;
        state.result = 0;
        {   /* the interpreter allows max_frames nested calls: never let the native recursion go deeper (it would then succeed where the
             * interpreter reports the limit); a frame is at least 8 * (parameters + 1) bytes */
            int64_t room = (int64_t)vm->max_frames - (int64_t)vm->nframes - 2;
            uint64_t fmin = 8U * ((uint64_t)jp->nparams + 1U);
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

JitPure *jit_pure_compile(VM *vm, Proto *p) { (void)vm; (void)p; return NULL; }
void jit_pure_free(Proto *p) { (void)p; }
int jit_pure_enter(VM *vm, Proto *p, const SpValue *args, uint64_t *left, int64_t *out) { (void)vm; (void)p; (void)args; (void)left; (void)out; return 0; }

#endif
