#define _POSIX_C_SOURCE 200809L
#include <time.h>
/* GC: precise, non-moving mark & sweep with no C recursion. */
#include "value_int.h"

static void mark_val(VM *vm, SpValue v);

/* ---------------------------------------------------------------- */
/* GC: precise, non-moving mark & sweep (no C recursion)            */
/* ---------------------------------------------------------------- */
/* Stack growth is deliberately outlined: it is a cold path and must not
 * inflate the per-object mark routine. */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline, cold))
#endif
static int gray_grow(VM *vm) {
    size_t next;
    if (vm->gc_gray_overflow) return 0;
    if (vm->gc_mark_limit != 0U && vm->capgray >= vm->gc_mark_limit) {
        vm->gc_gray_overflow = 1;
        return 0;
    }
    next = vm->capgray ? vm->capgray * 2U : 1024U;
    if (next < vm->capgray || next > SIZE_MAX / sizeof *vm->gray) {
        vm->gc_gray_overflow = 1;
        return 0;
    }
    if (vm->gc_mark_limit != 0U && next > vm->gc_mark_limit) next = vm->gc_mark_limit;
    if (next <= vm->ngray) {
        vm->gc_gray_overflow = 1;
        return 0;
    }
    Obj **grown = (Obj **)realloc(vm->gray, next * sizeof *grown);
    if (grown == NULL) {
        vm->gc_gray_overflow = 1;
        return 0;
    }
    vm->gray = grown;
    vm->capgray = next;
    return 1;
}

static void gray_push(VM *vm, Obj *o) {
    if (vm->ngray == vm->capgray && !gray_grow(vm)) return;
    vm->gray[vm->ngray++] = o;
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline))
#endif
static void mark_obj_new(VM *vm, Obj *o) {
    if (o->type == T_STRING) {
        SString *ss = (SString *)o;
        o->marked = vm->gc_black; /* strings have no outgoing references ... */
        if (ss->dp != ss->idata) {   /* ... except a string sharing a buffer, which keeps the hidden owner string alive */
            SString *own = (SString *)(void *)(ss->dp - offsetof(SString, idata));
            own->h.marked = vm->gc_black;
        }
        return;
    }
    o->marked = GC_GRAY; /* gray: queued, or discoverable by the fallback heap scan; the sweep makes the survivors black */
    gray_push(vm, o);
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
static inline void mark_obj(VM *vm, Obj *o) {
    if (o == NULL) return;
    /* unmarked = white (young, or any object at the start of a major collection) or the colour old objects had before the flip */
    const unsigned c = o->marked & 3U;
    if (c != 0U && c != 5U - vm->gc_black) return;
    mark_obj_new(vm, o);
}


static void mark_exec(VM *vm, const ExecState *st) {
    for (const SpValue *p = st->stack; p < st->sp; p++) mark_val(vm, *p);
    for (int i = 0; i < st->nframes; i++) {
        mark_obj(vm, (Obj *)st->frames[i].fn);
        mark_val(vm, st->frames[i].uev);
    }
    for (int i = 0; i < st->ndv; i++) mark_val(vm, st->dvals[i]);
    for (int i = 0; i < st->ndr; i++)
        if (st->drecs[i].method) mark_obj(vm, (Obj *)st->drecs[i].method);
}

static void mark_val(VM *vm, SpValue v) {
    if (v.type >= T_STRING && v.type <= T_CELL) mark_obj(vm, v.as.o);
}

void gc_mark(VM *vm, SpValue v) { mark_val(vm, v); }

static void blacken(VM *vm, Obj *o) {
    switch (o->type) {
    case T_ARRAY: {
        SArray *a = (SArray *)o;
        /* an array whose elements are all bools, ints or floats (the element-type note) holds no references: nothing to mark */
        if (!(a->h.xt >= (uint8_t)T_BOOL && a->h.xt <= (uint8_t)T_FLOAT))   /* numeric note: packed, or boxed numbers either way no references */
            for (int64_t i = 0; i < a->len; i++) mark_val(vm, array_get(a, i));
#ifndef NDEBUG_SP
        /* audit of the element-type note (Obj.xt): trace code relies on it, so a stale note is a memory-safety bug */
        if (a->h.xt != 0U)
            for (int64_t i = 0; i < a->len; i++)
                if (!array_packed(a) && array_boxed(a)[i].type != a->h.xt) {
                    (void)fprintf(stderr, "internal error: array element-type note %u but element %lld has type %u\n",
                                  (unsigned)a->h.xt, (long long)i, (unsigned)array_boxed(a)[i].type);
                    abort();
                }
#endif
        break;
    }
    case T_TABLE: {
        STable *t = (STable *)o;
        for (int64_t i = 0; i < t->nent; i++)
            if (t->ents[i].key.type != T_NIL) {
                mark_val(vm, t->ents[i].key);
                mark_val(vm, t->ents[i].val);
            }
        break;
    }
    case T_FUNCTION: {
        SFunc *f = (SFunc *)o;
        for (int i = 0; i < f->nup; i++) mark_obj(vm, (Obj *)f->up[i]);
        break;
    }
    case T_CELL: mark_val(vm, ((SCell *)o)->v); break;
    case T_ITERATOR: mark_val(vm, ((SIterator *)o)->held); break;
    case T_NATIVE: {
        SNativeObj *no = (SNativeObj *)o;
        if (no->cls->trace) no->cls->trace(vm, no);
        break;
    }
    case T_COROUTINE: {
        SCoroutine *co = (SCoroutine *)o;
        mark_obj(vm, (Obj *)co->fn);
        if (co->status == CO_SUSPENDED && co->block) mark_exec(vm, &co->st);
        break;
    }
    case T_CLASS: {
        SClass *c = (SClass *)o;
        mark_obj(vm, (Obj *)c->name);
        mark_obj(vm, (Obj *)c->parent);
        mark_obj(vm, (Obj *)c->fields);
        mark_obj(vm, (Obj *)c->methods);
        mark_obj(vm, (Obj *)c->ctor);
        break;
    }
    case T_INSTANCE: {
        SInstance *in = (SInstance *)o;
        mark_obj(vm, (Obj *)in->cls);
        for (int i = 0; i < in->nslots; i++) mark_val(vm, in->slots[i]);
        break;
    }
    case T_MODULE: {
        SModule *m = (SModule *)o;
        mark_obj(vm, (Obj *)m->name);
        mark_obj(vm, (Obj *)m->exports);
        break;
    }
    case T_ERROR: {
        SError *e = (SError *)o;
        mark_obj(vm, (Obj *)e->kind);
        mark_obj(vm, (Obj *)e->message);
        mark_obj(vm, (Obj *)e->file);
        mark_obj(vm, (Obj *)e->trace);
        mark_val(vm, e->cause);
        mark_val(vm, e->data);
        mark_val(vm, e->suppressed);
        break;
    }
    default: break;
    }
}

static size_t obj_size(Obj *o) {
    switch (o->type) {
    case T_STRING: return ((SString *)o)->dp != ((SString *)o)->idata ? offsetof(SString, idata) : offsetof(SString, idata) + ((SString *)o)->len + 1;
    case T_ARRAY: return sizeof(SArray) + (size_t)((SArray *)o)->h.icap * sizeof(SpValue) + (array_inline((SArray *)o) ? 0U : (size_t)((SArray *)o)->cap * array_esize((SArray *)o));
    case T_TABLE: {
        STable *t = (STable *)o;
        return sizeof(STable) + (size_t)t->cap * sizeof(TEntry) + (size_t)t->idxcap * sizeof(int32_t);
    }
    case T_FUNCTION: return sizeof(SFunc) + (size_t)((SFunc *)o)->nup * sizeof(SCell *);
    case T_CELL: return sizeof(SCell);
    case T_CLASS: return sizeof(SClass);
    case T_COROUTINE: return sizeof(SCoroutine) + ((SCoroutine *)o)->block_size;
    case T_INSTANCE: return offsetof(SInstance, slots) + (size_t)((SInstance *)o)->nslots * sizeof(SpValue);
    case T_MODULE: return sizeof(SModule);
    case T_ITERATOR: return sizeof(SIterator);
    case T_ERROR: return sizeof(SError);
    case T_NATIVE: return sizeof(SNativeObj) + ((SNativeObj *)o)->size;
    default: return sizeof(Obj);
    }
}

static void free_obj(VM *vm, Obj *o) {
    size_t sz = obj_size(o);
    switch (o->type) {
    case T_ARRAY: if (!array_inline((SArray *)o)) free(((SArray *)o)->data); break;
    case T_TABLE: free(((STable *)o)->ents); free(((STable *)o)->idx); break;
    case T_FUNCTION: free(((SFunc *)o)->up); break;
    case T_CLASS: free(((SClass *)o)->dflt); break;
    case T_COROUTINE: co_block_free(((SCoroutine *)o)->block, ((SCoroutine *)o)->block_size); break;
    case T_NATIVE: {
        SNativeObj *no = (SNativeObj *)o;
        if (no->cls->release) no->cls->release(no->data);
        free(no->data);
        break;
    }
    default: break;
    }
    obj_release_block(vm, o);
    vm->bytes -= sz;
}

/* ---- remembered set and heap verification ------------------------------------------------------------------------------ */
void gc_remember(VM *vm, Obj *o) {
    o->marked |= GC_REM;
    if (vm->rem_n == vm->rem_cap) {
        size_t nc = vm->rem_cap ? vm->rem_cap * 2U : 1024U;
        Obj **nb = (Obj **)realloc(vm->rem_buf, nc * sizeof *nb);
        if (nb == NULL) vm_fatal(vm, RS_MEMORY, "out of memory");
        vm->rem_buf = nb;
        vm->rem_cap = nc;
    }
    vm->rem_buf[vm->rem_n++] = o;
}

typedef void (*ChildFn)(VM *vm, Obj *parent, SpValue child, void *ctx);
static void exec_children(VM *vm, Obj *parent, const ExecState *st, ChildFn f, void *ctx) {
    for (const SpValue *p = st->stack; p < st->sp; p++) f(vm, parent, *p, ctx);
    for (int i = 0; i < st->nframes; i++) {
        f(vm, parent, v_obj(T_FUNCTION, st->frames[i].fn), ctx);
        f(vm, parent, st->frames[i].uev, ctx);
    }
    for (int i = 0; i < st->ndv; i++) f(vm, parent, st->dvals[i], ctx);
    for (int i = 0; i < st->ndr; i++)
        if (st->drecs[i].method) f(vm, parent, v_obj(T_FUNCTION, st->drecs[i].method), ctx);
}
/* every reference the object holds, as blacken sees them (used only by the verifier) */
static void each_child(VM *vm, Obj *o, ChildFn f, void *ctx) {
    switch (o->type) {
    case T_ARRAY: {
        SArray *a = (SArray *)o;
        if (!(a->h.xt >= (uint8_t)T_BOOL && a->h.xt <= (uint8_t)T_FLOAT))
            for (int64_t i = 0; i < a->len; i++) f(vm, o, array_get(a, i), ctx);
        break;
    }
    case T_TABLE: {
        STable *t = (STable *)o;
        for (int64_t i = 0; i < t->nent; i++)
            if (t->ents[i].key.type != T_NIL) { f(vm, o, t->ents[i].key, ctx); f(vm, o, t->ents[i].val, ctx); }
        break;
    }
    case T_FUNCTION: { SFunc *fn = (SFunc *)o; for (int i = 0; i < fn->nup; i++) f(vm, o, v_obj(T_CELL, fn->up[i]), ctx); break; }
    case T_CELL: f(vm, o, ((SCell *)o)->v, ctx); break;
    case T_ITERATOR: f(vm, o, ((SIterator *)o)->held, ctx); break;
    case T_COROUTINE: {
        SCoroutine *co = (SCoroutine *)o;
        f(vm, o, v_obj(T_FUNCTION, co->fn), ctx);
        if (co->status == CO_SUSPENDED && co->block) exec_children(vm, o, &co->st, f, ctx);
        break;
    }
    case T_CLASS: {
        SClass *c = (SClass *)o;
        f(vm, o, v_obj(T_STRING, c->name), ctx); f(vm, o, v_obj(T_CLASS, c->parent), ctx); f(vm, o, v_obj(T_TABLE, c->fields), ctx);
        f(vm, o, v_obj(T_TABLE, c->methods), ctx); f(vm, o, v_obj(T_FUNCTION, c->ctor), ctx);
        break;
    }
    case T_INSTANCE: {
        SInstance *in = (SInstance *)o;
        f(vm, o, v_obj(T_CLASS, in->cls), ctx);
        for (int i = 0; i < in->nslots; i++) f(vm, o, in->slots[i], ctx);
        break;
    }
    case T_MODULE: { SModule *m = (SModule *)o; f(vm, o, v_obj(T_STRING, m->name), ctx); f(vm, o, v_obj(T_TABLE, m->exports), ctx); break; }
    case T_ERROR: {
        SError *e = (SError *)o;
        f(vm, o, v_obj(T_STRING, e->kind), ctx); f(vm, o, v_obj(T_STRING, e->message), ctx); f(vm, o, v_obj(T_STRING, e->file), ctx);
        f(vm, o, v_obj(T_STRING, e->trace), ctx); f(vm, o, e->cause, ctx); f(vm, o, e->data, ctx); f(vm, o, e->suppressed, ctx);
        break;
    }
    default: break;   /* natives: their trace callbacks are not enumerable here */
    }
}
static void verify_edge(VM *vm, Obj *parent, SpValue child, void *ctx) {
    (void)vm; (void)ctx;
    if (child.type < T_STRING || child.type > T_CELL || child.as.o == NULL) return;
    if ((child.as.o->marked & 3U) == 0U && (parent->marked & GC_REM) == 0U) {
        (void)fprintf(stderr, "gc-verify: old %s holds a young %s and is not remembered (a missing write barrier)\n",
                      type_name(v_obj(parent->type, parent)), type_name(child));
        abort();
    }
}
/* before a minor collection: every old object that holds a young one must be in the remembered set */
static void gc_verify(VM *vm) {
    for (Obj *o = vm->gc_young_end; o != NULL; o = o->next)
        if ((o->marked & 3U) == vm->gc_black) each_child(vm, o, verify_edge, NULL);
}

/* ---- collection --------------------------------------------------------------------------------------------------------- */
static void gc_mark_roots(VM *vm) {
    {
        ExecState cur;
        exec_save(vm, &cur);
        mark_exec(vm, &cur);
        for (SCoroutine *c = vm->cur_co; c; c = c->resumer) {
            mark_exec(vm, &c->caller);
            mark_obj(vm, (Obj *)c);
        }
    }
    if (vm->prog) {
        for (int i = 0; i < vm->prog->nslots; i++) mark_val(vm, vm->slots[i]);
        for (int i = 0; i < vm->prog->nlinks; i++) mark_val(vm, vm->links[i]);
        for (int i = 0; i < vm->prog->nprotos; i++) {
            Proto *p = vm->prog->protos[i];
            for (int k = 0; k < p->nconsts; k++) mark_val(vm, p->consts[k]);
            jit_roots(p, mark_val, vm);
        }
    }
    for (int i = 0; i < vm->nroots; i++) mark_val(vm, vm->roots[i]);
    for (int i = 0; i < vm->nnroot; i++) mark_val(vm, vm->nroot_stack[i]);
    for (const HostRef *r = vm->hrefs; r; r = r->next) mark_val(vm, r->v);
    mark_val(vm, vm->pend_obj);
    mark_val(vm, vm->uncaught);
    for (int i = 0; i < 17; i++) mark_obj(vm, (Obj *)vm->type_names[i]);
    for (int i = 0; i < 4; i++) mark_obj(vm, (Obj *)vm->co_status_names[i]);
}

static void gc_drain(VM *vm) {
    for (;;) {
        while (vm->ngray != 0U) {
            Obj *o = vm->gray[--vm->ngray];
            /* The discovery bit prevents duplicate pushes; the normal fast
             * path needs no second per-object mark-state store. */
            blacken(vm, o);
        }
        if (!vm->gc_gray_overflow) break;
        /* The mark stack may be capped or realloc may fail. Every discovered
         * object is still gray. Re-scan the heap, blackening gray objects and
         * repeating until newly reached objects have also been visited. */
        vm->ngray = vm->capgray; /* make every attempted enqueue take the cold full-stack path */
        for (;;) {
            size_t found = 0U;
            for (Obj *o = vm->objs; o != NULL; o = o->next) {
                if ((o->marked & 3U) == GC_GRAY) {
                    o->marked = (uint8_t)((o->marked & ~3U) | vm->gc_black);   /* processed */
                    blacken(vm, o);
                    found++;
                }
            }
            if (found == 0U) break;
        }
        vm->ngray = 0U;
        vm->gc_gray_overflow = 0;
        break;
    }
}

/* free the dead objects of the list from *pp up to `stop` (exclusive); the survivors become (or stay) old. `major`: the unmarked
 * ones also include the objects still carrying the pre-flip colour. */
static void gc_sweep(VM *vm, Obj **pp, const Obj *stop) {
    const unsigned stale = 5U - vm->gc_black;
    size_t freed = 0U;                          /* bytes of the blocks released by the fast path below, taken off vm->bytes once */
    while (*pp != stop) {
        Obj *o = *pp;
        const unsigned c = o->marked & 3U;
        if (c != 0U && c != stale) {
            o->marked = vm->gc_black;           /* survivor: old from now on, not remembered */
            pp = &o->next;
            continue;
        }
        *pp = o->next;
        size_t hs = 0U;                          /* the common garbage has no external storage: its block goes straight back to its size class */
        switch (o->type) {
        case T_INSTANCE: hs = offsetof(SInstance, slots) + (size_t)((SInstance *)o)->nslots * sizeof(SpValue); break;
        case T_ARRAY: if (array_inline((SArray *)o)) hs = sizeof(SArray) + (size_t)((SArray *)o)->h.icap * sizeof(SpValue); break;
        case T_STRING: if (((SString *)o)->dp == ((SString *)o)->idata) hs = offsetof(SString, idata) + (size_t)((SString *)o)->len + 1U; break;
        case T_CELL: hs = sizeof(SCell); break;
        default: break;
        }
        if (hs != 0U) {
            freed += hs;
            if (hs <= SP_POOL_MAX) {
                size_t cl = (hs + 15) >> 4;
                *(void **)(void *)o = vm->pool_free[cl];
                vm->pool_free[cl] = o;
            } else {
                free(o);
            }
        } else {
            free_obj(vm, o);
        }
    }
    vm->bytes -= freed;
}

static double gc_now_ms(void) {
    struct timespec t;
    (void)clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

static void gc_collect(VM *vm, int major) {
    const int trace = vm->gc_trace;
    const double t0 = trace ? gc_now_ms() : 0.0;
    const size_t before = vm->bytes, nrem = vm->rem_n;
    vm->gc_runs++;
    vm->ngray = 0U;
    vm->gc_gray_overflow = 0;
    memset(vm->ic, 0, sizeof vm->ic);
    memset(vm->mc, 0, sizeof vm->mc);
    if (major) {
        vm->gc_majors++;
        for (size_t i = 0; i < vm->rem_n; i++) vm->rem_buf[i]->marked &= (uint8_t)~GC_REM;
        vm->rem_n = 0U;
        vm->gc_black = (uint8_t)(5U - vm->gc_black);    /* every old object is unmarked at once */
    } else {
        vm->gc_minors++;
        if (vm->gc_verify) gc_verify(vm);
    }
    gc_mark_roots(vm);
    if (!major) {                                       /* old objects that were stored into since the last collection */
        for (size_t i = 0; i < vm->rem_n; i++) {
            Obj *o = vm->rem_buf[i];
            o->marked &= (uint8_t)~GC_REM;
            blacken(vm, o);
        }
        vm->rem_n = 0U;
    }
    gc_drain(vm);
    intern_sweep(vm);   /* dead strings leave the intern table before their blocks are freed */
    gc_sweep(vm, &vm->objs, major ? NULL : vm->gc_young_end);
    vm->gc_young_end = vm->objs;                        /* everything that is left is old */

    const size_t live = vm->bytes;
    /* a minor collection that promoted most of what was allocated bought nothing (the heap is only growing): wait for the major threshold,
     * as a non-generational collector would */
    const size_t young_bytes = before > vm->gc_last_live ? before - vm->gc_last_live : 0U;
    const int growing = !major && young_bytes != 0U && live > vm->gc_last_live && (live - vm->gc_last_live) / 10U * 10U > young_bytes / 10U * 6U;
    vm->gc_last_live = live;
    if (major) {
        size_t m = live > SIZE_MAX / 2U ? SIZE_MAX : live * 2U;
        if (m < ((size_t)4U << 20U)) m = (size_t)4U << 20U;
        vm->gc_major_next = m;
    }
    /* The allocation window until the next collection: at least gc_nursery, and half the heap for a big one (a heap that only grows is
     * collected about as often as before, instead of once per 4MB; gc_window_pct percent of the live data), at most 64MB. vm_gc decides then whether it is a major collection. */
    size_t window = vm->gc_nursery;
    if (live / 100U * (size_t)vm->gc_window_pct > window) window = live / 100U * (size_t)vm->gc_window_pct;
    if (window > ((size_t)64U << 20U) && window > vm->gc_nursery) window = (size_t)64U << 20U;
    size_t next = live > SIZE_MAX - window ? SIZE_MAX : live + window;
    if (growing && vm->gc_major_next > next) next = vm->gc_major_next;
    {   /* never far past the heap size at which the next major collection is due (that bound is what keeps the peak near twice the live data) */
        size_t cap = vm->gc_major_next > live + vm->gc_nursery ? vm->gc_major_next : live + vm->gc_nursery;
        if (next > cap) next = cap;
    }
    if (vm->lim.max_heap_bytes != 0U && next > vm->lim.max_heap_bytes)
        next = vm->lim.max_heap_bytes;
    if (next <= live) next = live == SIZE_MAX ? SIZE_MAX : live + 1U;
    if (vm->gc_stress) next = live == SIZE_MAX ? SIZE_MAX : live + 1U;
    vm->gc_next = next;
    if (trace) {
        vm->gc_trace_ms += gc_now_ms() - t0;
        if (trace > 1)
            (void)fprintf(stderr, "gc: %s  %zu -> %zu bytes (remembered %zu)  %.3f ms  next at %zu\n", major ? "major" : "minor", before, live, nrem,
                          gc_now_ms() - t0, next);
    }
}

void vm_gc(VM *vm) {
    int major = !vm->gc_gen || vm->gc_force_major || vm->bytes >= vm->gc_major_next;
    /* stress mode collects at every allocation: mostly minor ones, a major one now and then so that both get exercised */
    if (vm->gc_stress && vm->gc_gen && !vm->gc_force_major) major = vm->bytes >= vm->gc_major_next || (vm->gc_runs & 15) == 15;
    vm->gc_force_major = 0;
    gc_collect(vm, major);
}

void vm_gc_full(VM *vm) {
    vm->gc_force_major = 1;
    vm_gc(vm);
}

void vm_free(VM *vm) {
    if (vm->gc_trace)
        (void)fprintf(stderr, "gc: %lu minor + %lu major collections, %.1f ms\n", vm->gc_minors, vm->gc_majors, vm->gc_trace_ms);
    lib_ext_free(vm);
    Obj *o = vm->objs;
    while (o) {
        Obj *n = o->next;
        switch (o->type) {
        case T_ARRAY: if (!array_inline((SArray *)o)) free(((SArray *)o)->data); break;
        case T_TABLE: free(((STable *)o)->ents); free(((STable *)o)->idx); break;
        case T_FUNCTION: free(((SFunc *)o)->up); break;
        case T_CLASS: free(((SClass *)o)->dflt); break;
        case T_COROUTINE: co_block_free(((SCoroutine *)o)->block, ((SCoroutine *)o)->block_size); break;
        case T_NATIVE: {
            SNativeObj *no = (SNativeObj *)o;
            if (no->cls->release) no->cls->release(no->data);
            free(no->data);
            break;
        }
        default: break;
        }
        obj_release_block(vm, o);
        o = n;
    }
    for (int i = 0; i < vm->npool_chunks; i++) free(vm->pool_chunks[i]);
    free(vm->pool_chunks);
    free(vm->main_exec.stack);
    free(vm->main_exec.frames);
    free(vm->main_exec.handlers);
    free(vm->main_exec.drecs);
    free(vm->main_exec.dvals);
    free(vm->outbuf);
    free(vm->roots);
    free(vm->nroot_stack);
    while (vm->hrefs) { HostRef *r = vm->hrefs; vm->hrefs = r->next; free(r); }
    for (int i = 0; i < vm->nhmods; i++) {
        free(vm->hmods[i]->name);
        free(vm->hmods[i]->fns);
        free(vm->hmods[i]->hd);
        free(vm->hmods[i]);
    }
    free(vm->hmods);
    free(vm->hdiag);
    free(vm->gray);
    free(vm->rem_buf);
    free(vm->itab);
    free(vm->slots);
    free(vm->links);
    free(vm);
}
