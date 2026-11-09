/* Constructor bytecode-shape analysis: a cold class-cache miss path. */
#include "../vm_int.h"
#include "internal.h"

static unsigned rd16(const uint8_t *p) { return (unsigned)p[0] | ((unsigned)p[1] << 8); }

/* Construction fast path. The compiler-generated constructor (SPEC 10.3) has a fixed shape; when every
 * field initialiser is a constant, `C(args)` can allocate the instance, store the initial slot values and
 * run `init` directly, without the constructor frame, the rest array and the spread call. The shape is
 * recognised from the bytecode (also after quickening), so program images need no extra information. */
static int ctor_const(const uint8_t *c, uint32_t n, uint32_t *pc, const Proto *p, SpValue *out) {
    if (*pc >= n) return 0;
    switch (c[*pc]) {
    case OP_CONST: { unsigned k = rd16(c + *pc + 1); if (k >= (unsigned)p->nconsts) return 0; *out = p->consts[k]; *pc += 3; return 1; }
    case OP_SMALLINT: *out = v_int((int16_t)rd16(c + *pc + 1)); *pc += 3; return 1;
    case OP_NIL: *out = v_nil(); *pc += 1; return 1;
    case OP_TRUE: *out = v_bool(1); *pc += 1; return 1;
    case OP_FALSE: *out = v_bool(0); *pc += 1; return 1;
    default: return 0;
    }
}

/* Recognise the constructor's shape. On success fills d[] (initial slot values), *has_init and *init. */
static int ctor_shape(const SClass *cls, SpValue *d, int *any, SFunc **init) {
    const Proto *p = cls->ctor->proto;
    const uint8_t *c = p->code;
    uint32_t n = p->code_len, pc = 7;
    if (n < 11 || c[0] != OP_LOAD_MODULE || c[3] != OP_NEW_INSTANCE || c[4] != OP_STORE_LOCAL) return 0;
    unsigned self = rd16(c + 5);
    while (pc + 3 <= n && c[pc] == OP_LOAD_LOCAL && rd16(c + pc + 1) == self) {
        uint32_t q = pc + 3;
        SpValue v;
        if (!ctor_const(c, n, &q, p, &v)) return 0;
        if (q + 3 > n || c[q] != OP_SET_SLOT) return 0;
        unsigned slot = rd16(c + q + 1);
        if ((int)slot >= cls->nfields) return 0;
        d[slot] = v;
        *any = 1;
        pc = q + 3;
    }
    *init = NULL;
    if (pc + 3 <= n && c[pc] == OP_LOAD_MODULE) {
        /* LOAD_MODULE ik; GET_MEMBER init; LOAD_LOCAL self; LOAD_LOCAL rest; CALL_SPREAD 1; POP */
        if (pc + 15 > n || c[pc + 3] != OP_GET_MEMBER || c[pc + 6] != OP_LOAD_LOCAL || rd16(c + pc + 7) != self ||
            c[pc + 9] != OP_LOAD_LOCAL || c[pc + 12] != OP_CALL_SPREAD || c[pc + 13] != 1 || c[pc + 14] != OP_POP)
            return 0;
        pc += 15;
        const SString *key = NULL;
        for (int k = 0; k < p->nconsts && !key; k++) {
            const SpValue *cv = &p->consts[k];
            if (cv->type == T_STRING && AS_STR(*cv)->len == 4 && memcmp(AS_STR(*cv)->dp, "init", 4) == 0) key = AS_STR(*cv);
        }
        SpValue mv;
        if (!key || !table_get_sstr(cls->methods, key, &mv) || mv.type != T_FUNCTION || AS_FUNC(mv)->nat) return 0;
        *init = AS_FUNC(mv);
    } else if (pc + 3 <= n && c[pc] == OP_CTOR_CHECK) {
        pc += 3;
    } else {
        return 0;
    }
    /* LOAD_LOCAL self; RETURN (or its quickened form) */
    if (pc + 4 > n) return 0;
    return (c[pc] == OP_LOAD_LOCAL && rd16(c + pc + 1) == self && c[pc + 3] == OP_RETURN) ||
           (c[pc] == OP_Q_RET_LOCAL && rd16(c + pc + 1) == self);
}

void vm_class_analyze(SClass *cls) {
    cls->fast = 2;
    if (!cls->ctor || cls->ctor->nat) return;
    SpValue *d = NULL;
    if (cls->nfields > 0) {
        d = malloc((size_t)cls->nfields * sizeof *d);
        if (!d) return;
        for (int i = 0; i < cls->nfields; i++) d[i] = v_nil();
    }
    int any = 0;
    SFunc *init = NULL;
    if (ctor_shape(cls, d, &any, &init)) {
        cls->init = init;
        cls->dflt = any ? d : NULL;
        if (!any) free(d);
        cls->fast = 1;
    } else {
        free(d);
    }
}

