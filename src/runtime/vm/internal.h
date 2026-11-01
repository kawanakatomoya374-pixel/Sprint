/* Private interfaces shared by the interpreter and its cold-path modules. */
#ifndef SPRINT_VM_INTERNAL_H
#define SPRINT_VM_INTERNAL_H

#include "../../sp.h"

enum {
    VM_TRACE_RECORD_MAX = 256,
    VM_TRACE_PRINT_MAX = 128,
    VM_TRACE_NEST_MAX = 8,
    VM_TRACE_SEEN_MAX = 128
};

typedef struct {
    const Proto *proto;
    uint32_t header;
} VMTraceSeen;

typedef struct VMTraceCapture VMTraceCapture;
struct VMTraceCapture {
    const Proto *root;
    uint32_t header, stack_depth;
    unsigned count, nseen;
    int active, overflow, print_records;
    uint8_t is_side, parent_slot;
    VMTraceSeen seen[VM_TRACE_SEEN_MAX];
    TraceStep steps[VM_TRACE_RECORD_MAX];
};

VMTraceCapture *vm_trace_capture_begin(int print_records);
void vm_trace_capture_end(VMTraceCapture *capture);
unsigned vm_trace_capture_mark(void);
void vm_trace_capture_restore(unsigned mark);
int vm_trace_capture_edge(VMTraceCapture *capture, const Proto *proto,
                          const uint8_t *code, const uint8_t *header,
                          const SpValue *base, const SpValue *sp);
void vm_trace_capture_start_side(VMTraceCapture *capture, const Proto *proto,
                                 const uint8_t *code, const uint8_t *header,
                                 const SpValue *base, const SpValue *sp,
                                 uint8_t parent_slot);
void vm_trace_capture_clear_side(VMTraceCapture *capture);

void vm_proto_quicken(Proto *proto);
void vm_class_analyze(SClass *cls);

#endif
