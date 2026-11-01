/* Bytecode quickening: cold program-load / REPL append path. */
#include "../vm_int.h"
#include "internal.h"

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static unsigned rd16(const uint8_t *p) { return (unsigned)p[0] | ((unsigned)p[1] << 8); }

/* Fused-opcode selection: LOCAL,SMALLINT,binop[,JUMP_IF_FALSE] and
 * LOCAL,LOCAL,binop[,JUMP_IF_FALSE], and RANGE_NEXT,STORE_LOCAL. Only the first
 * byte of a sequence is replaced (see enum Op). */
static int q_cmp_index(int op) {
    switch (op) {
    case OP_LT: return 0; case OP_LE: return 1; case OP_GT: return 2;
    case OP_GE: return 3; case OP_EQ: return 4; case OP_NE: return 5;
    default: return -1;
    }
}

void vm_proto_quicken(Proto *p) {
    if (!p->ocode && SP_JIT && p->code_len > 0) {
        p->ocode = malloc(p->code_len);   /* the JIT compiles from the pristine bytecode */
        if (p->ocode) memcpy(p->ocode, p->code, p->code_len);
    }
    uint8_t *w = p->code;
    const uint8_t *c = p->code;
    uint32_t n = p->code_len, pc = 0;
    uint32_t *jumps = NULL;
    size_t nj = 0, capj = 0;
    while (pc < n) {
        int op = c[pc];
        int len = op_len(op);
        if (len <= 0) break;
        if (op == OP_JUMP) {
            if (nj == capj) {
                size_t nc = capj ? capj * 2 : 16;
                uint32_t *t = realloc(jumps, nc * sizeof *t);
                if (!t) break;
                jumps = t;
                capj = nc;
            }
            jumps[nj++] = pc;
        }
        if (op == OP_LOAD_UPVAL && pc + 10 <= n && c[pc + 3] == OP_SMALLINT && c[pc + 6] == OP_ADD && c[pc + 7] == OP_STORE_UPVAL &&
            rd16(c + pc + 8) == rd16(c + pc + 1)) {
            w[pc] = OP_Q_UP_INC;   /* u += k */
        } else if (op == OP_LOAD_UPVAL && pc + 4 <= n && c[pc + 3] == OP_RETURN) {
            w[pc] = OP_Q_RET_UP;
        } else if (op == OP_LOAD_LOCAL && pc + 17 <= n && c[pc + 3] == OP_SMALLINT && c[pc + 6] == OP_MOD && c[pc + 7] == OP_SMALLINT &&
                   (c[pc + 10] == OP_EQ || c[pc + 10] == OP_NE) && c[pc + 11] == OP_JUMP_IF_FALSE) {
            w[pc] = c[pc + 10] == OP_EQ ? OP_Q_MODEQ_JF : OP_Q_MODNE_JF;   /* if x % m == k / != k */
        } else if ((op == OP_LOAD_LOCAL || op == OP_LOAD_MODULE) && pc + 14 <= n && c[pc + 3] == OP_LOAD_LOCAL && c[pc + 6] == OP_SMALLINT &&
            (c[pc + 9] == OP_MOD || c[pc + 9] == OP_MUL || c[pc + 9] == OP_ADD || c[pc + 9] == OP_SUB) &&
            c[pc + 10] == OP_ADD && c[pc + 11] == (op == OP_LOAD_LOCAL ? OP_STORE_LOCAL : OP_STORE_MODULE) &&
            rd16(c + pc + 12) == rd16(c + pc + 1)) {
            int module_dst = op == OP_LOAD_MODULE;
            int arithmetic = c[pc + 9];
            if (module_dst) {
                w[pc] = arithmetic == OP_MOD ? OP_Q_ACC_IM_MOD :
                        arithmetic == OP_MUL ? OP_Q_ACC_IM_MUL :
                        arithmetic == OP_SUB ? OP_Q_ACC_IM_SUB : OP_Q_ACC_IM;
            } else {
                w[pc] = arithmetic == OP_MOD ? OP_Q_ACC_I_MOD :
                        arithmetic == OP_MUL ? OP_Q_ACC_I_MUL :
                        arithmetic == OP_SUB ? OP_Q_ACC_I_SUB : OP_Q_ACC_I;
            }   /* s += x <op> k; specialize op and destination once at quickening */
        } else if ((op == OP_LOAD_LOCAL || op == OP_LOAD_MODULE) && pc + 10 <= n && c[pc + 3] == OP_LOAD_LOCAL && c[pc + 6] == OP_ADD &&
                   c[pc + 7] == (op == OP_LOAD_LOCAL ? OP_STORE_LOCAL : OP_STORE_MODULE) && rd16(c + pc + 8) == rd16(c + pc + 1)) {
            w[pc] = op == OP_LOAD_LOCAL ? OP_Q_ACC_L : OP_Q_ACC_LM;   /* s += x */
        } else if (op == OP_LOAD_LOCAL && pc + 10 <= n && c[pc + 3] == OP_LOAD_LOCAL && c[pc + 6] == OP_LOAD_LOCAL &&
                   c[pc + 9] == OP_SET_INDEX) {
            w[pc] = OP_Q_SETIDX_LLL;   /* a[i] = v */
        } else if (op == OP_LOAD_LOCAL && pc + 8 <= n && c[pc + 3] == OP_LOAD_LOCAL && (c[pc + 6] == OP_TRUE || c[pc + 6] == OP_FALSE) &&
                   c[pc + 7] == OP_SET_INDEX) {
            w[pc] = OP_Q_SETIDX_LLB;   /* a[i] = bool */
        } else if (op == OP_LOAD_LOCAL && pc + 4 <= n && (c[pc + 3] == OP_GET_MEMBER || c[pc + 3] == OP_RETURN)) {
            w[pc] = c[pc + 3] == OP_RETURN ? OP_Q_RET_LOCAL : OP_Q_LOCAL_GETM;
        } else if (op == OP_LOAD_LOCAL && pc + 4 <= n && c[pc + 3] == OP_GET_INDEX) {
            w[pc] = OP_Q_IDX_L;   /* top[local] */
        } else if (op == OP_LOAD_LOCAL && pc + 4 <= n && (c[pc + 3] == OP_ADD || c[pc + 3] == OP_SUB || c[pc + 3] == OP_MUL || c[pc + 3] == OP_DIV)) {
            w[pc] = (uint8_t)(c[pc + 3] == OP_ADD ? OP_Q_ADD_L : c[pc + 3] == OP_SUB ? OP_Q_SUB_L : c[pc + 3] == OP_MUL ? OP_Q_MUL_L : OP_Q_DIV_L);   /* top <op> local */
        } else if (op == OP_LOAD_LOCAL && pc + 7 <= n && (c[pc + 3] == OP_SMALLINT || c[pc + 3] == OP_LOAD_LOCAL)) {
            int imm = c[pc + 3] == OP_SMALLINT;
            int b = c[pc + 6];
            int ci = q_cmp_index(b);
            int q = 0;
            if (ci >= 0) {
                int jf = pc + 12 <= n && c[pc + 7] == OP_JUMP_IF_FALSE;
                q = jf ? (imm ? OP_Q_LLI_LT_JF : OP_Q_LLL_LT_JF) + ci : (imm ? OP_Q_LLI_LT : OP_Q_LLL_LT) + ci;
            } else if (b == OP_ADD) q = imm ? OP_Q_LLI_ADD : OP_Q_LLL_ADD;
            else if (b == OP_SUB) q = imm ? OP_Q_LLI_SUB : OP_Q_LLL_SUB;
            else if (b == OP_MOD && imm) q = OP_Q_LLI_MOD;
            else if (b == OP_MUL) q = imm ? OP_Q_LLI_MUL : OP_Q_LLL_MUL;
            else if (b == OP_DIV && !imm) q = OP_Q_LLL_DIV;
            else if (b == OP_FLOOR_DIV && imm) q = OP_Q_LLI_FDIV;
            else if (b == OP_GET_INDEX && !imm) q = OP_Q_LL_IDX;
            if (imm && pc + 10 <= n && c[pc + 7] == OP_STORE_LOCAL) {
                if (b == OP_ADD) q = OP_Q_LLI_ADD_ST;
                else if (b == OP_SUB) q = OP_Q_LLI_SUB_ST;
            }
            if (q) w[pc] = (uint8_t)q;
        } else if (op == OP_SMALLINT && pc + 9 <= n && q_cmp_index(c[pc + 3]) >= 0 && c[pc + 4] == OP_JUMP_IF_FALSE) {
            w[pc] = (uint8_t)(OP_Q_SI_LT_JF + q_cmp_index(c[pc + 3]));   /* if x <cmp> k */
        } else if (op == OP_SMALLINT && pc + 7 <= n && c[pc + 3] == OP_LOAD_LOCAL && (c[pc + 6] == OP_ADD || c[pc + 6] == OP_MUL)) {
            w[pc] = c[pc + 6] == OP_ADD ? OP_Q_IL_ADD : OP_Q_IL_MUL;   /* k + x, k * x */
        } else if (op == OP_SMALLINT && pc + 4 <= n && (c[pc + 3] == OP_ADD || c[pc + 3] == OP_SUB || c[pc + 3] == OP_MUL)) {
            w[pc] = (uint8_t)(c[pc + 3] == OP_ADD ? OP_Q_SI_ADD : c[pc + 3] == OP_SUB ? OP_Q_SI_SUB : OP_Q_SI_MUL);
        } else if ((op == OP_ADD || op == OP_SUB) && pc + 4 <= n && c[pc + 1] == OP_STORE_LOCAL) {
            w[pc] = (uint8_t)(op == OP_ADD ? OP_Q_ADD_ST : OP_Q_SUB_ST);
        } else if (op == OP_MUL && pc + 4 <= n && c[pc + 1] == OP_STORE_LOCAL) {
            w[pc] = OP_Q_MUL_ST;
        } else if ((op == OP_ADD || op == OP_SUB) && pc + 4 <= n && c[pc + 1] == OP_STORE_MODULE) {
            w[pc] = (uint8_t)(op == OP_ADD ? OP_Q_ADD_STM : OP_Q_SUB_STM);
        } else if (op == OP_RANGE_NEXT && pc + 10 <= n && c[pc + 7] == OP_STORE_LOCAL) {
            w[pc] = OP_Q_RANGE_NEXT_ST;
        } else if (op == OP_INVOKE && pc + 4 <= n) {
            unsigned k = rd16(c + pc + 1);
            if (k < (unsigned)p->nconsts && p->consts[k].type == T_STRING) {
                int id = lib_string_method_id(AS_STR(p->consts[k]));
                if (id >= 0 && id <= OP_Q_INVOKE_STR_LAST - OP_Q_INVOKE_STR_FIRST)
                    w[pc] = (uint8_t)(OP_Q_INVOKE_STR_FIRST + id);
            }
        }
        pc += (uint32_t)len;
    }
    /* second pass: a jump whose target is a fused loop head runs that head inline */
    for (size_t i = 0; i < nj; i++) {
        uint32_t jp = jumps[i];
        int64_t t = (int64_t)jp + 5 + (int32_t)rd32(c + jp + 1);
        if (t < 0 || t >= (int64_t)n) continue;
        int tq = c[t];
        if (tq == OP_Q_RANGE_NEXT_ST) w[jp] = OP_Q_JUMP_RN;
        else if (tq == OP_Q_LLL_LT_JF) w[jp] = OP_Q_JUMP_LLL_LT;
        else if (tq == OP_Q_LLI_LT_JF) w[jp] = OP_Q_JUMP_LLI_LT;
        else if ((tq > OP_Q_LLI_LT_JF && tq <= OP_Q_LLI_NE_JF) || (tq > OP_Q_LLL_LT_JF && tq <= OP_Q_LLL_NE_JF)) w[jp] = OP_Q_JUMP_JF;
    }
    free(jumps);
}

void prog_quicken(Program *pg) {
    for (int i = 0; i < pg->nprotos; i++) vm_proto_quicken(pg->protos[i]);
}

