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
        o->marked = 2U; /* strings have no outgoing references ... */
        if (ss->dp != ss->idata) {   /* ... except a string sharing a buffer, which keeps the hidden owner string alive */
            SString *own = (SString *)(void *)(ss->dp - offsetof(SString, idata));
            own->h.marked = 2U;
        }
        return;
    }
    o->marked = 1U; /* gray: queued, or discoverable by the fallback heap scan */
    gray_push(vm, o);
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((always_inline))
#endif
static inline void mark_obj(VM *vm, Obj *o) {
    if (o == NULL || o->marked != 0U) return;
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
        if (!(a->h.xt >= (uint8_t)T_BOOL && a->h.xt <= (uint8_t)T_FLOAT))
            for (int64_t i = 0; i < a->len; i++) mark_val(vm, a->items[i]);
#ifndef NDEBUG_SP
        /* audit of the element-type note (Obj.xt): trace code relies on it, so a stale note is a memory-safety bug */
        if (a->h.xt != 0U)
            for (int64_t i = 0; i < a->len; i++)
                if (a->items[i].type != a->h.xt) {
                    (void)fprintf(stderr, "internal error: array element-type note %u but element %lld has type %u\n",
                                  (unsigned)a->h.xt, (long long)i, (unsigned)a->items[i].type);
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
    case T_ARRAY: return sizeof(SArray) + (size_t)((SArray *)o)->h.icap * sizeof(SpValue) + (array_inline((SArray *)o) ? 0U : (size_t)((SArray *)o)->cap * sizeof(SpValue));
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
    case T_ARRAY: if (!array_inline((SArray *)o)) free(((SArray *)o)->items); break;
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

void vm_gc(VM *vm) {
    vm->gc_runs++;
    vm->ngray = 0U;
    vm->gc_gray_overflow = 0;
    memset(vm->ic, 0, sizeof vm->ic);
    memset(vm->mc, 0, sizeof vm->mc);
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
                if (o->marked == 1U) {
                    o->marked = 2U;
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

    Obj **pp = &vm->objs;
    while (*pp) {
        Obj *o = *pp;
        if (o->marked) {
            o->marked = 0;
            pp = &o->next;
        } else {
            *pp = o->next;
            if (o->type == T_INSTANCE) {         /* the common garbage: no external storage, so the block goes straight back to its size class */
                size_t hs = offsetof(SInstance, slots) + (size_t)((SInstance *)o)->nslots * sizeof(SpValue);
                vm->bytes -= hs;
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
    }
    size_t live = vm->bytes;
    static int factor = -1;
    if (factor < 0) { const char *e = getenv("SPRINT_GC_FACTOR"); factor = e && e[0] >= '1' && e[0] <= '9' ? e[0] - '0' : 2; }
    size_t next = live > SIZE_MAX / (size_t)factor ? SIZE_MAX : live * (size_t)factor;
    if (next < ((size_t)1U << 20U)) next = (size_t)1U << 20U;
    if (vm->lim.max_heap_bytes != 0U && next > vm->lim.max_heap_bytes)
        next = vm->lim.max_heap_bytes;
    if (next < live) next = live;
    if (vm->gc_stress) next = live == SIZE_MAX ? SIZE_MAX : live + 1U;
    vm->gc_next = next;
}

void vm_free(VM *vm) {
    lib_ext_free(vm);
    Obj *o = vm->objs;
    while (o) {
        Obj *n = o->next;
        switch (o->type) {
        case T_ARRAY: if (!array_inline((SArray *)o)) free(((SArray *)o)->items); break;
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
    free(vm->slots);
    free(vm->links);
    free(vm);
}
