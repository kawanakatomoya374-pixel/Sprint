/* The interpreter loop. Included twice by vm.c: RUN_LOOP_RECORDING 0 is the plain interpreter (no instruction-path
 * recording code at all), 1 records the executed path for the TraceJIT. run_loop() in vm.c switches between them. */
/* The dispatch loop holds no arrays or buffers (only scalars and one small struct), so the stack canary buys
 * nothing here and costs ~15% of interpreter speed; every other function keeps -fstack-protector-strong. */
#if defined(__GNUC__) && !defined(__clang__) && __GNUC__ >= 11
__attribute__((no_stack_protector))
#endif
static RunStatus RUN_LOOP_NAME(VM *vm, VMTraceCapture **capp, RunCold *ccold, int trace_jit_enabled, int trace_record_enabled) {
    VMTraceCapture *trace_cap = *capp; /* created at the first loop back edge, see JIT_HOOK */
    Frame *fr = &vm->frames[vm->nframes - 1];
    const uint8_t *pc = fr->pc;
    const uint8_t *ipc = pc;
    SpValue *sp = vm->sp;
    SpValue *base = fr->base;
    Proto *proto = fr->fn->proto;
    uint64_t left = vm->ileft; /* remaining step budget (UINT64_MAX = unlimited) */
    const int jit_enabled = vm->jit_on;
    /* Rarely used state lives in memory so the hot interpreter state (pc, sp,
     * base, left) can stay in registers. */
    RunCold cold = *ccold; /* continues the state of the other variant when run_loop() switched here */
    __asm__ volatile("" : : "r"(&cold) : "memory");
#define nargs cold.nargs
#define call_kind cold.call_kind
#define defer_mode cold.defer_mode
#define call_uev cold.call_uev
#define ev cold.ev
#define defer_ev cold.defer_ev

#define LOAD_FRAME() do { fr = &vm->frames[vm->nframes - 1]; pc = fr->pc; base = fr->base; proto = fr->fn->proto; } while (0)
#define U8() (*pc++)
#define U16() (pc += 2, rd16(pc - 2))
#define I32() (pc += 4, (int32_t)rd32(pc - 4))
#define PUSH(v) (*sp++ = (v))
#define SYNC() do { fr->pc = pc; vm->sp = sp; vm->ileft = left; } while (0)
#define RET(x) do { vm->ileft = left; return (x); } while (0)
#define GCP() do { if (vm->bytes >= vm->gc_next) { SYNC(); vm_gc(vm); } } while (0)
#define RAISE() goto raise
/* Step budget (SPEC 17.x): one tick per backward jump, call and defer run. */
#define TICK() do { if (left-- == 0) { SYNC(); left = tick_refill(vm); } } while (0)
/* Hot-loop JIT (src/runtime/jit.c): consulted at backward jumps once the proto is warm; HDR is the loop header. When
 * the loop runs compiled, control comes back here at the instruction where it left the region. */
#define JIT_HOOK(HDR, JR, RESUME) do { \
        /* The interpreter-only configuration should pay one strongly predicted \
         * not-taken branch at a backedge, not the recorder/cache bookkeeping. */ \
        if (__builtin_expect(jit_enabled, 0)) { \
            if (__builtin_expect(trace_cap == NULL, 0) && (trace_jit_enabled || trace_record_enabled)) { \
                trace_cap = *capp = vm_trace_capture_begin(trace_record_enabled); \
                if (!trace_cap && trace_record_enabled) \
                    (void)fprintf(stderr, "trace-record: nesting limit reached; recorder disabled\n"); \
            } \
            int trace_done_ = (trace_cap && (trace_cap->active || !proto_trace_blocked(proto, (uint32_t)((HDR) - proto->code)))) ? \
                vm_trace_capture_edge(trace_cap, proto, proto->code, (HDR), base, sp) : 0; \
            int trace_ran_ = 0; \
            if (trace_done_ && trace_jit_enabled && trace_cap && !trace_cap->overflow) { \
                (void)jit_trace_compile(vm, proto, (uint32_t)((HDR) - proto->code), trace_cap->steps, \
                                        trace_cap->count, trace_cap->stack_depth, \
                                        trace_cap->is_side != 0U, trace_cap->parent_slot); \
                /* compiled or rejected, the root recording of this loop is over: never record it again */ \
                if (!trace_cap->is_side) proto_trace_reject(proto, (uint32_t)((HDR) - proto->code)); \
                vm_trace_capture_clear_side(trace_cap); \
            } \
            if (trace_jit_enabled && proto->trace_any && !((trace_cap) && (trace_cap)->active)) { \
                vm->ileft = left; \
                uint8_t trace_parent_slot_ = 0U; \
                int trace_result_ = jit_trace_site(vm, proto, (HDR), base, sp, \
                                                   trace_cap ? &trace_parent_slot_ : NULL); \
                if (trace_result_ != 0) { \
                    left = vm->ileft; sp = vm->sp; LOAD_FRAME(); \
                    if (trace_result_ == 2 && trace_cap) \
                        vm_trace_capture_start_side(trace_cap, proto, proto->code, pc, base, sp, trace_parent_slot_); \
                    JR = pc; trace_ran_ = 1; \
                } \
            } \
            /* Record one full iteration before falling back to the region JIT. */ \
            if (!trace_ran_ && (!trace_cap || !trace_cap->active)) { \
                if (proto->jhot > 1) proto->jhot--; \
                else { \
                    vm->ileft = left; \
                    if (jit_site(vm, proto, (HDR), base, sp)) { left = vm->ileft; sp = vm->sp; LOAD_FRAME(); JR = pc; } \
                } \
            } \
            /* A loop recording just started (or ended): continue in the other interpreter variant. The cold state \
             * (in-flight deferred-call errors) travels with the frame, so the switch is possible between any two instructions. */ \
            if (RUN_LOOP_RECORDING ? (trace_cap && !trace_cap->active) : (trace_cap && trace_cap->active)) { \
                vm->sp = sp; vm->ileft = left; fr->pc = (JR) ? (JR) : (RESUME); \
                *ccold = cold; \
                return RUN_LOOP_RECORDING ? RS_SW_NORMAL : RS_SW_RECORD; \
            } \
        } \
    } while (0)

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
#pragma GCC diagnostic ignored "-Woverride-init"
    static const void *const dtab[256] = {
        [0 ... 255] = &&L_slow,
        [OP_NOP] = &&L_OP_NOP,
        [OP_CONST] = &&L_OP_CONST,
        [OP_NIL] = &&L_OP_NIL,
        [OP_TRUE] = &&L_OP_TRUE,
        [OP_FALSE] = &&L_OP_FALSE,
        [OP_SMALLINT] = &&L_OP_SMALLINT,
        [OP_POP] = &&L_OP_POP,
        [OP_DUP] = &&L_OP_DUP,
        [OP_DUP2] = &&L_OP_DUP2,
        [OP_LOAD_LOCAL] = &&L_OP_LOAD_LOCAL,
        [OP_STORE_LOCAL] = &&L_OP_STORE_LOCAL,
        [OP_LOAD_UPVAL] = &&L_OP_LOAD_UPVAL,
        [OP_STORE_UPVAL] = &&L_OP_STORE_UPVAL,
        [OP_LOAD_MODULE] = &&L_OP_LOAD_MODULE,
        [OP_STORE_MODULE] = &&L_OP_STORE_MODULE,
        [OP_LOAD_LINK] = &&L_OP_LOAD_LINK,
        [OP_ADD] = &&L_OP_ADD,
        [OP_SUB] = &&L_OP_SUB,
        [OP_MUL] = &&L_OP_MUL,
        [OP_DIV] = &&L_OP_DIV,
        [OP_FLOOR_DIV] = &&L_OP_DIV,
        [OP_MOD] = &&L_OP_DIV,
        [OP_POW] = &&L_OP_DIV,
        [OP_NOT] = &&L_OP_NOT,
        [OP_EQ] = &&L_OP_EQ,
        [OP_NE] = &&L_OP_NE,
        [OP_LT] = &&L_OP_LT,
        [OP_LE] = &&L_OP_LT,
        [OP_GT] = &&L_OP_LT,
        [OP_GE] = &&L_OP_LT,
        [OP_JUMP] = &&L_OP_JUMP,
        [OP_JUMP_IF_FALSE] = &&L_OP_JUMP_IF_FALSE,
        [OP_JUMP_IF_TRUE] = &&L_OP_JUMP_IF_TRUE,
        [OP_GET_INDEX] = &&L_OP_GET_INDEX,
        [OP_SET_INDEX] = &&L_OP_SET_INDEX,
        [OP_GET_MEMBER] = &&L_OP_GET_MEMBER,
        [OP_SET_MEMBER] = &&L_OP_SET_MEMBER,
        [OP_Q_LLI_ADD] = &&L_OP_Q_LLI_ADD,
        [OP_Q_LLI_SUB] = &&L_OP_Q_LLI_SUB,
        [OP_Q_LLI_MOD] = &&L_OP_Q_LLI_MOD,
        [OP_Q_LLI_LT] = &&L_OP_Q_LLI_LT,
        [OP_Q_LLI_LE] = &&L_OP_Q_LLI_LE,
        [OP_Q_LLI_GT] = &&L_OP_Q_LLI_GT,
        [OP_Q_LLI_GE] = &&L_OP_Q_LLI_GE,
        [OP_Q_LLI_EQ] = &&L_OP_Q_LLI_EQ,
        [OP_Q_LLI_NE] = &&L_OP_Q_LLI_NE,
        [OP_Q_ADD_L] = &&L_OP_Q_ADD_L,
        [OP_Q_SUB_L] = &&L_OP_Q_SUB_L,
        [OP_Q_MUL_L] = &&L_OP_Q_MUL_L,
        [OP_Q_DIV_L] = &&L_OP_Q_DIV_L,
        [OP_Q_MODEQ_JF] = &&L_OP_Q_MODEQ_JF,
        [OP_Q_MODNE_JF] = &&L_OP_Q_MODEQ_JF,
        [OP_Q_LLI_LT_JF] = &&L_OP_Q_LLI_LT_JF,
        [OP_Q_LLI_LE_JF] = &&L_OP_Q_LLI_LE_JF,
        [OP_Q_LLI_GT_JF] = &&L_OP_Q_LLI_GT_JF,
        [OP_Q_LLI_GE_JF] = &&L_OP_Q_LLI_GE_JF,
        [OP_Q_LLI_EQ_JF] = &&L_OP_Q_LLI_EQ_JF,
        [OP_Q_LLI_NE_JF] = &&L_OP_Q_LLI_NE_JF,
        [OP_Q_LLL_ADD] = &&L_OP_Q_LLL_ADD,
        [OP_Q_LLL_SUB] = &&L_OP_Q_LLL_SUB,
        [OP_Q_LLL_MUL] = &&L_OP_Q_LLL_MUL,
        [OP_Q_SI_LT_JF] = &&L_OP_Q_SI_LT_JF,
        [OP_Q_SI_LE_JF] = &&L_OP_Q_SI_LT_JF,
        [OP_Q_SI_GT_JF] = &&L_OP_Q_SI_LT_JF,
        [OP_Q_SI_GE_JF] = &&L_OP_Q_SI_LT_JF,
        [OP_Q_SI_EQ_JF] = &&L_OP_Q_SI_LT_JF,
        [OP_Q_SI_NE_JF] = &&L_OP_Q_SI_LT_JF,
        [OP_Q_LLI_FDIV] = &&L_OP_Q_LLI_FDIV,
        [OP_Q_IL_ADD] = &&L_OP_Q_IL_ADD,
        [OP_Q_IL_MUL] = &&L_OP_Q_IL_ADD,
        [OP_Q_LLL_DIV] = &&L_OP_Q_LLL_DIV,
        [OP_Q_LLL_LT] = &&L_OP_Q_LLL_LT,
        [OP_Q_LLL_LE] = &&L_OP_Q_LLL_LE,
        [OP_Q_LLL_GT] = &&L_OP_Q_LLL_GT,
        [OP_Q_LLL_GE] = &&L_OP_Q_LLL_GE,
        [OP_Q_LLL_EQ] = &&L_OP_Q_LLL_EQ,
        [OP_Q_LLL_NE] = &&L_OP_Q_LLL_NE,
        [OP_Q_LLL_LT_JF] = &&L_OP_Q_LLL_LT_JF,
        [OP_Q_LLL_LE_JF] = &&L_OP_Q_LLL_LE_JF,
        [OP_Q_LLL_GT_JF] = &&L_OP_Q_LLL_GT_JF,
        [OP_Q_LLL_GE_JF] = &&L_OP_Q_LLL_GE_JF,
        [OP_Q_LLL_EQ_JF] = &&L_OP_Q_LLL_EQ_JF,
        [OP_Q_LLL_NE_JF] = &&L_OP_Q_LLL_NE_JF,
        [OP_Q_RANGE_NEXT_ST] = &&L_OP_Q_RANGE_NEXT_ST,
        [OP_Q_ACC_I] = &&L_OP_Q_ACC_I_ADD,
        [OP_Q_ACC_IM] = &&L_OP_Q_ACC_IM_ADD,
        [OP_Q_ACC_I_MOD] = &&L_OP_Q_ACC_I_MOD,
        [OP_Q_ACC_I_MUL] = &&L_OP_Q_ACC_I_MUL,
        [OP_Q_ACC_I_SUB] = &&L_OP_Q_ACC_I_SUB,
        [OP_Q_ACC_IM_MOD] = &&L_OP_Q_ACC_IM_MOD,
        [OP_Q_ACC_IM_MUL] = &&L_OP_Q_ACC_IM_MUL,
        [OP_Q_ACC_IM_SUB] = &&L_OP_Q_ACC_IM_SUB,
        [OP_Q_ACC_L] = &&L_OP_Q_ACC_L,
        [OP_Q_ACC_LM] = &&L_OP_Q_ACC_L,
        [OP_Q_LLI_MUL] = &&L_OP_Q_LLI_MUL,
        [OP_Q_SI_ADD] = &&L_OP_Q_SI_ADD,
        [OP_Q_SI_SUB] = &&L_OP_Q_SI_ADD,
        [OP_Q_SI_MUL] = &&L_OP_Q_SI_ADD,
        [OP_Q_LLI_ADD_ST] = &&L_OP_Q_LLI_ADD_ST,
        [OP_Q_LLI_SUB_ST] = &&L_OP_Q_LLI_SUB_ST,
        [OP_Q_ADD_ST] = &&L_OP_Q_ADD_ST,
        [OP_Q_SUB_ST] = &&L_OP_Q_ADD_ST,
        [OP_Q_MUL_ST] = &&L_OP_Q_MUL_ST,
        [OP_Q_ADD_STM] = &&L_OP_Q_ADD_STM,
        [OP_Q_SUB_STM] = &&L_OP_Q_ADD_STM,
        [OP_Q_JUMP_RN] = &&L_OP_Q_JUMP_RN,
        [OP_Q_JUMP_LLL_LT] = &&L_OP_Q_JUMP_RN,
        [OP_Q_JUMP_LLI_LT] = &&L_OP_Q_JUMP_RN,
        [OP_Q_JUMP_JF] = &&L_OP_Q_JUMP_JF,
        [OP_Q_RET_LOCAL] = &&L_OP_Q_RET_LOCAL,
        [OP_Q_LOCAL_GETM] = &&L_OP_Q_LOCAL_GETM,
        [OP_Q_UP_INC] = &&L_OP_Q_UP_INC,
        [OP_Q_RET_UP] = &&L_OP_Q_RET_UP,
        [OP_Q_IDX_L] = &&L_OP_Q_IDX_L,
        [OP_Q_SETIDX_LLL] = &&L_OP_Q_SETIDX_LLL,
        [OP_Q_SETIDX_LLB] = &&L_OP_Q_SETIDX_LLL,
        [OP_Q_LL_IDX] = &&L_OP_Q_LL_IDX,
        [OP_Q_INVOKE_STR_FIRST ... OP_Q_INVOKE_STR_LAST] = &&call_general
    };
#pragma GCC diagnostic pop
#if RUN_LOOP_RECORDING
#define TRACE_STEP(IP) do { \
        if (__builtin_expect(trace_cap->active, 0)) { \
            if (trace_cap->count < VM_TRACE_RECORD_MAX) { \
                TraceStep *ts = &trace_cap->steps[trace_cap->count++]; \
                ts->proto = proto; \
                ts->pc = (uint32_t)((IP) - proto->code); \
                ts->op = *(IP); \
            } else { \
                /* the loop did not come round again within the step limit (it exited early, or its body is too long): \
                 * give the recording up, remember the loop as rejected and go back to the plain interpreter */ \
                trace_cap->active = 0; \
                trace_cap->overflow = 1; \
                if (!trace_cap->is_side) proto_trace_reject((Proto *)(uintptr_t)trace_cap->root, trace_cap->header); \
                fr->pc = (IP); vm->sp = sp; vm->ileft = left; \
                *ccold = cold; \
                return RS_SW_NORMAL; \
            } \
        } \
    } while (0)
#else
#define TRACE_STEP(IP) ((void)0)  /* the plain interpreter never records: see run_loop() */
#endif
#define NEXT() do { ipc = pc; TRACE_STEP(ipc); pc++; _Pragma("GCC diagnostic push") _Pragma("GCC diagnostic ignored \"-Wpedantic\"") goto *dtab[*ipc]; _Pragma("GCC diagnostic pop") } while (0)
    for (;;) {
        ipc = pc;
        TRACE_STEP(ipc);
        switch (*pc++) {
        case OP_NOP: L_OP_NOP: NEXT();
        case OP_CONST: L_OP_CONST: PUSH(proto->consts[U16()]); NEXT();
        case OP_NIL: L_OP_NIL: PUSH(v_nil()); NEXT();
        case OP_TRUE: L_OP_TRUE: PUSH(v_bool(1)); NEXT();
        case OP_FALSE: L_OP_FALSE: PUSH(v_bool(0)); NEXT();
        case OP_SMALLINT: L_OP_SMALLINT: q_smallint: { unsigned u = U16(); PUSH(v_int((int16_t)(uint16_t)u)); NEXT(); }
        case OP_POP: L_OP_POP: sp--; NEXT();
        case OP_DUP: L_OP_DUP: sp[0] = sp[-1]; sp++; NEXT();
        case OP_DUP2: L_OP_DUP2: sp[0] = sp[-2]; sp[1] = sp[-1]; sp += 2; NEXT();

        case OP_LOAD_LOCAL: L_OP_LOAD_LOCAL: q_load_local: PUSH(base[U16()]); NEXT();
        case OP_STORE_LOCAL: L_OP_STORE_LOCAL: base[U16()] = *--sp; NEXT();
        case OP_MAKE_CELL: {
            unsigned i = U16();
            GCP();
            SCell *cell = vm_new_cell(vm, base[i]);
            base[i] = v_obj(T_CELL, cell);
            break;
        }
        case OP_LOAD_CELL: {
            SpValue cv = base[U16()];
            if (cv.type != T_CELL) { (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: local is not a cell"); RAISE(); }
            PUSH(AS_CELL(cv)->v);
            break;
        }
        case OP_STORE_CELL: {
            SpValue cv = base[U16()];
            if (cv.type != T_CELL) { (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: local is not a cell"); RAISE(); }
            AS_CELL(cv)->v = *--sp;
            break;
        }
        case OP_LOAD_UPVAL: L_OP_LOAD_UPVAL: q_load_upval: PUSH(fr->fn->up[U16()]->v); NEXT();
        case OP_STORE_UPVAL: L_OP_STORE_UPVAL: fr->fn->up[U16()]->v = *--sp; NEXT();
        case OP_LOAD_MODULE: L_OP_LOAD_MODULE: q_load_module: {
            unsigned i = U16();
            if (vm->slots[i].type == T_UNINIT) {
                (void)vm_set_error(vm, E_NAME, "variable '%s' is used before its initialisation", vm->prog->slot_names[i]);
                RAISE();
            }
            PUSH(vm->slots[i]);
            NEXT();
        }
        case OP_STORE_MODULE: L_OP_STORE_MODULE: vm->slots[U16()] = *--sp; NEXT();
        case OP_LOAD_LINK: L_OP_LOAD_LINK: PUSH(vm->links[U16()]); NEXT();

        case OP_ADD: L_OP_ADD: q_add: {
            SpValue a = sp[-2], b = sp[-1];
            if (a.type == T_INT && b.type == T_INT) {
                int64_t r;
                if (!add_ovf(a.as.i, b.as.i, &r)) { sp--; sp[-1] = v_int(r); NEXT(); }
            } else if (a.type == T_FLOAT && b.type == T_FLOAT) {
                sp--; sp[-1] = v_float(a.as.f + b.as.f); NEXT();
            }
            SpValue r;
            if (arith(vm, OP_ADD, a, b, &r)) RAISE();
            sp--;
            sp[-1] = r;
            NEXT();
        }
        case OP_SUB: L_OP_SUB: q_sub: {
            SpValue a = sp[-2], b = sp[-1];
            if (a.type == T_INT && b.type == T_INT) {
                int64_t r;
                if (!sub_ovf(a.as.i, b.as.i, &r)) { sp--; sp[-1] = v_int(r); NEXT(); }
            } else if (a.type == T_FLOAT && b.type == T_FLOAT) {
                sp--; sp[-1] = v_float(a.as.f - b.as.f); NEXT();
            }
            SpValue r;
            if (arith(vm, OP_SUB, a, b, &r)) RAISE();
            sp--;
            sp[-1] = r;
            NEXT();
        }
        case OP_MUL: L_OP_MUL: q_mul: {
            SpValue a = sp[-2], b = sp[-1];
            if (a.type == T_INT && b.type == T_INT) {
                int64_t r;
                if (!mul_ovf(a.as.i, b.as.i, &r)) { sp--; sp[-1] = v_int(r); NEXT(); }
            } else if (a.type == T_FLOAT && b.type == T_FLOAT) {
                sp--; sp[-1] = v_float(a.as.f * b.as.f); NEXT();
            }
            SpValue r;
            if (arith(vm, OP_MUL, a, b, &r)) RAISE();
            sp--;
            sp[-1] = r;
            NEXT();
        }
        case OP_DIV: case OP_FLOOR_DIV: case OP_MOD: case OP_POW: L_OP_DIV: {
            int op = pc[-1];
            SpValue a = sp[-2], b = sp[-1];
            SpValue r;
            if (op == OP_DIV && a.type == T_FLOAT && b.type == T_FLOAT && !sp_feq(b.as.f, 0.0)) {
                sp--; sp[-1] = v_float(a.as.f / b.as.f); NEXT();
            }
            if (a.type == T_INT && b.type == T_INT && a.as.i >= 0 && b.as.i > 0 && op != OP_POW) {
                /* common non-negative case inline: floor division and modulo agree with C here */
                uint64_t ux = (uint64_t)a.as.i, uy = (uint64_t)b.as.i;
                if (op == OP_MOD) r = v_int((int64_t)(((ux | uy) >> 32) == 0 ? (uint64_t)((uint32_t)ux % (uint32_t)uy) : ux % uy));
                else if (op == OP_FLOOR_DIV) r = v_int((int64_t)(((ux | uy) >> 32) == 0 ? (uint64_t)((uint32_t)ux / (uint32_t)uy) : ux / uy));
                else r = v_float((double)a.as.i / (double)b.as.i);
                sp--;
                sp[-1] = r;
                NEXT();
            }
            if (arith(vm, op, a, b, &r)) RAISE();
            sp--;
            sp[-1] = r;
            NEXT();
        }
        case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR: {
            SpValue r;
            if (bitop(vm, pc[-1], sp[-2], sp[-1], &r)) RAISE();
            sp--;
            sp[-1] = r;
            break;
        }
        case OP_NEG: {
            SpValue a = sp[-1];
            if (a.type == T_INT) {
                if (a.as.i == INT64_MIN) { (void)vm_set_error(vm, E_ARITH, "integer overflow in unary -"); RAISE(); }
                sp[-1] = v_int(-a.as.i);
            } else if (a.type == T_FLOAT) sp[-1] = v_float(-a.as.f);
            else { (void)vm_set_error(vm, E_TYPE, "bad operand type for unary -: %s", type_name(a)); RAISE(); }
            break;
        }
        case OP_BNOT: {
            SpValue a = sp[-1];
            if (a.type != T_INT) { (void)vm_set_error(vm, E_TYPE, "bad operand type for unary ~: %s", type_name(a)); RAISE(); }
            sp[-1] = v_int(~a.as.i);
            break;
        }
        case OP_NOT: L_OP_NOT: sp[-1] = v_bool(!TRUTHY(sp[-1])); NEXT();

        case OP_CONCAT: {
            unsigned n = U8();
            GCP();
            {
                SString *fs = concat_fast(vm, sp - n, n);
                if (fs) { sp -= n; PUSH(v_obj(T_STRING, fs)); break; }
            }
            size_t total = 0;
            for (unsigned i = 0; i < n; i++) {
                Out m = {0};
                fmt_value(vm, sp[-(int)n + (int)i], 0, 0, &m);
                total += m.len;
            }
            if (total > vm->lim.max_string_bytes) vm_fatal(vm, RS_MEMORY, "string length limit exceeded");
            SString *s = vm_alloc_string(vm, total);
            Out w = {0};
            w.dst = s->data;
            w.cap = total;
            for (unsigned i = 0; i < n; i++) fmt_value(vm, sp[-(int)n + (int)i], 0, 0, &w);
            string_finish(s);
            sp -= n;
            PUSH(v_obj(T_STRING, s));
            break;
        }

        case OP_EQ: L_OP_EQ: {
            SpValue a = sp[-2], b = sp[-1];
            sp--;
            sp[-1] = v_bool(a.type == T_INT && b.type == T_INT ? a.as.i == b.as.i : value_eq(a, b));
            NEXT();
        }
        case OP_NE: L_OP_NE: {
            SpValue a = sp[-2], b = sp[-1];
            sp--;
            sp[-1] = v_bool(a.type == T_INT && b.type == T_INT ? a.as.i != b.as.i : !value_eq(a, b));
            NEXT();
        }
        case OP_LT: case OP_LE: case OP_GT: case OP_GE: L_OP_LT: {
            int op = pc[-1];
            int un;
            SpValue a = sp[-2], b = sp[-1];
            int c;
            if (a.type == T_INT && b.type == T_INT) { c = a.as.i < b.as.i ? -1 : a.as.i > b.as.i; un = 0; }
            else {
                c = compare(vm, a, b, &un);
                if (c == 2) RAISE();
            }
            int r = 0;
            if (!un) r = op == OP_LT ? c < 0 : op == OP_LE ? c <= 0 : op == OP_GT ? c > 0 : c >= 0;
            sp--;
            sp[-1] = v_bool(r);
            NEXT();
        }

        case OP_JUMP: L_OP_JUMP: { int32_t off = I32(); pc += off; if (off < 0) { const uint8_t *jr_ = NULL; TICK(); JIT_HOOK(pc, jr_, pc); (void)jr_; } NEXT(); }
        case OP_JUMP_IF_FALSE: L_OP_JUMP_IF_FALSE: { int32_t off = I32(); SpValue cv = *--sp; if (!TRUTHY(cv)) { pc += off; if (off < 0) TICK(); } NEXT(); }
        case OP_JUMP_IF_TRUE: L_OP_JUMP_IF_TRUE: { int32_t off = I32(); SpValue cv = *--sp; if (TRUTHY(cv)) { pc += off; if (off < 0) TICK(); } NEXT(); }
        case OP_JUMP_IF_FALSE_OR_POP: { int32_t off = I32(); if (!TRUTHY(sp[-1])) { pc += off; if (off < 0) TICK(); } else sp--; break; }
        case OP_JUMP_IF_TRUE_OR_POP: { int32_t off = I32(); if (TRUTHY(sp[-1])) { pc += off; if (off < 0) TICK(); } else sp--; break; }

        case OP_GET_INDEX: L_OP_GET_INDEX: {
            SpValue r;
            if (sp[-2].type == T_ARRAY && sp[-1].type == T_INT) {
                const SArray *ga = AS_ARRAY(sp[-2]);
                int64_t gi = sp[-1].as.i;
                if (gi >= 0 && gi < ga->len) { sp--; sp[-1] = ga->items[gi]; NEXT(); }
            } else if (sp[-2].type == T_NATIVE && typed_peek(sp[-2], sp[-1], &r)) {
                sp--;
                sp[-1] = r;
                NEXT();
            }
            if (get_index(vm, sp[-2], sp[-1], &r)) RAISE();
            sp--;
            sp[-1] = r;
            NEXT();
        }
        case OP_SET_INDEX: L_OP_SET_INDEX: {
            if (sp[-3].type == T_ARRAY && sp[-2].type == T_INT) {
                SArray *sa = AS_ARRAY(sp[-3]);
                int64_t si = sp[-2].as.i;
                if (si >= 0 && si < sa->len) { array_note_store(sa, sp[-1]); sa->items[si] = sp[-1]; sp -= 3; NEXT(); }
            } else if (sp[-3].type == T_NATIVE && typed_poke(sp[-3], sp[-2], sp[-1])) {
                sp -= 3;
                NEXT();
            }
            GCP();
            if (set_index(vm, sp[-3], sp[-2], sp[-1])) RAISE();
            sp -= 3;
            NEXT();
        }
        case OP_GET_MEMBER: L_OP_GET_MEMBER: {
            SString *name = AS_STR(proto->consts[U16()]);
            SpValue r;
            if (sp[-1].type == T_INSTANCE) {
                const SInstance *gi = AS_INSTANCE(sp[-1]);
                const ICEnt *ce = ic_find(vm, gi->cls, name);
                if (ce) { sp[-1] = ce->kind == 1 ? gi->slots[ce->slot] : ce->fn; NEXT(); }
            }
            if (get_member(vm, sp[-1], name, &r)) RAISE();
            sp[-1] = r;
            NEXT();
        }
        case OP_SET_MEMBER: L_OP_SET_MEMBER: {
            SString *name = AS_STR(proto->consts[U16()]);
            if (sp[-2].type == T_INSTANCE) {
                SInstance *si = AS_INSTANCE(sp[-2]);
                const ICEnt *ce = ic_find(vm, si->cls, name);
                if (ce && ce->kind == 1) { si->slots[ce->slot] = sp[-1]; sp -= 2; NEXT(); }
            }
            GCP();
            if (set_member(vm, sp[-2], name, sp[-1])) RAISE();
            sp -= 2;
            NEXT();
        }
        case OP_NEW_ARRAY: {
            unsigned n = U16();
            GCP();
            SArray *a = vm_new_array(vm, (int64_t)n);
            for (unsigned i = 0; i < n; i++) a->items[i] = sp[-(int)n + (int)i];
            a->len = (int64_t)n;
            sp -= n;
            PUSH(v_obj(T_ARRAY, a));
            break;
        }
        case OP_NEW_TABLE: {
            unsigned n = U16();
            GCP();
            STable *t = vm_new_table(vm, (int64_t)n);
            for (unsigned i = 0; i < n; i++) {
                SpValue *kv = sp - 2 * (int)n + 2 * (int)i;
                if (table_set(vm, t, kv[0], kv[1])) RAISE();
            }
            sp -= 2 * n;
            PUSH(v_obj(T_TABLE, t));
            break;
        }
        case OP_CLOSURE: {
            uint32_t idx = (uint32_t)I32();
            GCP();
            Proto *p = vm->prog->protos[idx];
            SFunc *f = vm_new_closure_obj(vm, p, p->nupvals);
            for (int i = 0; i < p->nupvals; i++) {
                if (p->upvals[i].from_local) {
                    if (base[p->upvals[i].index].type != T_CELL) {
                        (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: captured local is not a cell");
                        RAISE();
                    }
                    f->up[i] = AS_CELL(base[p->upvals[i].index]);
                } else {
                    if (p->upvals[i].index >= fr->fn->nup) {
                        (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: bad upvalue reference");
                        RAISE();
                    }
                    f->up[i] = fr->fn->up[p->upvals[i].index];
                }
            }
            PUSH(v_obj(T_FUNCTION, f));
            break;
        }

        case OP_CALL: {
            /* fast path: Sprint function, exact arity, no defaults/rest */
            SpValue *cfv = sp - (int)pc[0] - 1;
            if (cfv->type == T_FUNCTION) {
                SFunc *cf = AS_FUNC(*cfv);
                Proto *cp = cf->proto;
                int cn = (int)pc[0];
                if (cp && cn == cp->nparams && !cp->has_rest && cp->ndefaults == 0 && vm->nframes < vm->max_frames &&
                    cfv + 1 + cp->nlocals + cp->max_stack + 8 <= vm->stack_end && cn == cp->nrequired) {
                    TICK();
                    pc++;
#if SP_JIT
                    if (__builtin_expect(cp->pure != NULL, 0)) {   /* a pure recursive integer function: native, no frames */
                        int64_t pure_r;
                        uint64_t pure_left = left;
                        if (jit_pure_enter(vm, cp, cfv + 1, &pure_left, &pure_r)) {
                            left = pure_left;
                            sp = cfv;
                            PUSH(v_int(pure_r));
                            break;
                        }
                    }
#endif
                    SpValue *nb = cfv + 1;
                    for (int i = cn; i < cp->nlocals; i++) nb[i] = v_nil();
                    fr->pc = pc;
                    Frame *nf = fr + 1;
                    vm->nframes++;
                    nf->fn = cf;
                    nf->base = nb;
                    nf->kind = FK_NORMAL;
                    nf->uev = v_nil();
                    nf->dbase = vm->ndr;
                    nf->pc = cp->code;
#if SP_JIT
                    {   /* a hot function runs as compiled code, which comes back here when it returns or leaves */
                        JitUnit *ju = cp->junit;
                        if (!ju) {
                            if (cp->jcall > 1) cp->jcall--;
                            else ju = jit_call_hot(vm, cf, nb);
                        }
                        if (ju) {
                            vm->ileft = left;
                            jit_run(vm, ju, nb);
                            left = vm->ileft;
                            sp = vm->sp;
                            LOAD_FRAME();
                            break;
                        }
                    }
#endif
                    fr = nf;
                    pc = cp->code;
                    base = nb;
                    proto = cp;
                    sp = nb + cp->nlocals;
                    break;
                }
            }
            goto call_general;
        }
        case OP_Q_INVOKE_STR_SLICE: case OP_Q_INVOKE_STR_FIND: case OP_Q_INVOKE_STR_CONTAINS:
        case OP_Q_INVOKE_STR_STARTS_WITH: case OP_Q_INVOKE_STR_ENDS_WITH: case OP_Q_INVOKE_STR_COUNT:
        case OP_Q_INVOKE_STR_SPLIT: case OP_Q_INVOKE_STR_SPLIT_LINES: case OP_Q_INVOKE_STR_TRIM:
        case OP_Q_INVOKE_STR_TRIM_START: case OP_Q_INVOKE_STR_TRIM_END: case OP_Q_INVOKE_STR_UPPER:
        case OP_Q_INVOKE_STR_LOWER: case OP_Q_INVOKE_STR_REPLACE: case OP_Q_INVOKE_STR_REPEAT:
        case OP_Q_INVOKE_STR_CHAR_COUNT: case OP_Q_INVOKE_STR_CHAR_AT: case OP_Q_INVOKE_STR_IS_BOUNDARY:
        case OP_Q_INVOKE_STR_CODEPOINTS:
        case OP_CALL_SPREAD: case OP_INVOKE_SPREAD:
        case OP_INVOKE: call_general: {
            int op = pc[-1];
            SString *mname = NULL;
            int qstr_id = op >= OP_Q_INVOKE_STR_FIRST && op <= OP_Q_INVOKE_STR_LAST ? op - OP_Q_INVOKE_STR_FIRST : -1;
            if (op == OP_INVOKE || op == OP_INVOKE_SPREAD || qstr_id >= 0) mname = AS_STR(proto->consts[U16()]);
            nargs = (int)U8();
            if (op == OP_CALL_SPREAD || op == OP_INVOKE_SPREAD) {
                SpValue arr = sp[-1];
                if (arr.type != T_ARRAY) {
                    (void)vm_set_error(vm, E_TYPE, "spread argument must be an array, not %s", type_name(arr));
                    RAISE();
                }
                SArray *a = AS_ARRAY(arr);
                sp--;
                if (nargs + a->len > 255) { (void)vm_set_error(vm, E_TYPE, "too many arguments (limit 255)"); RAISE(); }
                if (sp + a->len + 8 > vm->stack_end) vm_fatal(vm, RS_MEMORY, "operand stack overflow");
                for (int64_t i = 0; i < a->len; i++) PUSH(a->items[i]);
                nargs += (int)a->len;
            }
            if (mname) {
                SpValue *ov = sp - nargs - 1;
                SpValue recv = *ov;
                if (qstr_id >= 0 && recv.type == T_STRING) {
                    SpValue ret = v_nil();
                    GCP();
                    SYNC();
                    int nerr = lib_invoke_string_method_id(vm, recv, (unsigned)qstr_id, nargs + 1, ov, &ret);
                    left = vm->ileft;
                    if (nerr) RAISE();
                    sp = ov;
                    PUSH(ret);
                    break;
                }
                if (recv.type == T_ARRAY && nargs == 1 && str_hash(mname) == vm->h_append && mname->len == 6 &&
                    memcmp(mname->data, "append", 6) == 0 && AS_ARRAY(recv)->len < AS_ARRAY(recv)->cap) {
                    /* array.append without growth: no allocation, no GC point */
                    SArray *aa = AS_ARRAY(recv);
                    array_note_push(aa, ov[1]);
                    aa->items[aa->len++] = ov[1];
                    sp = ov;
                    PUSH(v_nil());
                    break;
                }
                if (recv.type == T_ARRAY || recv.type == T_STRING || recv.type == T_NATIVE) {
                    SpValue ret = v_nil();
                    int found = 0;
                    GCP();
                    SYNC();
                    int nerr = lib_invoke_builtin_method_s(vm, recv, mname, nargs + 1, ov, &ret, &found);
                    left = vm->ileft;
                    if (nerr) RAISE();
                    if (!found) {
                        (void)vm_set_error(vm, E_NAME, "'%s' has no method '%s'", type_name(recv), mname->data);
                        RAISE();
                    }
                    sp = ov;
                    PUSH(ret);
                    break;
                }
                SpValue fv;
                if (recv.type == T_TABLE || recv.type == T_MODULE) {
                    if (get_member(vm, recv, mname, &fv)) RAISE();
                    *ov = fv;
                } else if (recv.type == T_INSTANCE) {
                    SInstance *in = AS_INSTANCE(recv);
                    const ICEnt *ce = ic_find(vm, in->cls, mname);
                    if (ce && ce->kind == 1) {
                        *ov = in->slots[ce->slot];
                    } else if (ce) {
                        fv = ce->fn;
                        if (sp + 8 > vm->stack_end) { SYNC(); vm_fatal(vm, RS_MEMORY, "operand stack overflow"); }
                        for (int mi = nargs; mi >= 0; mi--) ov[mi + 1] = ov[mi];
                        ov[0] = fv;
                        sp++;
                        nargs++;
                    } else {
                        (void)vm_set_error(vm, E_NAME, "'%s' instance has no field or method '%s'", in->cls->name->data, mname->data);
                        RAISE();
                    }
                } else if (recv.type == T_CLASS) {
                    if (get_member(vm, recv, mname, &fv)) RAISE();
                    *ov = fv;
                } else {
                    (void)vm_set_error(vm, E_TYPE, "'%s' object has no method '%s'", type_name(recv), mname->data);
                    RAISE();
                }
            }
            goto do_call;
        }

        case OP_RETURN:
        case OP_RETURN_NIL: {
            SpValue r = pc[-1] == OP_RETURN ? sp[-1] : v_nil();
            int idx = vm->nframes - 1;
            if (fr->kind == FK_NORMAL && idx > 0 && (vm->nh == 0 || vm->handlers[vm->nh - 1].frame < idx)) {
                /* fast path: plain return into the calling frame */
                sp = fr->base - 1;
                *sp++ = r;
                vm->nframes = idx;
                fr--;
                pc = fr->pc;
                base = fr->base;
                proto = fr->fn->proto;
                break;
            }
            int fkind = fr->kind;
            SpValue fuev = fr->uev;
            while (vm->nh > 0 && vm->handlers[vm->nh - 1].frame >= idx) vm->nh--;
            sp = fr->base - 1;
            vm->nframes--;
            if (fkind == FK_BOUNDARY) { /* sp_call / vm_call frame (also the only frame for a host call) */
                vm->bret = r;
                vm->sp = sp;
                RET(RS_OK);
            }
            if (vm->nframes == 0) {
                if (vm->cur_co) {
                    SCoroutine *co = vm->cur_co;
                    co->status = CO_DEAD;
                    const uint8_t *fexit = co->for_exit;
                    int wasfor = co->resume_for;
                    co->resume_for = 0;
                    exec_load(vm, &co->caller);
                    vm->cur_co = co->resumer;
                    if (vm->cur_co) vm->cur_co->status = CO_RUNNING;
                    vm_co_release(vm, co);
                    sp = vm->sp;
                    LOAD_FRAME();
                    if (wasfor) pc = fexit;
                    else PUSH(r);
                    continue;
                }
                vm->sp = sp;
                RET(RS_OK);
            }
            if (fkind == FK_NORMAL) PUSH(r);
            else if (fkind == FK_CTOR) PUSH(fuev);
            LOAD_FRAME();
            if (fkind == FK_DEFER_UNWIND) {
                ev = fuev;
                goto unwind;
            }
            break;
        }

        case OP_FOR_PREP: {
            unsigned s = U16();
            SpValue it = *--sp;
            if (it.type != T_ARRAY && !typed_is(it) && it.type != T_TABLE && it.type != T_COROUTINE && it.type != T_ITERATOR) {
                (void)vm_set_error(vm, E_TYPE, "'%s' object is not iterable", type_name(it));
                RAISE();
            }
            base[s] = it;
            base[s + 1] = v_int(0);
            base[s + 2] = v_int(it.type == T_TABLE ? (int64_t)AS_TABLE(it)->version : 0);
            break;
        }
        case OP_FOR_NEXT: {
            unsigned s = U16();
            unsigned n = U8();
            int32_t off = I32();
            SpValue it = base[s];
            if (it.type == T_ARRAY) {
                SArray *a = AS_ARRAY(it);
                int64_t cur = base[s + 1].as.i;
                if (base[s + 1].type != T_INT || cur < 0) { (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: bad loop state"); RAISE(); }
                if (cur >= a->len) { pc += off; break; }
                base[s + 1] = v_int(cur + 1);
                if (n == 2) PUSH(v_int(cur));
                PUSH(a->items[cur]);
            } else if (it.type == T_NATIVE) {   /* a typed array (OP_FOR_PREP admits no other native) */
                int64_t cur = base[s + 1].as.i;
                if (base[s + 1].type != T_INT || cur < 0) { (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: bad loop state"); RAISE(); }
                if (cur >= typed_len(it)) { pc += off; break; }
                SpValue tv;
                (void)typed_peek(it, v_int(cur), &tv);
                base[s + 1] = v_int(cur + 1);
                if (n == 2) PUSH(v_int(cur));
                PUSH(tv);
            } else if (it.type == T_ITERATOR) {
                SIterator *iter = AS_ITER(it);
                if ((int)n != iter->cls->arity) {
                    SYNC();
                    (void)vm_set_error(vm, E_TYPE, "iterator '%s' yields %d value(s) per step, but the loop has %u variable(s)",
                                       iter->cls->kind, iter->cls->arity, n);
                    RAISE();
                }
                if (iter->done) { pc += off; break; }
                SpValue out[2] = {v_nil(), v_nil()};
                SYNC();
                int r = iter->cls->next(vm, iter, out);
                if (r == 1) { iter->done = 1; pc += off; break; }
                if (r == 2) { iter->done = 1; RAISE(); }
                PUSH(out[0]);
                if (n == 2) PUSH(out[1]);
            } else if (it.type == T_COROUTINE) {
                SCoroutine *co = AS_CO(it);
                if (n == 2) {
                    SYNC();
                    (void)vm_set_error(vm, E_TYPE, "a coroutine yields one value; use a single loop variable");
                    RAISE();
                }
                if (co->status == CO_DEAD) { pc += off; break; }
                if (co->status != CO_SUSPENDED) {
                    SYNC();
                    (void)vm_set_error(vm, E_RUNTIME, "cannot resume a coroutine that is not suspended");
                    RAISE();
                }
                co->resume_for = 1;
                co->for_exit = pc + off;
                vm->sw_co = co;
                vm->sw_kind = SW_RESUME;
                goto do_resume;
            } else {
                if (it.type != T_TABLE || base[s + 1].type != T_INT || base[s + 1].as.i < 0) {
                    (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: bad loop state");
                    RAISE();
                }
                STable *t = AS_TABLE(it);
                if ((int64_t)t->version != base[s + 2].as.i) {
                    (void)vm_set_error(vm, E_RUNTIME, "table was modified during iteration");
                    RAISE();
                }
                SpValue k, v;
                int64_t nx = table_next(t, base[s + 1].as.i, &k, &v);
                if (nx < 0) { pc += off; break; }
                base[s + 1] = v_int(nx);
                PUSH(k);
                if (n == 2) PUSH(v);
            }
            break;
        }
        case OP_RANGE_PREP: {
            unsigned s = U16();
            SpValue a = sp[-3], b = sp[-2], c = sp[-1];
            if (a.type != T_INT || b.type != T_INT || c.type != T_INT) {
                (void)vm_set_error(vm, E_TYPE, "range() arguments must be int");
                RAISE();
            }
            if (c.as.i == 0) { (void)vm_set_error(vm, E_VALUE, "range() step must not be zero"); RAISE(); }
            base[s] = a;
            base[s + 1] = b;
            base[s + 2] = c;
            sp -= 3;
            break;
        }
        case OP_RANGE_NEXT: q_range_next: {
            unsigned s = U16();
            int32_t off = I32();
            if (base[s].type != T_INT || base[s + 1].type != T_INT || base[s + 2].type != T_INT || base[s + 2].as.i == 0) {
                (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: bad range state");
                RAISE();
            }
            int64_t cur = base[s].as.i, stop = base[s + 1].as.i, step = base[s + 2].as.i;
            if (step > 0 ? cur >= stop : cur <= stop) { pc += off; break; }
            PUSH(v_int(cur));
            int64_t nx;
            if (add_ovf(cur, step, &nx)) nx = stop; /* past the end of the int range: terminate */
            base[s] = v_int(nx);
            break;
        }

        case OP_THROW: {
            SpValue v = sp[-1];
            if (v.type != T_ERROR) {
                (void)vm_set_error(vm, E_TYPE, "only error values can be thrown, not %s", type_name(v));
                RAISE();
            }
            sp--;
            vm->pend_obj = v;
            RAISE();
        }
        case OP_TRY_BEGIN: {
            int32_t off = I32();
            if (vm->nh >= vm->hcap) { SYNC(); vm_fatal(vm, RS_MEMORY, "try nesting limit exceeded"); }
            Handler *h = &vm->handlers[vm->nh++];
            h->frame = vm->nframes - 1;
            h->pc = pc + off;
            h->sp = sp;
            h->ddepth = vm->ndr;
            break;
        }
        case OP_TRY_END: vm->nh--; break;

        case OP_PANIC: {
            SpValue pv = sp[-1];
            GCP();
            SString *msg = vm_to_string(vm, pv);
            sp--;
            SYNC();
            vm->pend_obj = v_obj(T_ERROR, vm_make_error(vm, E_PANIC, vm_new_string(vm, "Panic", 5), msg));
            RAISE();
        }
        case OP_DEFER_SCOPE: { unsigned s = U16(); base[s] = v_int(vm->ndr); break; }
        case OP_RUN_DEFERS: {
            unsigned s = U16();
            if (vm->ndr > base[s].as.i) {
                fr->pc = ipc;
                pc = ipc;
                defer_mode = FK_DEFER_RUN;
                goto start_defer;
            }
            break;
        }
        case OP_DEFER: {
            int n = (int)U8();
            SpValue *fv = sp - n - 1;
            SYNC();
            if (fv->type == T_CLASS) *fv = v_obj(T_FUNCTION, AS_CLASS(*fv)->ctor);
            if (check_callable(vm, fv, n)) RAISE();
            defer_register(vm, fv, n + 1, NULL);
            sp = fv;
            break;
        }
        case OP_DEFER_INVOKE: {
            SString *mname = AS_STR(proto->consts[U16()]);
            int n = (int)U8();
            SpValue *ov = sp - n - 1;
            SYNC();
            if (ov->type == T_ARRAY || ov->type == T_STRING) {
                if (!sp_invoke_method_exists(ov->type, mname->data, mname->len)) {
                    (void)vm_set_error(vm, E_NAME, "'%s' has no method '%s'", type_name(*ov), mname->data);
                    RAISE();
                }
                defer_register(vm, ov, n + 1, mname);
            } else {
                SpValue fv;
                int nv = n + 1;
                if (ov->type != T_TABLE && ov->type != T_MODULE && ov->type != T_INSTANCE && ov->type != T_CLASS) {
                    (void)vm_set_error(vm, E_TYPE, "'%s' object has no method '%s'", type_name(*ov), mname->data);
                    RAISE();
                }
                if (get_member(vm, *ov, mname, &fv)) RAISE();
                if (ov->type == T_INSTANCE && fv.type == T_FUNCTION &&
                    table_get_sstr(AS_INSTANCE(*ov)->cls->methods, mname, &(SpValue){0})) {
                    if (sp + 8 > vm->stack_end) vm_fatal(vm, RS_MEMORY, "operand stack overflow");
                    memmove(ov + 1, ov, (size_t)(n + 1) * sizeof *ov);
                    ov[0] = fv;
                    sp++;
                    nv++;
                } else {
                    *ov = fv;
                }
                if (ov->type == T_CLASS) *ov = v_obj(T_FUNCTION, AS_CLASS(*ov)->ctor);
                if (check_callable(vm, ov, nv - 1)) RAISE();
                defer_register(vm, ov, nv, NULL);
            }
            sp = ov;
            break;
        }

        case OP_NEW_INSTANCE: {
            if (sp[-1].type != T_CLASS) { (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: NEW_INSTANCE needs a class"); RAISE(); }
            GCP();
            sp[-1] = v_obj(T_INSTANCE, vm_new_instance(vm, AS_CLASS(sp[-1])));
            break;
        }
        case OP_SET_SLOT: {
            unsigned i = U16();
            if (sp[-2].type != T_INSTANCE || (int)i >= AS_INSTANCE(sp[-2])->nslots) {
                (void)vm_set_error(vm, E_RUNTIME, "corrupt bytecode: bad instance slot");
                RAISE();
            }
            AS_INSTANCE(sp[-2])->slots[i] = sp[-1];
            sp -= 2;
            break;
        }
        case OP_CTOR_CHECK: {
            unsigned s = U16();
            SpValue a = base[s];
            if (a.type == T_ARRAY && AS_ARRAY(a)->len > 0) {
                SYNC();
                (void)vm_set_error(vm, E_TYPE, "%s() takes no arguments but %lld were given", proto->name ? proto->name : "class",
                                   (long long)AS_ARRAY(a)->len);
                RAISE();
            }
            break;
        }
        case OP_RAISE_ERR: {
            int code = (int)U8();
            SString *m = AS_STR(proto->consts[U16()]);
            SYNC();
            (void)vm_set_error(vm, code, "%s", m->data);
            RAISE();
        }
        case OP_CLASS: {
            const ClassInfo *ci = &vm->prog->classes[U16()];
            GCP();
            SYNC();
            int nm = ci->nmethods;
            SpValue *ms = sp - nm;
            SpValue pv = ms[-1];
            SClass *parent = pv.type == T_CLASS ? AS_CLASS(pv) : NULL;
            SClass *cls = vm_new_class(vm, vm_new_string(vm, ci->name, strlen(ci->name)), parent);
            int nf = 0;
            if (parent) {
                SpValue k, val;
                int64_t cur = 0;
                while ((cur = table_next(parent->fields, cur, &k, &val)) >= 0) (void)table_set(vm, cls->fields, k, val);
                cur = 0;
                while ((cur = table_next(parent->methods, cur, &k, &val)) >= 0) (void)table_set(vm, cls->methods, k, val);
                nf = parent->nfields;
            }
            for (int i = 0; i < ci->nfields; i++)
                table_set_str(vm, cls->fields, ci->field_names[i], strlen(ci->field_names[i]), v_int(nf++));
            cls->nfields = nf;
            for (int i = 0; i < nm; i++)
                table_set_str(vm, cls->methods, ci->method_names[i], strlen(ci->method_names[i]), ms[i]);
            cls->ctor = vm_new_closure_obj(vm, vm->prog->protos[ci->ctor_proto], 0);
            sp = ms;
            sp[-1] = v_obj(T_CLASS, cls);
            break;
        }
        case OP_YIELD: {
            if (!vm->cur_co) {
                SYNC();
                (void)vm_set_error(vm, E_RUNTIME, "yield outside of a coroutine");
                RAISE();
            }
            for (int i = 0; i < vm->nframes; i++)
                if (vm->frames[i].kind != FK_NORMAL && vm->frames[i].kind != FK_CTOR) {
                    SYNC();
                    (void)vm_set_error(vm, E_RUNTIME, "cannot yield from a deferred call or a native callback");
                    RAISE();
                }
            SpValue yv = sp[-1];
            sp--;
            SYNC();
            SCoroutine *co = vm->cur_co;
            exec_save(vm, &co->st);
            co->status = CO_SUSPENDED;
            exec_load(vm, &co->caller);
            vm->cur_co = co->resumer;
            if (vm->cur_co) vm->cur_co->status = CO_RUNNING;
            sp = vm->sp;
            LOAD_FRAME();
            PUSH(yv);
            break;
        }
        case OP_TEST_ARRAY: {
            unsigned n = U16();
            SpValue v = sp[-1];
            sp[-1] = v_bool(v.type == T_ARRAY && (uint64_t)AS_ARRAY(v)->len == n);
            break;
        }
        case OP_TEST_HAS: {
            SString *k = AS_STR(proto->consts[U16()]);
            SpValue v = sp[-1];
            int has = 0;
            SpValue tmp;
            if (v.type == T_TABLE) has = table_get_str(AS_TABLE(v), k->data, k->len, &tmp);
            else if (v.type == T_INSTANCE) has = table_get_str(AS_INSTANCE(v)->cls->fields, k->data, k->len, &tmp);
            sp[-1] = v_bool(has);
            break;
        }
        case OP_MATCH_FAIL: {
            char buf[120];
            Out w = {0};
            w.dst = buf;
            w.cap = sizeof buf - 1;
            fmt_value(vm, sp[-1], 0, 1, &w);
            buf[w.len < w.cap ? w.len : w.cap] = 0;
            sp--;
            SYNC();
            (void)vm_set_error(vm, E_MATCH, "no case matched %s", buf);
            RAISE();
        }

        case OP_ASSERT_FAIL: {
            SpValue m = sp[-1];
            SString *msg;
            GCP();
            msg = m.type == T_NIL ? vm_new_string(vm, "assertion failed", 16) : vm_to_string(vm, m);
            sp--;
            SYNC();
            fr->pc = ipc;
            vm->pend_obj = v_obj(T_ERROR, vm_make_error(vm, E_ASSERT, vm->type_names[0] ? vm_new_string(vm, "AssertionError", 14) : NULL, msg));
            RAISE();
        }

        case OP_Q_LLI_ADD: L_OP_Q_LLI_ADD: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qx.type != T_INT || add_ovf(qx.as.i, qk, &qr)) goto q_deopt;
            
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_SUB: L_OP_Q_LLI_SUB: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qx.type != T_INT || sub_ovf(qx.as.i, qk, &qr)) goto q_deopt;
            
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_MOD: L_OP_Q_LLI_MOD: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qx.type != T_INT || qk <= 0) goto q_deopt;
            if ((qk & (qk - 1)) == 0) qr = qx.as.i & (qk - 1);
            else if ((((uint64_t)qx.as.i | (uint64_t)qk) >> 32) == 0) qr = (int64_t)((uint32_t)qx.as.i % (uint32_t)qk); /* 32-bit div is much cheaper */
            else { qr = qx.as.i % qk; if (qr < 0) qr += qk; }
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_LT: L_OP_Q_LLI_LT: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
            PUSH(v_bool(qx.as.i < qk)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_LE: L_OP_Q_LLI_LE: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
            PUSH(v_bool(qx.as.i <= qk)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_GT: L_OP_Q_LLI_GT: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
            PUSH(v_bool(qx.as.i > qk)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_GE: L_OP_Q_LLI_GE: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
            PUSH(v_bool(qx.as.i >= qk)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_EQ: L_OP_Q_LLI_EQ: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
            PUSH(v_bool(qx.as.i == qk)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLI_NE: L_OP_Q_LLI_NE: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
            PUSH(v_bool(qx.as.i != qk)); pc = ipc + 7; NEXT();
        }
        case OP_Q_ADD_L: L_OP_Q_ADD_L: {
            SpValue qa = sp[-1], qb = base[rd16(ipc + 1)];
            int64_t qr;
            if (qa.type == T_INT && qb.type == T_INT) { if (add_ovf(qa.as.i, qb.as.i, &qr)) goto q_deopt; sp[-1] = v_int(qr); }
            else if (qa.type == T_FLOAT && qb.type == T_FLOAT) sp[-1] = v_float(qa.as.f + qb.as.f);
            else goto q_deopt;
            pc = ipc + 4; NEXT();
        }
        case OP_Q_SUB_L: L_OP_Q_SUB_L: {
            SpValue qa = sp[-1], qb = base[rd16(ipc + 1)];
            int64_t qr;
            if (qa.type == T_INT && qb.type == T_INT) { if (sub_ovf(qa.as.i, qb.as.i, &qr)) goto q_deopt; sp[-1] = v_int(qr); }
            else if (qa.type == T_FLOAT && qb.type == T_FLOAT) sp[-1] = v_float(qa.as.f - qb.as.f);
            else goto q_deopt;
            pc = ipc + 4; NEXT();
        }
        case OP_Q_MUL_L: L_OP_Q_MUL_L: {
            SpValue qa = sp[-1], qb = base[rd16(ipc + 1)];
            int64_t qr;
            if (qa.type == T_INT && qb.type == T_INT) { if (mul_ovf(qa.as.i, qb.as.i, &qr)) goto q_deopt; sp[-1] = v_int(qr); }
            else if (qa.type == T_FLOAT && qb.type == T_FLOAT) sp[-1] = v_float(qa.as.f * qb.as.f);
            else goto q_deopt;
            pc = ipc + 4; NEXT();
        }
        case OP_Q_DIV_L: L_OP_Q_DIV_L: {
            SpValue qa = sp[-1], qb = base[rd16(ipc + 1)];
            if (qa.type != T_FLOAT || qb.type != T_FLOAT || sp_feq(qb.as.f, 0.0)) goto q_deopt;
            sp[-1] = v_float(qa.as.f / qb.as.f);
            pc = ipc + 4; NEXT();
        }
        case OP_Q_MODEQ_JF: case OP_Q_MODNE_JF: L_OP_Q_MODEQ_JF: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qm = (int16_t)(uint16_t)rd16(ipc + 4), qk = (int16_t)(uint16_t)rd16(ipc + 8), qr;
            if (qx.type != T_INT || qm <= 0) goto q_deopt;
            if ((qm & (qm - 1)) == 0) qr = qx.as.i & (qm - 1);
            else if ((((uint64_t)qx.as.i | (uint64_t)qm) >> 32) == 0) qr = (int64_t)((uint32_t)qx.as.i % (uint32_t)qm);
            else { qr = qx.as.i % qm; if (qr < 0) qr += qm; }
            pc = ipc + 16;
            if ((qr == qk) != (ipc[0] == OP_Q_MODEQ_JF)) { int32_t qo = (int32_t)rd32(ipc + 12); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLI_LT_JF: L_OP_Q_LLI_LT_JF: q_lli_lt_jf: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!(qx.as.i < qk)) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLI_LE_JF: L_OP_Q_LLI_LE_JF: q_lli_le_jf: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!(qx.as.i <= qk)) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLI_GT_JF: L_OP_Q_LLI_GT_JF: q_lli_gt_jf: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!(qx.as.i > qk)) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLI_GE_JF: L_OP_Q_LLI_GE_JF: q_lli_ge_jf: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!(qx.as.i >= qk)) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLI_EQ_JF: L_OP_Q_LLI_EQ_JF: q_lli_eq_jf: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!(qx.as.i == qk)) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLI_NE_JF: L_OP_Q_LLI_NE_JF: q_lli_ne_jf: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4);
            if (qx.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!(qx.as.i != qk)) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLL_ADD: L_OP_Q_LLL_ADD: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int64_t qr;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) { PUSH(v_float(qx.as.f + qy.as.f)); pc = ipc + 7; NEXT(); }
            if (qx.type != T_INT || qy.type != T_INT || add_ovf(qx.as.i, qy.as.i, &qr)) goto q_deopt;
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_SUB: L_OP_Q_LLL_SUB: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int64_t qr;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) { PUSH(v_float(qx.as.f - qy.as.f)); pc = ipc + 7; NEXT(); }
            if (qx.type != T_INT || qy.type != T_INT || sub_ovf(qx.as.i, qy.as.i, &qr)) goto q_deopt;
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_MUL: L_OP_Q_LLL_MUL: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int64_t qr;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) { PUSH(v_float(qx.as.f * qy.as.f)); pc = ipc + 7; NEXT(); }
            if (qx.type != T_INT || qy.type != T_INT || mul_ovf(qx.as.i, qy.as.i, &qr)) goto q_deopt;
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_SI_LT_JF: case OP_Q_SI_LE_JF: case OP_Q_SI_GT_JF: case OP_Q_SI_GE_JF: case OP_Q_SI_EQ_JF: case OP_Q_SI_NE_JF: L_OP_Q_SI_LT_JF: {
            SpValue qx = sp[-1];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 1);
            if (qx.type != T_INT) goto q_deopt;
            int qc;
            switch (ipc[0]) {
            case OP_Q_SI_LT_JF: qc = qx.as.i < qk; break;
            case OP_Q_SI_LE_JF: qc = qx.as.i <= qk; break;
            case OP_Q_SI_GT_JF: qc = qx.as.i > qk; break;
            case OP_Q_SI_GE_JF: qc = qx.as.i >= qk; break;
            case OP_Q_SI_EQ_JF: qc = qx.as.i == qk; break;
            default: qc = qx.as.i != qk; break;
            }
            sp--;
            pc = ipc + 9;
            if (!qc) { int32_t qo = (int32_t)rd32(ipc + 5); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLI_FDIV: L_OP_Q_LLI_FDIV: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qx.type != T_INT || qk <= 0) goto q_deopt;
            if ((qk & (qk - 1)) == 0) qr = qx.as.i >> __builtin_ctzll((unsigned long long)qk);   /* 2^n: an arithmetic shift is the floor division */
            else if (qx.as.i >= 0) qr = (((uint64_t)qx.as.i | (uint64_t)qk) >> 32) == 0 ? (int64_t)((uint32_t)qx.as.i / (uint32_t)qk) : qx.as.i / qk;
            else { qr = qx.as.i / qk; if (qx.as.i % qk != 0) qr--; }
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_IL_ADD: case OP_Q_IL_MUL: L_OP_Q_IL_ADD: {
            SpValue qx = base[rd16(ipc + 4)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 1), qr;
            if (qx.type != T_INT || (ipc[0] == OP_Q_IL_ADD ? add_ovf(qx.as.i, qk, &qr) : mul_ovf(qx.as.i, qk, &qr))) goto q_deopt;
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_DIV: L_OP_Q_LLL_DIV: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            if (qx.type != T_FLOAT || qy.type != T_FLOAT || sp_feq(qy.as.f, 0.0)) goto q_deopt;
            PUSH(v_float(qx.as.f / qy.as.f)); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_LT: L_OP_Q_LLL_LT: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
            PUSH(v_bool((qf ? qx.as.f < qy.as.f : qx.as.i < qy.as.i))); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_LE: L_OP_Q_LLL_LE: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
            PUSH(v_bool((qf ? qx.as.f <= qy.as.f : qx.as.i <= qy.as.i))); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_GT: L_OP_Q_LLL_GT: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
            PUSH(v_bool((qf ? qx.as.f > qy.as.f : qx.as.i > qy.as.i))); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_GE: L_OP_Q_LLL_GE: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
            PUSH(v_bool((qf ? qx.as.f >= qy.as.f : qx.as.i >= qy.as.i))); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_EQ: L_OP_Q_LLL_EQ: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
            PUSH(v_bool((qf ? sp_feq(qx.as.f, qy.as.f) : qx.as.i == qy.as.i))); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_NE: L_OP_Q_LLL_NE: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
            PUSH(v_bool((qf ? !sp_feq(qx.as.f, qy.as.f) : qx.as.i != qy.as.i))); pc = ipc + 7; NEXT();
        }
        case OP_Q_LLL_LT_JF: L_OP_Q_LLL_LT_JF: q_lll_lt_jf: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!((qf ? qx.as.f < qy.as.f : qx.as.i < qy.as.i))) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLL_LE_JF: L_OP_Q_LLL_LE_JF: q_lll_le_jf: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!((qf ? qx.as.f <= qy.as.f : qx.as.i <= qy.as.i))) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLL_GT_JF: L_OP_Q_LLL_GT_JF: q_lll_gt_jf: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!((qf ? qx.as.f > qy.as.f : qx.as.i > qy.as.i))) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLL_GE_JF: L_OP_Q_LLL_GE_JF: q_lll_ge_jf: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!((qf ? qx.as.f >= qy.as.f : qx.as.i >= qy.as.i))) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLL_EQ_JF: L_OP_Q_LLL_EQ_JF: q_lll_eq_jf: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!((qf ? sp_feq(qx.as.f, qy.as.f) : qx.as.i == qy.as.i))) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_LLL_NE_JF: L_OP_Q_LLL_NE_JF: q_lll_ne_jf: {
            SpValue qx = base[rd16(ipc + 1)], qy = base[rd16(ipc + 4)];
            int qf = 0;
            if (qx.type == T_FLOAT && qy.type == T_FLOAT) qf = 1;
            else if (qx.type != T_INT || qy.type != T_INT) goto q_deopt;
           
            pc = ipc + 12;
            if (!((qf ? !sp_feq(qx.as.f, qy.as.f) : qx.as.i != qy.as.i))) { int32_t qo = (int32_t)rd32(ipc + 8); pc += qo; if (qo < 0) TICK(); }
            NEXT();
        }
        case OP_Q_RANGE_NEXT_ST: L_OP_Q_RANGE_NEXT_ST: q_rn: {
            unsigned qs = rd16(ipc + 1);
            if (base[qs].type != T_INT || base[qs + 1].type != T_INT || base[qs + 2].type != T_INT || base[qs + 2].as.i == 0)
                goto q_deopt;
            int64_t cur = base[qs].as.i, stop = base[qs + 1].as.i, step = base[qs + 2].as.i;
            if (step > 0 ? cur >= stop : cur <= stop) { pc = ipc + 7 + (int32_t)rd32(ipc + 3); break; }
            int64_t nx;
            if (add_ovf(cur, step, &nx)) nx = stop;
            base[qs] = v_int(nx);
            base[rd16(ipc + 8)] = v_int(cur);
           
            pc = ipc + 10;
            NEXT();
        }
#define Q_ACCUMULATE(DEST, ARITH) do { \
            SpValue *qd_ = (DEST); \
            SpValue qs_ = *qd_, qx_ = base[rd16(ipc + 4)]; \
            int64_t qk_ = (int16_t)(uint16_t)rd16(ipc + 7), qr_, qt_; \
            if (qs_.type != T_INT || qx_.type != T_INT) goto q_deopt; \
            if ((ARITH) == OP_MOD) { \
                if (qk_ <= 0) goto q_deopt; \
                if ((qk_ & (qk_ - 1)) == 0) qr_ = qx_.as.i & (qk_ - 1); \
                else if ((((uint64_t)qx_.as.i | (uint64_t)qk_) >> 32) == 0) qr_ = (int64_t)((uint32_t)qx_.as.i % (uint32_t)qk_); \
                else { qr_ = qx_.as.i % qk_; if (qr_ < 0) qr_ += qk_; } \
            } else if ((ARITH) == OP_MUL) { if (mul_ovf(qx_.as.i, qk_, &qr_)) goto q_deopt; } \
            else if ((ARITH) == OP_ADD) { if (add_ovf(qx_.as.i, qk_, &qr_)) goto q_deopt; } \
            else { if (sub_ovf(qx_.as.i, qk_, &qr_)) goto q_deopt; } \
            if (add_ovf(qs_.as.i, qr_, &qt_)) goto q_deopt; \
            *qd_ = v_int(qt_); pc = ipc + 14; NEXT(); \
        } while (0)
        case OP_Q_ACC_I: L_OP_Q_ACC_I_ADD:
            Q_ACCUMULATE(&base[rd16(ipc + 12)], OP_ADD);
        case OP_Q_ACC_IM: L_OP_Q_ACC_IM_ADD:
            Q_ACCUMULATE(&vm->slots[rd16(ipc + 12)], OP_ADD);
        case OP_Q_ACC_I_MOD: L_OP_Q_ACC_I_MOD:
            Q_ACCUMULATE(&base[rd16(ipc + 12)], OP_MOD);
        case OP_Q_ACC_I_MUL: L_OP_Q_ACC_I_MUL:
            Q_ACCUMULATE(&base[rd16(ipc + 12)], OP_MUL);
        case OP_Q_ACC_I_SUB: L_OP_Q_ACC_I_SUB:
            Q_ACCUMULATE(&base[rd16(ipc + 12)], OP_SUB);
        case OP_Q_ACC_IM_MOD: L_OP_Q_ACC_IM_MOD:
            Q_ACCUMULATE(&vm->slots[rd16(ipc + 12)], OP_MOD);
        case OP_Q_ACC_IM_MUL: L_OP_Q_ACC_IM_MUL:
            Q_ACCUMULATE(&vm->slots[rd16(ipc + 12)], OP_MUL);
        case OP_Q_ACC_IM_SUB: L_OP_Q_ACC_IM_SUB:
            Q_ACCUMULATE(&vm->slots[rd16(ipc + 12)], OP_SUB);
#undef Q_ACCUMULATE
        case OP_Q_ACC_L: case OP_Q_ACC_LM: L_OP_Q_ACC_L: {
            SpValue *qd = ipc[0] == OP_Q_ACC_L ? &base[rd16(ipc + 8)] : &vm->slots[rd16(ipc + 8)];
            SpValue qs = *qd, qx = base[rd16(ipc + 4)];
            int64_t qr;
            if (qs.type == T_INT && qx.type == T_INT && !add_ovf(qs.as.i, qx.as.i, &qr)) *qd = v_int(qr);
            else if (qs.type == T_FLOAT && qx.type == T_FLOAT) *qd = v_float(qs.as.f + qx.as.f);
            else goto q_deopt;
            pc = ipc + 10; NEXT();
        }
        case OP_Q_LLI_MUL: L_OP_Q_LLI_MUL: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qx.type != T_INT || mul_ovf(qx.as.i, qk, &qr)) goto q_deopt;
            PUSH(v_int(qr)); pc = ipc + 7; NEXT();
        }
        case OP_Q_SI_ADD: case OP_Q_SI_SUB: case OP_Q_SI_MUL: L_OP_Q_SI_ADD: {
            SpValue qx = sp[-1];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 1), qr;
            int ovf;
            if (qx.type != T_INT) goto q_deopt;
            if (ipc[0] == OP_Q_SI_ADD) ovf = add_ovf(qx.as.i, qk, &qr);
            else if (ipc[0] == OP_Q_SI_SUB) ovf = sub_ovf(qx.as.i, qk, &qr);
            else ovf = mul_ovf(qx.as.i, qk, &qr);
            if (ovf) goto q_deopt;
            sp[-1] = v_int(qr); pc = ipc + 4; NEXT();
        }
        case OP_Q_LLI_ADD_ST: L_OP_Q_LLI_ADD_ST: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qx.type != T_INT || add_ovf(qx.as.i, qk, &qr)) goto q_deopt;
            base[rd16(ipc + 8)] = v_int(qr); pc = ipc + 10; NEXT();
        }
        case OP_Q_LLI_SUB_ST: L_OP_Q_LLI_SUB_ST: {
            SpValue qx = base[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qx.type != T_INT || sub_ovf(qx.as.i, qk, &qr)) goto q_deopt;
            base[rd16(ipc + 8)] = v_int(qr); pc = ipc + 10; NEXT();
        }
        case OP_Q_ADD_ST: case OP_Q_SUB_ST: L_OP_Q_ADD_ST: {
            SpValue qa = sp[-2], qb = sp[-1];
            int64_t qr;
            if (qa.type == T_INT && qb.type == T_INT &&
                !(ipc[0] == OP_Q_ADD_ST ? add_ovf(qa.as.i, qb.as.i, &qr) : sub_ovf(qa.as.i, qb.as.i, &qr)))
                base[rd16(ipc + 2)] = v_int(qr);
            else if (qa.type == T_FLOAT && qb.type == T_FLOAT)
                base[rd16(ipc + 2)] = v_float(ipc[0] == OP_Q_ADD_ST ? qa.as.f + qb.as.f : qa.as.f - qb.as.f);
            else goto q_deopt;
            sp -= 2; pc = ipc + 4; NEXT();
        }
        case OP_Q_MUL_ST: L_OP_Q_MUL_ST: {
            SpValue qa = sp[-2], qb = sp[-1];
            int64_t qr;
            if (qa.type == T_FLOAT && qb.type == T_FLOAT) base[rd16(ipc + 2)] = v_float(qa.as.f * qb.as.f);
            else if (qa.type == T_INT && qb.type == T_INT && !mul_ovf(qa.as.i, qb.as.i, &qr)) base[rd16(ipc + 2)] = v_int(qr);
            else goto q_deopt;
            sp -= 2; pc = ipc + 4; NEXT();
        }
        case OP_Q_ADD_STM: case OP_Q_SUB_STM: L_OP_Q_ADD_STM: {
            SpValue qa = sp[-2], qb = sp[-1];
            int64_t qr;
            if (qa.type == T_INT && qb.type == T_INT &&
                !(ipc[0] == OP_Q_ADD_STM ? add_ovf(qa.as.i, qb.as.i, &qr) : sub_ovf(qa.as.i, qb.as.i, &qr)))
                vm->slots[rd16(ipc + 2)] = v_int(qr);
            else if (qa.type == T_FLOAT && qb.type == T_FLOAT)
                vm->slots[rd16(ipc + 2)] = v_float(ipc[0] == OP_Q_ADD_STM ? qa.as.f + qb.as.f : qa.as.f - qb.as.f);
            else goto q_deopt;
            sp -= 2; pc = ipc + 4; NEXT();
        }
        case OP_Q_JUMP_RN: case OP_Q_JUMP_LLL_LT: case OP_Q_JUMP_LLI_LT: L_OP_Q_JUMP_RN: {
            int qj = ipc[0];
            int32_t qo = (int32_t)rd32(ipc + 1);
            ipc = ipc + 5 + qo;
            pc = ipc + 1;
            if (qo < 0) { const uint8_t *jr_ = NULL; TICK(); JIT_HOOK(ipc, jr_, ipc); if (jr_) break; }
            if (qj == OP_Q_JUMP_RN) goto q_rn;
            if (qj == OP_Q_JUMP_LLL_LT) goto q_lll_lt_jf;
            goto q_lli_lt_jf;
        }
        case OP_Q_JUMP_JF: L_OP_Q_JUMP_JF: {
            int32_t qo = (int32_t)rd32(ipc + 1);
            ipc = ipc + 5 + qo;
            pc = ipc + 1;
            if (qo < 0) { const uint8_t *jr_ = NULL; TICK(); JIT_HOOK(ipc, jr_, ipc); if (jr_) break; }
            switch (ipc[0]) {
            case OP_Q_LLI_LE_JF: goto q_lli_le_jf;
            case OP_Q_LLI_GT_JF: goto q_lli_gt_jf;
            case OP_Q_LLI_GE_JF: goto q_lli_ge_jf;
            case OP_Q_LLI_EQ_JF: goto q_lli_eq_jf;
            case OP_Q_LLI_NE_JF: goto q_lli_ne_jf;
            case OP_Q_LLL_LE_JF: goto q_lll_le_jf;
            case OP_Q_LLL_GT_JF: goto q_lll_gt_jf;
            case OP_Q_LLL_GE_JF: goto q_lll_ge_jf;
            case OP_Q_LLL_EQ_JF: goto q_lll_eq_jf;
            default: goto q_lll_ne_jf;
            }
        }
        case OP_Q_RET_LOCAL: L_OP_Q_RET_LOCAL: {
            int qi = vm->nframes - 1;
            if (fr->kind == FK_NORMAL && qi > 0 && (vm->nh == 0 || vm->handlers[vm->nh - 1].frame < qi)) {
                SpValue qr = base[rd16(ipc + 1)];
                sp = fr->base - 1;
                *sp++ = qr;
                vm->nframes = qi;
                fr--;
                pc = fr->pc;
                base = fr->base;
                proto = fr->fn->proto;
                break;
            }
            goto q_deopt;
        }
        case OP_Q_LOCAL_GETM: L_OP_Q_LOCAL_GETM: {
            SpValue qo = base[rd16(ipc + 1)];
            if (qo.type == T_INSTANCE) {
                const SInstance *qi = AS_INSTANCE(qo);
                const ICEnt *ce = ic_find(vm, qi->cls, AS_STR(proto->consts[rd16(ipc + 4)]));
                if (ce) { PUSH(ce->kind == 1 ? qi->slots[ce->slot] : ce->fn); pc = ipc + 6; NEXT(); }
            }
            goto q_deopt;
        }
        case OP_Q_UP_INC: L_OP_Q_UP_INC: {
            SCell *qu = fr->fn->up[rd16(ipc + 1)];
            int64_t qk = (int16_t)(uint16_t)rd16(ipc + 4), qr;
            if (qu->v.type != T_INT || add_ovf(qu->v.as.i, qk, &qr)) goto q_deopt;
            qu->v = v_int(qr); pc = ipc + 10; NEXT();
        }
        case OP_Q_RET_UP: L_OP_Q_RET_UP: {
            int qi = vm->nframes - 1;
            if (fr->kind == FK_NORMAL && qi > 0 && (vm->nh == 0 || vm->handlers[vm->nh - 1].frame < qi)) {
                SpValue qr = fr->fn->up[rd16(ipc + 1)]->v;
                sp = fr->base - 1;
                *sp++ = qr;
                vm->nframes = qi;
                fr--;
                pc = fr->pc;
                base = fr->base;
                proto = fr->fn->proto;
                break;
            }
            goto q_deopt;
        }
        case OP_Q_IDX_L: L_OP_Q_IDX_L: {
            SpValue qa = sp[-1], qb = base[rd16(ipc + 1)];
            if (qa.type == T_ARRAY && qb.type == T_INT) {
                const SArray *arr = AS_ARRAY(qa);
                if (qb.as.i >= 0 && qb.as.i < arr->len) { sp[-1] = arr->items[qb.as.i]; pc = ipc + 4; NEXT(); }
            }
            goto q_deopt;
        }
        case OP_Q_SETIDX_LLL: case OP_Q_SETIDX_LLB: L_OP_Q_SETIDX_LLL: {
            SpValue qa = base[rd16(ipc + 1)], qb = base[rd16(ipc + 4)];
            if (qa.type == T_ARRAY && qb.type == T_INT) {
                SArray *arr = AS_ARRAY(qa);
                if (qb.as.i >= 0 && qb.as.i < arr->len) {
                    if (ipc[0] == OP_Q_SETIDX_LLL) {
                        array_note_store(arr, base[rd16(ipc + 7)]);
                        arr->items[qb.as.i] = base[rd16(ipc + 7)];
                        pc = ipc + 10;
                    } else {
                        array_note_store(arr, v_bool(ipc[6] == OP_TRUE));
                        arr->items[qb.as.i] = v_bool(ipc[6] == OP_TRUE);
                        pc = ipc + 8;
                    }
                    break;
                }
            }
            goto q_deopt;
        }
        case OP_Q_LL_IDX: L_OP_Q_LL_IDX: {
            SpValue qa = base[rd16(ipc + 1)], qb = base[rd16(ipc + 4)];
            if (qa.type == T_ARRAY && qb.type == T_INT) {
                const SArray *arr = AS_ARRAY(qa);
                if (qb.as.i >= 0 && qb.as.i < arr->len) { PUSH(arr->items[qb.as.i]); pc = ipc + 7; NEXT(); }
            } else if (qa.type == T_NATIVE) {
                SpValue qr;
                if (typed_peek(qa, qb, &qr)) { PUSH(qr); pc = ipc + 7; NEXT(); }
            }
            goto q_deopt;
        }
        q_deopt:
            /* run the original first instruction; the rest follow normally */
            pc = ipc + 1;
            switch (ipc[0]) {
            case OP_Q_RANGE_NEXT_ST: goto q_range_next;
            case OP_Q_SI_ADD: case OP_Q_SI_SUB: case OP_Q_SI_MUL: goto q_smallint;
            case OP_Q_SI_LT_JF: case OP_Q_SI_LE_JF: case OP_Q_SI_GT_JF: case OP_Q_SI_GE_JF: case OP_Q_SI_EQ_JF: case OP_Q_SI_NE_JF:
            case OP_Q_IL_ADD: case OP_Q_IL_MUL: goto q_smallint;
            case OP_Q_ADD_ST: case OP_Q_ADD_STM: goto q_add;
            case OP_Q_SUB_ST: case OP_Q_SUB_STM: goto q_sub;
            case OP_Q_MUL_ST: goto q_mul;
            case OP_Q_ACC_IM: case OP_Q_ACC_LM:
            case OP_Q_ACC_IM_MOD: case OP_Q_ACC_IM_MUL: case OP_Q_ACC_IM_SUB: goto q_load_module;
            case OP_Q_ACC_I_MOD: case OP_Q_ACC_I_MUL: case OP_Q_ACC_I_SUB: goto q_load_local;
            case OP_Q_UP_INC: case OP_Q_RET_UP: goto q_load_upval;
            default: goto q_load_local;
            }

        /* every byte value has a case, so the compiler needs no range check before the jump table */
        case 0xDE: case 0xDF: case 0xE6:
        case 0xE7: case 0xE8: case 0xE9: case 0xEA:
        case 0xEB: case 0xEC: case 0xED: case 0xEE: case 0xEF: case 0xF0: case 0xF1: case 0xF2:
        case 0xF3: case 0xF4: case 0xF5: case 0xF6: case 0xF7: case 0xF8: case 0xF9: case 0xFA:
        case 0xFB: case 0xFC: case 0xFD: case 0xFE: case 0xFF:
            SYNC();
            vm_fatal(vm, RS_ERROR, "internal error: invalid opcode 0x%02X (reserved)", (unsigned)pc[-1]);
        default:
            SYNC();
            vm_fatal(vm, RS_ERROR, "internal error: invalid opcode 0x%02X", (unsigned)pc[-1]);
        }
        continue;

    L_slow:
        pc = ipc;
        continue;

    do_call: {
        TICK();
        if (sp[-nargs - 1].type == T_CLASS) {
            SClass *cc = AS_CLASS(sp[-nargs - 1]);
            if (cc->fast == 0) vm_class_analyze(cc);
            if (cc->fast == 1 && call_kind == FK_NORMAL) {
                /* construction fast path (see vm_class_analyze) */
                GCP();
                SInstance *ci = vm_new_instance(vm, cc);
                if (cc->dflt)
                    for (int i = 0; i < ci->nslots; i++) ci->slots[i] = cc->dflt[i];
                SpValue *cf = sp - nargs - 1;
                if (!cc->init) {
                    if (nargs > 0) {
                        SYNC();
                        (void)vm_set_error(vm, E_TYPE, "%s() takes no arguments but %d were given", cc->name->data, nargs);
                        RAISE();
                    }
                    *cf = v_obj(T_INSTANCE, ci);
                    sp = cf + 1;
                    continue;
                }
                for (int i = nargs; i > 0; i--) cf[i + 1] = cf[i];
                cf[1] = v_obj(T_INSTANCE, ci);
                cf[0] = v_obj(T_FUNCTION, cc->init);
                sp++;
                nargs++;
                call_kind = FK_CTOR;
                call_uev = cf[1];
            } else {
                sp[-nargs - 1] = v_obj(T_FUNCTION, cc->ctor);
            }
        }
            /* call the value at sp[-nargs-1] */
            SpValue *fv = sp - nargs - 1;
            if (fv->type != T_FUNCTION) {
                (void)vm_set_error(vm, E_TYPE, "'%s' object is not callable", type_name(*fv));
                RAISE();
            }
            SFunc *f = AS_FUNC(*fv);
            if (f->nat) {
                const NativeDesc *d = f->nat;
                if (nargs == 1 && fv[1].type == T_FLOAT && d >= math_fns && d < math_fns + math_fns_count) {
                    double mr;
                    if (math_fast1(d, fv[1].as.f, &mr)) { sp = fv; PUSH(v_float(mr)); continue; }
                }
                if (nargs < d->min_args || (d->max_args >= 0 && nargs > d->max_args)) {
                    (void)vm_set_error(vm, E_TYPE, "%s() takes %s%d argument%s but %d %s given", d->name,
                                       d->max_args == d->min_args ? "" : (nargs < d->min_args ? "at least " : "at most "),
                                       nargs < d->min_args ? d->min_args : d->max_args,
                                       (nargs < d->min_args ? d->min_args : d->max_args) == 1 ? "" : "s", nargs,
                                       nargs == 1 ? "was" : "were");
                    RAISE();
                }
                SpValue ret = v_nil();
                GCP();
                SYNC();
                int nr = d->fn(vm, nargs, fv + 1, &ret);
                left = vm->ileft;
                if (nr == 1) RAISE();
                sp = fv;
                if (nr == 2) goto do_resume;
                PUSH(ret);
                continue;
            }
            Proto *p = f->proto;
            if (nargs < p->nrequired) {
                (void)vm_set_error(vm, E_TYPE, "%s() missing %d required argument%s", p->name ? p->name : "<anonymous>",
                                   p->nrequired - nargs, p->nrequired - nargs == 1 ? "" : "s");
                RAISE();
            }
            if (!p->has_rest && nargs > p->nparams) {
                (void)vm_set_error(vm, E_TYPE, "%s() takes at most %d argument%s but %d were given",
                                   p->name ? p->name : "<anonymous>", p->nparams, p->nparams == 1 ? "" : "s", nargs);
                RAISE();
            }
            if (vm->nframes >= vm->max_frames) {
                SYNC();
                vm_fatal(vm, RS_MEMORY, "call depth limit exceeded (%d)", vm->max_frames);
            }
            SpValue *nb = fv + 1;
            if (nb + p->nlocals + p->max_stack + 8 > vm->stack_end) {
                SYNC();
                vm_fatal(vm, RS_MEMORY, "operand stack limit exceeded");
            }
            int filled = nargs < p->nparams ? nargs : p->nparams;
            if (p->has_rest) {
                int extra = nargs > p->nparams ? nargs - p->nparams : 0;
                /* the in-flight error of a deferred call is only in a C local until the frame exists */
                vm->pend_obj = call_uev;
                GCP();
                vm->pend_obj = v_nil();
                SArray *ra = vm_new_array(vm, extra);
                for (int i = 0; i < extra; i++) ra->items[i] = nb[p->nparams + i];
                ra->len = extra;
                for (int i = filled; i < p->nlocals; i++) nb[i] = v_nil();
                nb[p->nparams] = v_obj(T_ARRAY, ra);
            } else {
                for (int i = filled; i < p->nlocals; i++) nb[i] = v_nil();
            }
            fr->pc = pc;
            Frame *nf = &vm->frames[vm->nframes++];
            nf->fn = f;
            nf->base = nb;
            nf->kind = call_kind;
            nf->uev = call_uev;
            nf->dbase = vm->ndr;
            call_kind = FK_NORMAL;
            call_uev = v_nil();
            uint32_t entry = 0;
            if (p->ndefaults > 0) {
                int k = nargs - p->nrequired;
                if (k > p->ndefaults) k = p->ndefaults;
                entry = p->default_pcs[k];
            }
            nf->pc = p->code + entry;
            sp = nb + p->nlocals;
#if SP_JIT
            if ((nf->kind == FK_NORMAL || nf->kind == FK_CTOR) && nargs == p->nparams && !p->has_rest && p->ndefaults == 0) {
                JitUnit *ju = p->junit;     /* methods and constructors reach compiled code here */
                if (!ju) {
                    if (p->jcall > 1) p->jcall--;
                    else ju = jit_call_hot(vm, f, nb);
                }
                if (ju) {
                    SYNC();
                    jit_run(vm, ju, nb);
                    left = vm->ileft;
                    sp = vm->sp;
                }
            }
#endif
            LOAD_FRAME();
            continue;
    }

    do_resume: {
        SCoroutine *co = vm->sw_co;
        SYNC();
        vm->sw_kind = SW_NONE;
        exec_save(vm, &co->caller);
        co->resumer = vm->cur_co;
        if (vm->cur_co) vm->cur_co->status = CO_NORMAL;
        vm->cur_co = co;
        co->status = CO_RUNNING;
        exec_load(vm, &co->st);
        if (!co->started) {
            co->started = 1;
            SFunc *f = co->fn;
            Proto *p = f->proto;
            if (vm->stack + 1 + p->nlocals + p->max_stack + 8 > vm->stack_end)
                vm_fatal(vm, RS_MEMORY, "coroutine stack is too small for its function");
            vm->stack[0] = v_obj(T_FUNCTION, f);
            SpValue *nb = vm->stack + 1;
            for (int i = 0; i < p->nlocals; i++) nb[i] = v_nil();
            if (p->has_rest) nb[p->nparams] = v_obj(T_ARRAY, vm_new_array(vm, 0));
            Frame *nf = &vm->frames[0];
            nf->fn = f;
            nf->base = nb;
            nf->pc = p->code + (p->ndefaults > 0 ? p->default_pcs[0] : 0u);
            nf->kind = FK_NORMAL;
            nf->dbase = 0;
            nf->uev = v_nil();
            vm->nframes = 1;
            vm->sp = nb + p->nlocals;
        }
        sp = vm->sp;
        LOAD_FRAME();
        if (co->closing) {
            vm->pend_obj = v_obj(T_ERROR, vm_make_error(vm, E_CLOSE, vm_new_string(vm, "Close", 5), vm_new_string(vm, "coroutine closed", 16)));
            ev = take_pending(vm);
            goto unwind;
        }
        continue;
    }

    start_defer: {
        if (sp + vm->drecs[vm->ndr - 1].nvals + 8 > vm->stack_end) {
            SYNC();
            vm_fatal(vm, RS_MEMORY, "operand stack limit exceeded");
        }
        DeferRec r = vm->drecs[--vm->ndr];
        vm->ndv -= r.nvals;
        SpValue *fv = sp;
        for (int i = 0; i < r.nvals; i++) *sp++ = vm->dvals[vm->ndv + i];
        int dn = r.nvals - 1;
        if (r.method || AS_FUNC(*fv)->nat) {
            /* natives run inline; their result is discarded */
            SpValue ret = v_nil();
            int err;
            SYNC();
            if (r.method) {
                int found = 0;
                err = lib_invoke_builtin_method_s(vm, fv[0], r.method, r.nvals, fv, &ret, &found);
                left = vm->ileft;
            } else {
                err = AS_FUNC(*fv)->nat->fn(vm, dn, fv + 1, &ret);
                left = vm->ileft;
                if (err == 2) {
                    vm->sw_kind = SW_NONE;
                    err = vm_set_error(vm, E_RUNTIME, "coroutines cannot be switched from a deferred call");
                }
            }
            sp = fv;
            if (err) {
                if (defer_mode == FK_DEFER_RUN) goto raise;
                ev = combine_errors(defer_ev, take_pending(vm));
                goto unwind;
            }
            if (defer_mode == FK_DEFER_RUN) {
                pc = ipc;
                continue;
            }
            ev = defer_ev;
            goto unwind;
        }
        nargs = dn;
        call_kind = defer_mode;
        call_uev = defer_mode == FK_DEFER_UNWIND ? defer_ev : v_nil();
        goto do_call;
    }

    raise:
        SYNC();
        fr->pc = ipc;
        ev = take_pending(vm);
        /* A constructor call that failed before its frame existed (wrong arity...) leaves its new instance in call_uev, which is
         * not a GC root: the stale pointer would end up in the next frame's uev after the instance had been collected. */
        call_uev = v_nil();
    unwind:
        for (;;) {
            int top = vm->nframes - 1;
            fr = &vm->frames[top];
            int is_panic = uncatchable(AS_ERROR(ev));
            Handler *h = NULL;
            if (!is_panic && vm->nh > 0 && vm->handlers[vm->nh - 1].frame == top) h = &vm->handlers[vm->nh - 1];
            int stop = h ? h->ddepth : fr->dbase;
            if (vm->ndr > stop) {
                defer_mode = FK_DEFER_UNWIND;
                defer_ev = ev;
                vm->sp = sp;
                goto start_defer;
            }
            if (h) {
                Handler hh = *h;
                vm->nh--;
                base = fr->base;
                proto = fr->fn->proto;
                sp = hh.sp;
                PUSH(ev);
                pc = hh.pc;
                fr->pc = pc;
                break;
            }
            if (fr->kind == FK_BOUNDARY) {
                while (vm->nh > 0 && vm->handlers[vm->nh - 1].frame >= top) vm->nh--;
                vm->pend_obj = ev;
                vm->sp = fr->base - 1;
                vm->nframes--;
                RET(RS_ERROR);
            }
            if (top == 0 && vm->cur_co) {
                SCoroutine *co = vm->cur_co;
                int closed = AS_ERROR(ev)->code == E_CLOSE;
                co->status = CO_DEAD;
                exec_load(vm, &co->caller);
                vm->cur_co = co->resumer;
                if (vm->cur_co) vm->cur_co->status = CO_RUNNING;
                vm_co_release(vm, co);
                sp = vm->sp;
                LOAD_FRAME();
                if (closed) {
                    PUSH(v_nil());
                    break;
                }
                continue;
            }
            if (top == 0) {
                vm->sp = sp;
                if (is_panic) {
                    (void)snprintf(vm->fatal_msg, sizeof vm->fatal_msg, "%s", AS_ERROR(ev)->message->data);
                    vm->fatal_status = RS_PANIC;
                    RET(RS_PANIC);
                }
                vm->uncaught = ev;
                RET(AS_ERROR(ev)->code == E_PERM ? RS_PERM : RS_ERROR);
            }
            if (fr->kind == FK_DEFER_UNWIND) ev = combine_errors(fr->uev, ev);
            while (vm->nh > 0 && vm->handlers[vm->nh - 1].frame >= top) vm->nh--;
            sp = fr->base - 1;
            vm->nframes--;
        }
    }
#undef LOAD_FRAME
#undef U8
#undef U16
#undef I32
#undef PUSH
#undef SYNC
#undef GCP
#undef RAISE
}
#undef nargs
#undef call_kind
#undef defer_mode
#undef call_uev
#undef ev
#undef defer_ev
#undef RET
#undef TICK
#undef JIT_HOOK
#undef TRACE_STEP
#undef NEXT

