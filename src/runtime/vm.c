/* Layer 6: the interpreter (SPEC 17): arithmetic, indexing, the dispatch loop. No C recursion for Sprint calls. */
#include "vm_int.h"
#include "vm/internal.h"

static const ICEnt *ic_fill(VM *vm, ICEnt *e, const SClass *k, const SString *name);

/* ---------------------------------------------------------------- */
/* arithmetic                                                        */
/* ---------------------------------------------------------------- */
static const char *op_sym(int op) {
    switch (op) {
    case OP_ADD: return "+"; case OP_SUB: return "-"; case OP_MUL: return "*";
    case OP_DIV: return "/"; case OP_FLOOR_DIV: return "//"; case OP_MOD: return "%";
    case OP_POW: return "**"; case OP_BAND: return "&"; case OP_BOR: return "|";
    case OP_BXOR: return "^"; case OP_SHL: return "<<"; case OP_SHR: return ">>";
    default: return "?";
    }
}

static int add_ovf(int64_t x, int64_t y, int64_t *r) {
#if defined(__GNUC__)
    return __builtin_add_overflow(x, y, r);
#else
    uint64_t u = (uint64_t)x + (uint64_t)y;
    *r = (int64_t)u;
    return (((x ^ *r) & (y ^ *r)) < 0);
#endif
}
static int sub_ovf(int64_t x, int64_t y, int64_t *r) {
#if defined(__GNUC__)
    return __builtin_sub_overflow(x, y, r);
#else
    uint64_t u = (uint64_t)x - (uint64_t)y;
    *r = (int64_t)u;
    return (((x ^ y) & (x ^ *r)) < 0);
#endif
}
static int mul_ovf(int64_t x, int64_t y, int64_t *r) {
#if defined(__GNUC__)
    return __builtin_mul_overflow(x, y, r);
#else
    if (x == 0 || y == 0) { *r = 0; return 0; }
    if ((x == -1 && y == INT64_MIN) || (y == -1 && x == INT64_MIN)) { *r = INT64_MIN; return 1; }
    *r = (int64_t)((uint64_t)x * (uint64_t)y);
    return (x != -1 && *r / x != y) || (x == -1 && *r != -y);
#endif
}

static double tof(SpValue v) { return v.type == T_INT ? (double)v.as.i : v.as.f; }

static int ipow(int64_t b, int64_t e, int64_t *out) {
    int64_t r = 1;
    while (e > 0) {
        if (e & 1) { if (mul_ovf(r, b, &r)) return 1; }
        e >>= 1;
        if (e > 0 && mul_ovf(b, b, &b)) return 1;
    }
    *out = r;
    return 0;
}

static int arith(VM *vm, int op, SpValue a, SpValue b, SpValue *out) {
    if (a.type == T_INT && b.type == T_INT) {
        int64_t x = a.as.i, y = b.as.i, r;
        switch (op) {
        case OP_ADD: if (add_ovf(x, y, &r)) return vm_set_error(vm, E_ARITH, "integer overflow in +"); *out = v_int(r); return 0;
        case OP_SUB: if (sub_ovf(x, y, &r)) return vm_set_error(vm, E_ARITH, "integer overflow in -"); *out = v_int(r); return 0;
        case OP_MUL: if (mul_ovf(x, y, &r)) return vm_set_error(vm, E_ARITH, "integer overflow in *"); *out = v_int(r); return 0;
        case OP_DIV:
            if (y == 0) return vm_set_error(vm, E_ARITH, "division by zero");
            *out = v_float((double)x / (double)y);
            return 0;
        case OP_FLOOR_DIV:
            if (y == 0) return vm_set_error(vm, E_ARITH, "division by zero");
            if (x == INT64_MIN && y == -1) return vm_set_error(vm, E_ARITH, "integer overflow in //");
            r = x / y;
            if ((x % y != 0) && ((x < 0) != (y < 0))) r--;
            *out = v_int(r);
            return 0;
        case OP_MOD:
            if (y == 0) return vm_set_error(vm, E_ARITH, "modulo by zero");
            if (y == -1) { *out = v_int(0); return 0; }
            if (((uint64_t)x | (uint64_t)y) >> 32 == 0) { *out = v_int((int64_t)((uint32_t)x % (uint32_t)y)); return 0; }
            r = x % y;
            if (r != 0 && ((r < 0) != (y < 0))) r += y;
            *out = v_int(r);
            return 0;
        case OP_POW:
            if (y >= 0) {
                if (ipow(x, y, &r)) return vm_set_error(vm, E_ARITH, "integer overflow in **");
                *out = v_int(r);
            } else {
                if (x == 0) return vm_set_error(vm, E_ARITH, "zero raised to a negative power");
                *out = v_float(pow((double)x, (double)y));
            }
            return 0;
        default: break;
        }
    }
    if (IS_NUM(a) && IS_NUM(b)) {
        double x = tof(a), y = tof(b);
        switch (op) {
        case OP_ADD: *out = v_float(x + y); return 0;
        case OP_SUB: *out = v_float(x - y); return 0;
        case OP_MUL: *out = v_float(x * y); return 0;
        case OP_DIV:
            if (sp_feq(y, 0.0)) return vm_set_error(vm, E_ARITH, "division by zero");
            *out = v_float(x / y);
            return 0;
        case OP_FLOOR_DIV:
            if (sp_feq(y, 0.0)) return vm_set_error(vm, E_ARITH, "division by zero");
            *out = v_float(floor(x / y));
            return 0;
        case OP_MOD: {
            if (sp_feq(y, 0.0)) return vm_set_error(vm, E_ARITH, "modulo by zero");
            double r = fmod(x, y);
            if (!sp_feq(r, 0.0) && ((r < 0) != (y < 0))) r += y;
            *out = v_float(r);
            return 0;
        }
        case OP_POW: *out = v_float(pow(x, y)); return 0;
        default: break;
        }
    }
    return vm_set_error(vm, E_TYPE, "unsupported operand types for %s: %s and %s", op_sym(op),
                        type_name(a), type_name(b));
}

static int bitop(VM *vm, int op, SpValue a, SpValue b, SpValue *out) {
    if (a.type != T_INT || b.type != T_INT)
        return vm_set_error(vm, E_TYPE, "unsupported operand types for %s: %s and %s", op_sym(op),
                            type_name(a), type_name(b));
    int64_t x = a.as.i, y = b.as.i;
    switch (op) {
    case OP_BAND: *out = v_int(x & y); return 0;
    case OP_BOR: *out = v_int(x | y); return 0;
    case OP_BXOR: *out = v_int(x ^ y); return 0;
    case OP_SHL:
        if (y < 0) return vm_set_error(vm, E_VALUE, "negative shift count");
        *out = v_int(y >= 64 ? 0 : (int64_t)((uint64_t)x << y));
        return 0;
    default: /* OP_SHR */
        if (y < 0) return vm_set_error(vm, E_VALUE, "negative shift count");
        if (y >= 64) *out = v_int(x < 0 ? -1 : 0);
        else *out = v_int(x < 0 ? ~((~x) >> y) : (x >> y));
        return 0;
    }
}

/* returns -1,0,1 or sets error and returns 2 */
static int compare(VM *vm, SpValue a, SpValue b, int *unordered) {
    *unordered = 0;
    if (IS_NUM(a) && IS_NUM(b)) return num_cmp(a, b, unordered);
    if (a.type == T_STRING && b.type == T_STRING) {
        SString *x = AS_STR(a), *y = AS_STR(b);
        size_t n = x->len < y->len ? x->len : y->len;
        int c = memcmp(x->data, y->data, n);
        if (c != 0) return c < 0 ? -1 : 1;
        return x->len < y->len ? -1 : x->len > y->len;
    }
    (void)vm_set_error(vm, E_TYPE, "cannot compare %s with %s", type_name(a), type_name(b));
    return 2;
}

/* ---------------------------------------------------------------- */
/* indexing and members                                              */
/* ---------------------------------------------------------------- */
static int get_index(VM *vm, SpValue o, SpValue k, SpValue *out) {
    switch (o.type) {
    case T_ARRAY: {
        if (k.type != T_INT) return vm_set_error(vm, E_TYPE, "array index must be int, not %s", type_name(k));
        SArray *a = AS_ARRAY(o);
        if (k.as.i < 0 || k.as.i >= a->len)
            return vm_set_error(vm, E_INDEX, "array index %lld out of range (length %lld)", (long long)k.as.i, (long long)a->len);
        *out = a->items[k.as.i];
        return 0;
    }
    case T_STRING: {
        if (k.type != T_INT) return vm_set_error(vm, E_TYPE, "string index must be int, not %s", type_name(k));
        SString *s = AS_STR(o);
        if (k.as.i < 0 || k.as.i >= (int64_t)s->len)
            return vm_set_error(vm, E_INDEX, "string index %lld out of range (length %u)", (long long)k.as.i, s->len);
        *out = v_int((unsigned char)s->data[k.as.i]);
        return 0;
    }
    case T_TABLE: return table_get(vm, AS_TABLE(o), k, out, NULL);
    case T_NATIVE:
        if (typed_is(o)) return typed_get(vm, o, k, out);
        return vm_set_error(vm, E_TYPE, "'%s' object is not subscriptable", type_name(o));
    default: return vm_set_error(vm, E_TYPE, "'%s' object is not subscriptable", type_name(o));
    }
}

static int set_index(VM *vm, SpValue o, SpValue k, SpValue v) {
    switch (o.type) {
    case T_ARRAY: {
        if (k.type != T_INT) return vm_set_error(vm, E_TYPE, "array index must be int, not %s", type_name(k));
        SArray *a = AS_ARRAY(o);
        if (k.as.i < 0 || k.as.i >= a->len)
            return vm_set_error(vm, E_INDEX, "array index %lld out of range (length %lld)", (long long)k.as.i, (long long)a->len);
        a->items[k.as.i] = v;
        return 0;
    }
    case T_TABLE: return table_set(vm, AS_TABLE(o), k, v);
    case T_STRING: return vm_set_error(vm, E_TYPE, "strings are immutable");
    case T_NATIVE:
        if (typed_is(o)) return typed_set(vm, o, k, v);
        return vm_set_error(vm, E_TYPE, "'%s' object does not support item assignment", type_name(o));
    default: return vm_set_error(vm, E_TYPE, "'%s' object does not support item assignment", type_name(o));
    }
}

static inline const ICEnt *ic_find(VM *vm, const SClass *k, const SString *name) {
    ICEnt *e = &vm->ic[(((uintptr_t)k >> 4) ^ ((uintptr_t)name >> 4) ^ str_hash_peek(name)) & (IC_SIZE - 1)];
    if (e->cls == k && e->name == name) return e;
    return ic_fill(vm, e, k, name);
}

static const ICEnt *ic_fill(VM *vm, ICEnt *e, const SClass *k, const SString *name) {
    (void)vm;
    SpValue sv;
    if (table_get_sstr(k->fields, name, &sv)) { e->kind = 1; e->slot = sv.as.i; e->fn = v_nil(); }
    else if (table_get_sstr(k->methods, name, &sv)) { e->kind = 2; e->slot = 0; e->fn = sv; }
    else return NULL;
    e->cls = k;
    e->name = name;
    return e;
}

/* table lookup through the member cache; 0 when the key is absent */
static inline int mc_get(VM *vm, const STable *t, const SString *name, SpValue *out) {
    MCEnt *e = &vm->mc[(((uintptr_t)t >> 4) ^ ((uintptr_t)name >> 4)) & (MC_SIZE - 1)];
    if (e->t == t && e->name == name && e->idx < t->nent) {
        const TEntry *te = &t->ents[e->idx];
        if (te->key.type == T_STRING && AS_STR(te->key) == e->ks) { *out = te->val; return 1; }
    }
    int64_t i = table_find_sstr(t, name);
    if (i < 0) return 0;
    e->t = t;
    e->name = name;
    e->ks = AS_STR(t->ents[i].key);
    e->idx = i;
    *out = t->ents[i].val;
    return 1;
}

static int get_member(VM *vm, SpValue o, SString *name, SpValue *out) {
    switch (o.type) {
    case T_TABLE:
        if (!mc_get(vm, AS_TABLE(o), name, out)) *out = v_nil();
        return 0;
    case T_MODULE:
        if (!mc_get(vm, AS_MODULE(o)->exports, name, out))
            return vm_set_error(vm, E_NAME, "module '%s' has no export '%s'", AS_MODULE(o)->name->data, name->data);
        return 0;
    case T_ERROR: {
        SError *e = AS_ERROR(o);
        const char *n = name->data;
        if (strcmp(n, "kind") == 0) *out = v_obj(T_STRING, e->kind);
        else if (strcmp(n, "code") == 0) *out = v_int(e->code);
        else if (strcmp(n, "message") == 0) *out = v_obj(T_STRING, e->message);
        else if (strcmp(n, "cause") == 0) *out = e->cause;
        else if (strcmp(n, "data") == 0) *out = e->data;
        else if (strcmp(n, "suppressed") == 0) *out = e->suppressed;
        else if (strcmp(n, "file") == 0) *out = v_obj(T_STRING, e->file);
        else if (strcmp(n, "line") == 0) *out = v_int(e->line);
        else if (strcmp(n, "column") == 0) *out = v_int(e->col);
        else if (strcmp(n, "trace") == 0) *out = v_obj(T_STRING, e->trace);
        else return vm_set_error(vm, E_NAME, "error has no field '%s'", n);
        return 0;
    }
    case T_INSTANCE: {
        SInstance *in = AS_INSTANCE(o);
        const ICEnt *ce = ic_find(vm, in->cls, name);
        if (ce) { *out = ce->kind == 1 ? in->slots[ce->slot] : ce->fn; return 0; }
        return vm_set_error(vm, E_NAME, "'%s' instance has no field or method '%s'", in->cls->name->data, name->data);
    }
    case T_CLASS: {
        SClass *k = AS_CLASS(o);
        const ICEnt *ce = ic_find(vm, k, name);
        if (ce && ce->kind == 2) { *out = ce->fn; return 0; }
        return vm_set_error(vm, E_NAME, "class '%s' has no method '%s'", k->name->data, name->data);
    }
    case T_ARRAY: case T_STRING:
        if (sp_invoke_method_exists(o.type, name->data, name->len))
            return vm_set_error(vm, E_TYPE, "method '%s' of %s must be called (no bound methods)", name->data, type_name(o));
        return vm_set_error(vm, E_NAME, "'%s' has no member '%s'", type_name(o), name->data);
    default:
        return vm_set_error(vm, E_TYPE, "'%s' object has no members", type_name(o));
    }
}

static int set_member(VM *vm, SpValue o, SString *name, SpValue v) {
    switch (o.type) {
    case T_TABLE: return table_set(vm, AS_TABLE(o), v_obj(T_STRING, name), v);
    case T_MODULE: return vm_set_error(vm, E_CONST, "cannot assign to module member '%s'", name->data);
    case T_ERROR: return vm_set_error(vm, E_TYPE, "error values are immutable");
    case T_INSTANCE: {
        SInstance *in = AS_INSTANCE(o);
        const ICEnt *ce = ic_find(vm, in->cls, name);
        if (ce && ce->kind == 1) { in->slots[ce->slot] = v; return 0; }
        if (ce)
            return vm_set_error(vm, E_TYPE, "cannot assign to method '%s'", name->data);
        return vm_set_error(vm, E_NAME, "'%s' instance has no field '%s'", in->cls->name->data, name->data);
    }
    case T_CLASS: return vm_set_error(vm, E_TYPE, "cannot assign to a class member");
    default: return vm_set_error(vm, E_TYPE, "'%s' object does not support member assignment", type_name(o));
    }
}

/* ---------------------------------------------------------------- */
/* interpreter                                                       */
/* ---------------------------------------------------------------- */
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static unsigned rd16(const uint8_t *p) { return (unsigned)p[0] | ((unsigned)p[1] << 8); }


static SpValue take_pending(VM *vm) {
    if (vm->pend_obj.type != T_NIL) {
        SpValue ev = vm->pend_obj;
        vm->pend_obj = v_nil();
        return ev;
    }
    const char *kn = err_kind_name(vm->pend_code);
    SError *e = vm_new_error(vm, vm->pend_code, kn, strlen(kn), vm->pend_msg, strlen(vm->pend_msg));
    return v_obj(T_ERROR, e);
}

static int uncatchable(const SError *e) { return e->code == E_PANIC || e->code == E_CLOSE; }

/* SPEC 12.4.3: a deferred call failed with e2 while e1 was propagating. */
static SpValue combine_errors(SpValue e1, SpValue e2) {
    SError *a = AS_ERROR(e1), *b = AS_ERROR(e2);
    if (uncatchable(b)) return e2;
    if (uncatchable(a)) return e1;
    if (a->suppressed.type == T_NIL) a->suppressed = e2;
    return e1;
}

/* Validate a defer target at registration time (arity included), so that
 * running it later cannot fail in call setup. */
static int check_callable(VM *vm, const SpValue *fv, int nargs) {
    if (fv->type != T_FUNCTION) return vm_set_error(vm, E_TYPE, "'%s' object is not callable", type_name(*fv));
    const SFunc *f = AS_FUNC(*fv);
    if (f->nat) {
        const NativeDesc *d = f->nat;
        if (nargs < d->min_args || (d->max_args >= 0 && nargs > d->max_args))
            return vm_set_error(vm, E_TYPE, "%s() called with wrong number of arguments (%d)", d->name, nargs);
        return 0;
    }
    const Proto *p = f->proto;
    if (nargs < p->nrequired || (!p->has_rest && nargs > p->nparams))
        return vm_set_error(vm, E_TYPE, "%s() called with wrong number of arguments (%d)", p->name ? p->name : "<anonymous>", nargs);
    return 0;
}

static void defer_register(VM *vm, SpValue *vals, int nvals, SString *method) {
    if (vm->ndr >= vm->drcap || vm->ndv + nvals > vm->dvcap)
        vm_fatal(vm, RS_MEMORY, "defer limit exceeded");
    for (int i = 0; i < nvals; i++) vm->dvals[vm->ndv + i] = vals[i];
    vm->ndv += nvals;
    vm->drecs[vm->ndr].nvals = nvals;
    vm->drecs[vm->ndr].method = method;
    vm->ndr++;
}

/* number of decimal characters sp_fmt_int would produce */
static size_t int_len(int64_t v) {
    uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    size_t n = v < 0 ? 2 : 1;
    while (u >= 10000) { u /= 10000; n += 4; }
    if (u >= 1000) return n + 3;
    if (u >= 100) return n + 2;
    if (u >= 10) return n + 1;
    return n;
}

/* CONCAT fast path: every operand is a string or an int. Returns the new string, or NULL if not applicable. */
static SString *concat_fast(VM *vm, const SpValue *ops, unsigned n) {
    size_t total = 0;
    for (unsigned i = 0; i < n; i++) {
        if (ops[i].type == T_STRING) total += AS_STR(ops[i])->len;
        else if (ops[i].type == T_INT) total += int_len(ops[i].as.i);
        else return NULL;
    }
    if (total > vm->lim.max_string_bytes) vm_fatal(vm, RS_MEMORY, "string length limit exceeded");
    SString *r = vm_alloc_string(vm, total);
    char *d = r->data;
    for (unsigned i = 0; i < n; i++) {
        if (ops[i].type == T_STRING) {
            const SString *x = AS_STR(ops[i]);
            memcpy(d, x->data, x->len);
            d += x->len;
        } else {
            d += sp_fmt_int(d, ops[i].as.i);
        }
    }
    string_finish(r);
    return r;
}

/* for the JIT: the same fast path (strings and ints only; NULL otherwise) */
SString *vm_concat_fast(VM *vm, const SpValue *ops, unsigned n) { return concat_fast(vm, ops, n); }

/* The step budget is handed to run_loop in chunks so that an asynchronous
 * sp_interrupt() is noticed without any per-instruction flag test. */
enum { TICK_CHUNK = 1 << 20 };
static uint64_t tick_refill(VM *vm) {
    if (vm->interrupted) vm_fatal(vm, RS_INTERRUPT, "interrupted");
    if (vm->deadline_s > 0) {
        struct timespec ts;
        (void)timespec_get(&ts, TIME_UTC);
        if ((double)ts.tv_sec + (double)ts.tv_nsec / 1e9 > vm->deadline_s)
            vm_fatal(vm, RS_TIMEOUT, "runtime limit exceeded");
    }
    if (vm->ibank == 0) vm_fatal(vm, RS_TIMEOUT, "instruction limit exceeded");
    uint64_t chunk = vm->ibank < TICK_CHUNK ? vm->ibank : TICK_CHUNK;
    if (vm->ibank != UINT64_MAX) vm->ibank -= chunk;
    return chunk - 1;
}

/* Execution-path recorder for TraceJIT. It records one actually executed iteration after a backward edge is
 * observed, including bytecodes executed in callees, then passes supported traces to the verified SSA compiler.
 * Unsupported paths are discarded and continue through the interpreter/region JIT unchanged. Keep storage off
 * the normal path. */
/* The interpreter exists in two compiled variants (vm_loop.inc): the plain one pays nothing for TraceJIT path recording, and
 * the recording one logs every executed instruction. A loop recording starts and ends at a back edge, between two
 * instructions; there the running variant saves its state into the VM frame and returns RS_SW_RECORD / RS_SW_NORMAL, and this
 * wrapper continues the same frame in the other variant. */
/* the rarely used interpreter state that must survive a switch between the two variants */
typedef struct RunCold { int nargs, call_kind, defer_mode; SpValue call_uev, ev, defer_ev; } RunCold;

#define RUN_LOOP_NAME run_loop_plain
#define RUN_LOOP_RECORDING 0
#include "vm_loop.inc"
#undef RUN_LOOP_NAME
#undef RUN_LOOP_RECORDING
#define RUN_LOOP_NAME run_loop_rec
#define RUN_LOOP_RECORDING 1
#include "vm_loop.inc"
#undef RUN_LOOP_NAME
#undef RUN_LOOP_RECORDING

static RunStatus run_loop(VM *vm) {
    /* run_loop is re-entered for every vm_call (sort comparators, map/filter callbacks...), and getenv is a linear scan of
     * the environment: read the two switches once. The values are idempotent, so a racing first call is harmless. */
    static int env_state = -1; /* -1 unread, else bit0 = print recorded paths, bit1 = TraceJIT on */
    int es = env_state;
    if (es < 0) {
        const char *te = getenv("SPRINT_TRACE_RECORD"), *tj = getenv("SPRINT_TRACE_JIT");
        /* TraceJIT is on unless SPRINT_TRACE_JIT=0 */
        es = (te && te[0] && te[0] != '0' ? 1 : 0) | (tj && tj[0] == '0' ? 0 : 2);
        env_state = es;
    }
    const int trace_jit_enabled = vm->jit_on && (es & 2);
    const int trace_record_enabled = es & 1;
    VMTraceCapture *trace_cap = NULL; /* created lazily by the variants at the first loop back edge */
    RunCold cold;
    cold.nargs = 0; cold.call_kind = FK_NORMAL; cold.defer_mode = FK_NORMAL;
    cold.call_uev = v_nil(); cold.ev = v_nil(); cold.defer_ev = v_nil();
    RunStatus st;
    int recording = 0;
    for (;;) {
        st = recording ? run_loop_rec(vm, &trace_cap, &cold, trace_jit_enabled, trace_record_enabled)
                       : run_loop_plain(vm, &trace_cap, &cold, trace_jit_enabled, trace_record_enabled);
        if (st == RS_SW_RECORD) recording = 1;
        else if (st == RS_SW_NORMAL) recording = 0;
        else break;
    }
    if (trace_cap) vm_trace_capture_end(trace_cap);
    return st;
}


/* ---------------------------------------------------------------- */
/* program start                                                     */
/* ---------------------------------------------------------------- */
/* Call a Sprint value from a native (SPEC 20.5). The only C recursion in the
 * VM; bounded by max_native_reentry. Returns 1 with the error pending. */
int vm_call(VM *vm, SpValue fnv, int argc, const SpValue *argv, SpValue *ret) {
    if (fnv.type == T_CLASS) fnv = v_obj(T_FUNCTION, AS_CLASS(fnv)->ctor);
    if (check_callable(vm, &fnv, argc)) return 1;
    if (vm->native_depth >= vm->max_reentry) vm_fatal(vm, RS_MEMORY, "native re-entry limit exceeded");
    SpValue *fv = vm->sp;
    if (fv + argc + 8 > vm->stack_end) vm_fatal(vm, RS_MEMORY, "operand stack overflow");
    fv[0] = fnv;
    for (int i = 0; i < argc; i++) fv[1 + i] = argv[i];
    SFunc *f = AS_FUNC(fnv);
    if (f->nat) {
        vm->sp = fv + argc + 1;
        int r = f->nat->fn(vm, argc, fv + 1, ret);
        vm->sp = fv;
        if (r == 2) {
            vm->sw_kind = SW_NONE;
            return vm_set_error(vm, E_RUNTIME, "coroutines cannot be switched from a native callback");
        }
        return r;
    }
    Proto *p = f->proto;
    if (vm->nframes >= vm->max_frames) vm_fatal(vm, RS_MEMORY, "call depth limit exceeded (%d)", vm->max_frames);
    SpValue *nb = fv + 1;
    if (nb + p->nlocals + p->max_stack + 8 > vm->stack_end) vm_fatal(vm, RS_MEMORY, "operand stack limit exceeded");
    int filled = argc < p->nparams ? argc : p->nparams;
    for (int i = filled; i < p->nlocals; i++) nb[i] = v_nil();
    if (p->has_rest) {
        int extra = argc > p->nparams ? argc - p->nparams : 0;
        SArray *ra = vm_new_array(vm, extra);
        for (int i = 0; i < extra; i++) ra->items[i] = nb[p->nparams + i];
        ra->len = extra;
        nb[p->nparams] = v_obj(T_ARRAY, ra);
    }
    Frame *nf = &vm->frames[vm->nframes++];
    nf->fn = f;
    nf->base = nb;
    nf->kind = FK_BOUNDARY;
    nf->dbase = vm->ndr;
    nf->uev = v_nil();
    uint32_t entry = 0;
    if (p->ndefaults > 0) {
        int k = argc - p->nrequired;
        if (k > p->ndefaults) k = p->ndefaults;
        entry = p->default_pcs[k];
    }
    nf->pc = p->code + entry;
    vm->sp = nb + p->nlocals;
    vm->native_depth++;
    RunStatus st = run_loop(vm);
    vm->native_depth--;
    vm->sp = fv;
    if (st == RS_OK) {
        *ret = vm->bret;
        vm->bret = v_nil();
        return 0;
    }
    return 1;
}

static uint64_t prog_limit_left(const VM *vm) { return vm->lim.max_instructions ? vm->lim.max_instructions : UINT64_MAX; }

static void run_link_range(VM *vm, Program *prog, int from) {
    for (int i = from; i < prog->nlinks; i++) {
        const Link *l = &prog->links[i];
        if (l->kind == LINK_PRELUDE)
            vm->links[i] = lib_prelude_value(vm, lib_prelude_index(l->member, strlen(l->member)));
        else if (l->kind == LINK_MOD_VALUE)
            vm->links[i] = lib_module_value(vm, l->module);
        else {
            int found = 0;
            vm->links[i] = lib_module_export(vm, l->module, l->member, &found);
        }
    }
}

static RunStatus run_module(VM *vm, Program *prog, int mi) {
    Proto *entry = prog->protos[prog->mods[mi].entry_proto];
    SFunc *f = vm_new_closure_obj(vm, entry, 0);
    vm->stack[0] = v_obj(T_FUNCTION, f);
    SpValue *base = vm->stack + 1;
    for (int i = 0; i < entry->nlocals; i++) base[i] = v_nil();
    vm->sp = base + entry->nlocals;
    vm->nframes = 1;
    vm->frames[0].fn = f;
    vm->frames[0].base = base;
    vm->frames[0].pc = entry->code;
    vm->frames[0].kind = FK_NORMAL;
    vm->frames[0].dbase = 0;
    vm->frames[0].uev = v_nil();
    vm->ndr = 0;
    vm->ndv = 0;
    vm->nh = 0;
    return run_loop(vm);
}

RunStatus vm_run_program(VM *vm, Program *prog, int argc, char **argv) {
    unsigned trace_depth_base = vm_trace_capture_mark();
    vm->prog = prog;
    vm->prog_argc = argc;
    vm->prog_argv = argv;
    vm->slots = malloc(sizeof(SpValue) * (size_t)(prog->nslots ? prog->nslots : 1));
    vm->links = malloc(sizeof(SpValue) * (size_t)(prog->nlinks ? prog->nlinks : 1));
    if (!vm->slots || !vm->links) return RS_MEMORY;
    for (int i = 0; i < prog->nslots; i++) vm->slots[i] = v_uninit();
    for (int i = 0; i < prog->nlinks; i++) vm->links[i] = v_nil();

    if (!vm->no_quicken) prog_quicken(prog);
    vm->ibank = prog_limit_left(vm);
    vm->ileft = 0;
    vm->fatal_armed = 1;
    if (setjmp(vm->fatal_jb) == 0) {
        run_link_range(vm, prog, 0);
        vm->result = RS_OK;
        for (int mi = 0; mi < prog->nmods && vm->result == RS_OK; mi++) { const RunStatus mrs = run_module(vm, prog, mi); vm->result = (RunStatusInt)mrs; }
    } else {
        vm->result = vm->fatal_status;
    }
    vm->fatal_armed = 0;
    vm_trace_capture_restore(trace_depth_base); /* discard recorder frames skipped by a fatal longjmp */
    vm_out_flush(vm);
    return (RunStatus)vm->result;
}

/* REPL: the program grows between calls. Module slots and links are extended in place
 * (values already stored keep their indices) and only the new modules are run. */
RunStatus vm_run_chunk(VM *vm, Program *prog) {
    unsigned trace_depth_base = vm_trace_capture_mark();
    vm->prog = prog;
    if (prog->nslots > vm->slots_have || !vm->slots) {
        SpValue *ns = realloc(vm->slots, sizeof(SpValue) * (size_t)(prog->nslots ? prog->nslots : 1));
        if (!ns) return RS_MEMORY;
        vm->slots = ns;
        for (int i = vm->slots_have; i < prog->nslots; i++) vm->slots[i] = v_uninit();
        vm->slots_have = prog->nslots;
    }
    int old_links = vm->links_have;
    if (prog->nlinks > vm->links_have || !vm->links) {
        SpValue *nl = realloc(vm->links, sizeof(SpValue) * (size_t)(prog->nlinks ? prog->nlinks : 1));
        if (!nl) return RS_MEMORY;
        vm->links = nl;
        for (int i = vm->links_have; i < prog->nlinks; i++) vm->links[i] = v_nil();
        vm->links_have = prog->nlinks;
    }
    if (!vm->no_quicken)
        for (int i = vm->protos_quick; i < prog->nprotos; i++) vm_proto_quicken(prog->protos[i]);
    vm->protos_quick = prog->nprotos;
    vm->ibank = prog_limit_left(vm);
    vm->ileft = 0;
    vm->fatal_armed = 1;
    if (setjmp(vm->fatal_jb) == 0) {
        run_link_range(vm, prog, old_links);
        vm->result = RS_OK;
        while (vm->mods_run < prog->nmods && vm->result == RS_OK) {
            int mi = vm->mods_run++;
            { const RunStatus mrs = run_module(vm, prog, mi); vm->result = (RunStatusInt)mrs; }
        }
    } else {
        vm->result = vm->fatal_status;
    }
    vm->mods_run = prog->nmods;
    vm->fatal_armed = 0;
    vm_trace_capture_restore(trace_depth_base); /* discard recorder frames skipped by a fatal longjmp */
    vm_out_flush(vm);
    return (RunStatus)vm->result;
}

void vm_print_uncaught(VM *vm, int use_json) {
    if (vm->result == RS_PANIC) {
        (void)fprintf(stderr, "panic: %s\n", vm->fatal_msg);
        return;
    }
    if (vm->result == RS_MEMORY || vm->result == RS_TIMEOUT) {
        (void)fprintf(stderr, "%s: %s\n", vm->result == RS_MEMORY ? "MemoryError" : "TimeoutError", vm->fatal_msg);
        return;
    }
    if (vm->uncaught.type != T_ERROR) return;
    SError *e = AS_ERROR(vm->uncaught);
    if (use_json) {
        (void)fprintf(stderr,
                      "{\"severity\":\"error\",\"kind\":\"%s\",\"code\":%d,\"message\":\"%s\",\"file\":\"%s\",\"line\":%d,\"column\":%d}\n",
                      e->kind->data, e->code, e->message->data, e->file->data, e->line, e->col);
        return;
    }
    (void)fprintf(stderr, "error[%s]: %s\n  --> %s:%d:%d\ntrace (most recent call last):\n%s", e->kind->data,
                  e->message->data, e->file->data, e->line, e->col, e->trace->data);
}
