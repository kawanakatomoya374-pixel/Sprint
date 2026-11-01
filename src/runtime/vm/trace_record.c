/* Optional TraceJIT execution-path recorder. Allocations stay out of the VM hot path. */
#include "../vm_int.h"
#include "internal.h"
#include <stdlib.h>
#include <string.h>

static _Thread_local VMTraceCapture trace_pool[VM_TRACE_NEST_MAX];
static _Thread_local unsigned trace_depth;

VMTraceCapture *vm_trace_capture_begin(int print_records) {
    if (trace_depth >= VM_TRACE_NEST_MAX) return NULL;
    VMTraceCapture *t = &trace_pool[trace_depth++];
    /* only the scalar state: the step and seen arrays (several KB) are valid up to count/nseen and need no clearing.
     * run_loop is entered for every callback and nested call, so a full memset here was a per-call cost. */
    t->root = NULL;
    t->header = t->stack_depth = 0;
    t->count = t->nseen = 0;
    t->active = t->overflow = 0;
    t->is_side = t->parent_slot = 0;
    t->print_records = print_records != 0;
    return t;
}

void vm_trace_capture_end(VMTraceCapture *t) {
    if (t && trace_depth && t == &trace_pool[trace_depth - 1]) trace_depth--;
}

unsigned vm_trace_capture_mark(void) { return trace_depth; }

void vm_trace_capture_restore(unsigned mark) {
    if (mark <= VM_TRACE_NEST_MAX) trace_depth = mark;
}

int vm_trace_capture_edge(VMTraceCapture *t, const Proto *p, const uint8_t *code,
                          const uint8_t *hdr, const SpValue *base, const SpValue *sp) {
    size_t depth;
    if (!t || !p || !base || !sp || sp < base + p->nlocals) return 0;
    depth = (size_t)(sp - (base + p->nlocals));
    if (depth > UINT16_MAX) return 0;
    uint32_t h = (uint32_t)(hdr - code);
    if (!t->active) {
        if (proto_trace_blocked(p, h)) return 0;
        for (unsigned i = 0; i < t->nseen; i++)
            if (t->seen[i].proto == p && t->seen[i].header == h) return 0;
        if (t->nseen >= sizeof t->seen / sizeof t->seen[0]) return 0;
        t->root = p;
        t->header = h;
        t->stack_depth = (uint32_t)depth;
        t->count = 0;
        t->overflow = 0;
        t->active = 1;
        return 0;
    }
    if (t->root != p || t->header != h) return 0;
    if (t->stack_depth != (uint32_t)depth) {
        t->active = 0;
        t->overflow = 1;
        return 0;
    }

    t->seen[t->nseen++] = (VMTraceSeen){p, h};
    const char *name = p->name ? p->name : "?";
    if (t->print_records) {
        (void)fprintf(stderr, "trace-record: %s@%u steps=%u%s path=", name, h, t->count,
                      t->overflow ? "+ (truncated)" : "");
        unsigned n = t->count < VM_TRACE_PRINT_MAX ? t->count : VM_TRACE_PRINT_MAX;
        for (unsigned i = 0; i < n; i++) {
            const TraceStep *st = &t->steps[i];
            (void)fprintf(stderr, "%s%s@%u:%02x", i ? " " : "",
                          st->proto->name ? st->proto->name : "?", st->pc, st->op);
        }
        if (t->count > n) (void)fprintf(stderr, " ...(+%u)", t->count - n);
        (void)fputc('\n', stderr);
    }
    t->active = 0;
    return 1;
}


void vm_trace_capture_start_side(VMTraceCapture *t, const Proto *p,
                                 const uint8_t *code, const uint8_t *hdr,
                                 const SpValue *base, const SpValue *sp,
                                 uint8_t parent_slot) {
    if (t == NULL || p == NULL || code == NULL || hdr == NULL ||
        base == NULL || sp == NULL || sp < base + p->nlocals ||
        hdr < code || (size_t)(hdr - code) >= p->code_len ||
        t->nseen >= VM_TRACE_SEEN_MAX) return;
    size_t depth = (size_t)(sp - (base + p->nlocals));
    if (depth > UINT16_MAX) return;
    t->root = p;
    t->header = (uint32_t)(hdr - code);
    t->stack_depth = (uint32_t)depth;
    t->count = 0U;
    t->overflow = 0;
    t->active = 1;
    t->is_side = 1U;
    t->parent_slot = parent_slot;
}

void vm_trace_capture_clear_side(VMTraceCapture *t) {
    if (t == NULL) return;
    t->is_side = 0U;
    t->parent_slot = 0U;
}

void proto_trace_reject(Proto *p, uint32_t header) {
    const uint32_t need = (header >> 3) + 1U;
    if (need > p->trace_settled_bytes) {
        uint32_t cap = (p->code_len >> 3) + 1U;
        if (cap < need) cap = need;
        uint8_t *nb = realloc(p->trace_settled, cap);
        if (!nb) return; /* out of memory: the loop is simply recorded again later */
        memset(nb + p->trace_settled_bytes, 0, cap - p->trace_settled_bytes);
        p->trace_settled = nb;
        p->trace_settled_bytes = cap;
    }
    p->trace_settled[header >> 3] = (uint8_t)(p->trace_settled[header >> 3] | (1U << (header & 7U)));
}
