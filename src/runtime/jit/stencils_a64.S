// Copy-and-patch stencils for the Sprint region JIT, AArch64 Linux (AAPCS64). Same idea as stencils.S (x86-64): each stencil is a piece
// of machine code that jit.c copies in bytecode order and patches (tools/jitgen.c turns this object into stencils_a64.h):
//
//   H0..H5   32-bit holes (slot byte offsets, structure offsets, immediates)     HQ  64-bit immediate
//   JIT_T    branch target of a branch stencil       JIT_X   the exit stub a failed guard jumps to
//
// Registers while JIT code runs (callee-saved):  x19 = VM *   x20 = frame base (locals at +0, the operand stack above)
//   x21 = constant pool   x22 = vm->slots   x23 = the current Frame.   Scratch: x0..x15, d0..d7.   Slots are 16 bytes: type word at +0, payload at +8.
//
// Immediates that depend on a hole are built with movz/movk (LDI32/LDI64) and memory offsets use the :lo12: relocation, whose scaled
// imm12 field jit.c fills with the whole offset (up to 32760 for 8-byte accesses). Stencils that are not here are left empty: a region that
// needs one is not compiled (the interpreter runs it). Regenerate stencils_a64.h with `make jit-regen-a64`.

#define T_BOOL 1
#define T_INT 2
#define T_FLOAT 3
#define T_STRING 4
#define T_ARRAY 5
#define T_FUNCTION 7
#define T_INSTANCE 9
#define T_CELL 15
#include "layout_a64.h"

.macro ST name
    .section .text.\name,"ax",%progbits
    .p2align 2
    .globl \name
    .type \name,%function
\name:
.endm

.macro LDI32 r, hole                    // x\r = the sign-extended 32-bit hole
    movz w\r, #:abs_g0_nc:\hole
    movk w\r, #:abs_g1:\hole
    sxtw x\r, w\r
.endm
.macro LDU32 r, hole                    // w\r = the 32-bit hole (zero-extended)
    movz w\r, #:abs_g0_nc:\hole
    movk w\r, #:abs_g1:\hole
.endm
.macro LDI64 r, hole                    // x\r = the 64-bit hole
    movz x\r, #:abs_g0_nc:\hole
    movk x\r, #:abs_g1_nc:\hole
    movk x\r, #:abs_g2_nc:\hole
    movk x\r, #:abs_g3:\hole
.endm
.macro SETT hole, t                     // the type word of the frame slot at \hole
    movz x9, #\t
    str x9, [x20, :lo12:\hole]
.endm

// ---- frame: entry, exit ---------------------------------------------------------------------------------
ST entry                                // loop region: x0 = VM, x1 = frame base, x2 = constants, x3 = current Frame
    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x23, x3
    mov x4, sp
    str x4, [x19, #L_VM_JRSP]
    ldr x22, [x19, #L_VM_SLOTS]

ST exit                                 // H0 = exit id, HQ = the region that owns the exit table
    LDI64 0, HQ
    str x0, [x19, #L_VM_JCUR]
    ldr x1, [x19, #L_VM_JRSP]
    mov sp, x1
    LDU32 0, H0
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

ST jmp
    b JIT_T

ST tick                                 // back edge: subtract first; a borrow means the budget was already zero
    ldr x0, [x19, :lo12:H0]
    subs x0, x0, #1
    b.lo 1f
    str x0, [x19, :lo12:H0]
    b JIT_T
1:  str xzr, [x19, :lo12:H0]
    b JIT_X

ST tick1                                // one step of budget for an inlined call
    ldr x0, [x19, :lo12:H0]
    subs x0, x0, #1
    b.lo 1f
    str x0, [x19, :lo12:H0]
    b 2f
1:  str xzr, [x19, :lo12:H0]
    b JIT_X
2:

// ---- guards ------------------------------------------------------------------------------------------------
ST gtag                                 // frame slot H0 must have type word H1
    ldr x0, [x20, :lo12:H0]
    LDI32 1, H1
    cmp x0, x1
    b.ne JIT_X

ST gntag                                // slot H0 must NOT have type word H1
    ldr x0, [x20, :lo12:H0]
    LDI32 1, H1
    cmp x0, x1
    b.eq JIT_X

ST gimm                                 // int payload of frame slot H0 must be H1
    ldr x0, [x20, :lo12:H0+8]
    LDI32 1, H1
    cmp x0, x1
    b.ne JIT_X

ST gnonneg                              // int slot H0 must be non-negative
    ldr x0, [x20, :lo12:H0+8]
    tbnz x0, #63, JIT_X

ST gnz                                  // int slot H0 must be non-zero
    ldr x0, [x20, :lo12:H0+8]
    cbz x0, JIT_X

ST gtag_mod                             // module variable at byte offset H0 must have type word H1
    ldr x0, [x22, :lo12:H0]
    LDI32 1, H1
    cmp x0, x1
    b.ne JIT_X

ST gobj_mod                             // module variable at byte offset H0 must be the object HQ
    ldr x0, [x22, :lo12:H0+8]
    LDI64 1, HQ
    cmp x0, x1
    b.ne JIT_X

ST gi53                                 // int slot H0 must be within +-2^53 (exactly representable as a double)
    ldr x0, [x20, :lo12:H0+8]
    asr x0, x0, #53
    add x0, x0, #1
    cmp x0, #1
    b.hi JIT_X

// ---- moves ------------------------------------------------------------------------------------------------
ST mov                                  // slot H0 <- slot H1
    ldr x0, [x20, :lo12:H1]
    ldr x1, [x20, :lo12:H1+8]
    str x0, [x20, :lo12:H0]
    str x1, [x20, :lo12:H0+8]

ST movk                                 // slot H0 <- constant H1
    ldr x0, [x21, :lo12:H1]
    ldr x1, [x21, :lo12:H1+8]
    str x0, [x20, :lo12:H0]
    str x1, [x20, :lo12:H0+8]

ST ldmod                                // slot H0 <- module variable at byte offset H2
    ldr x0, [x22, :lo12:H2]
    ldr x1, [x22, :lo12:H2+8]
    str x0, [x20, :lo12:H0]
    str x1, [x20, :lo12:H0+8]

ST stmod                                // module variable at byte offset H0 <- slot H2
    ldr x0, [x20, :lo12:H2]
    ldr x1, [x20, :lo12:H2+8]
    str x0, [x22, :lo12:H0]
    str x1, [x22, :lo12:H0+8]

// ---- integer arithmetic: dst H0, a H1, b H2.  forms: rr slot/slot, rk slot/const, kr const/slot; _n: the destination already holds an int tag
.macro IARITH_FORM nm, form, ba, bb, tag
    ST i\nm\()_\form
    ldr x0, [\ba, :lo12:H1+8]
    ldr x1, [\bb, :lo12:H2+8]
    IOP_\nm
.if \tag
    SETT H0, T_INT
.endif
    str x0, [x20, :lo12:H0+8]
.endm
.macro IOP_add
    adds x0, x0, x1
    b.vs JIT_X
.endm
.macro IOP_sub
    subs x0, x0, x1
    b.vs JIT_X
.endm
.macro IOP_mul
    mul x2, x0, x1
    smulh x3, x0, x1
    cmp x3, x2, asr #63
    b.ne JIT_X
    mov x0, x2
.endm
.macro IARITH nm
    IARITH_FORM \nm, rr, x20, x20, 1
    IARITH_FORM \nm, rk, x20, x21, 1
    IARITH_FORM \nm, kr, x21, x20, 1
    IARITH_FORM \nm, rr_n, x20, x20, 0
    IARITH_FORM \nm, rk_n, x20, x21, 0
    IARITH_FORM \nm, kr_n, x21, x20, 0
.endm
IARITH add
IARITH sub
IARITH mul

// bitwise operations and shifts (a count outside 0 .. 63 leaves to the interpreter)
.macro IBIT_FORM nm, form, ba, bb
    ST ib\nm\()_\form
    ldr x0, [\ba, :lo12:H1+8]
    ldr x1, [\bb, :lo12:H2+8]
    IBOP_\nm
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
.endm
.macro IBOP_and
    and x0, x0, x1
.endm
.macro IBOP_or
    orr x0, x0, x1
.endm
.macro IBOP_xor
    eor x0, x0, x1
.endm
.macro IBOP_shl
    cmp x1, #63
    b.hi JIT_X
    lsl x0, x0, x1
.endm
.macro IBOP_sar
    cmp x1, #63
    b.hi JIT_X
    asr x0, x0, x1
.endm
.macro IBIT nm
    IBIT_FORM \nm, rr, x20, x20
    IBIT_FORM \nm, rk, x20, x21
    IBIT_FORM \nm, kr, x21, x20
.endm
IBIT and
IBIT or
IBIT xor
IBIT shl
IBIT sar

ST ineg
    ldr x0, [x20, :lo12:H1+8]
    negs x0, x0
    b.vs JIT_X
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
ST ibnot
    ldr x0, [x20, :lo12:H1+8]
    mvn x0, x0
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
ST fneg
    ldr x0, [x20, :lo12:H1+8]
    eor x0, x0, #0x8000000000000000
    SETT H0, T_FLOAT
    str x0, [x20, :lo12:H0+8]

// floor division and modulo of ints: divisor 0 and -1 leave to the interpreter
.macro IDM_LOAD ba, bb
    ldr x0, [\ba, :lo12:H1+8]
    ldr x1, [\bb, :lo12:H2+8]
    cbz x1, JIT_X
    cmn x1, #1
    b.eq JIT_X
    sdiv x2, x0, x1                     // truncating quotient
    msub x3, x2, x1, x0                 // remainder (sign of the dividend)
.endm
.macro IFDIV_TAIL                       // x2 = quotient, x3 = remainder, x1 = divisor
    cbz x3, 1f
    eor x4, x3, x1
    tbz x4, #63, 1f
    sub x2, x2, #1
1:  SETT H0, T_INT
    str x2, [x20, :lo12:H0+8]
.endm
.macro IMOD_TAIL
    cbz x3, 1f
    eor x4, x3, x1
    tbz x4, #63, 1f
    add x3, x3, x1
1:  SETT H0, T_INT
    str x3, [x20, :lo12:H0+8]
.endm
ST ifdiv_rr
    IDM_LOAD x20, x20
    IFDIV_TAIL
ST ifdiv_rk
    IDM_LOAD x20, x21
    IFDIV_TAIL
ST ifdiv_kr
    IDM_LOAD x21, x20
    IFDIV_TAIL
ST imod_rr
    IDM_LOAD x20, x20
    IMOD_TAIL
ST imod_rk
    IDM_LOAD x20, x21
    IMOD_TAIL
ST imod_kr
    IDM_LOAD x21, x20
    IMOD_TAIL

// x % c and x // c for a constant c > 0 that is not a power of two: multiply by the reciprocal (H2 = c, H3 = shift, HQ = magic); negative x divides
ST imod_m
    ldr x8, [x20, :lo12:H1+8]
    LDI32 10, H2
    tbnz x8, #63, 2f
    LDI64 0, HQ
    umulh x9, x8, x0
    sub x11, x8, x9
    lsr x11, x11, #1
    add x11, x11, x9
    LDU32 12, H3
    lsr x11, x11, x12
    msub x8, x11, x10, x8
    b 3f
2:  sdiv x9, x8, x10
    msub x8, x9, x10, x8
    cbz x8, 3f
    add x8, x8, x10
3:  SETT H0, T_INT
    str x8, [x20, :lo12:H0+8]

ST ifdiv_m
    ldr x8, [x20, :lo12:H1+8]
    LDI32 10, H2
    tbnz x8, #63, 2f
    LDI64 0, HQ
    umulh x9, x8, x0
    sub x11, x8, x9
    lsr x11, x11, #1
    add x11, x11, x9
    LDU32 12, H3
    lsr x11, x11, x12
    b 3f
2:  sdiv x11, x8, x10
    msub x9, x11, x10, x8
    cbz x9, 3f
    sub x11, x11, #1
3:  SETT H0, T_INT
    str x11, [x20, :lo12:H0+8]

// x % 2^k (H2 = 2^k - 1), x // 2^k (H2 = k): an arithmetic mask / shift is the floor semantics
ST imod_p2
    ldr x0, [x20, :lo12:H1+8]
    LDI32 1, H2
    and x0, x0, x1
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
ST ifdiv_p2
    ldr x0, [x20, :lo12:H1+8]
    LDU32 1, H2
    asr x0, x0, x1
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]

// ---- floats: operand types f/i (an int operand is converted), forms rr rk kr ------------------------------------------
.macro LDF d, t, hole, b
.ifc \t,f
    ldr \d, [\b, :lo12:\hole+8]
.else
    ldr x9, [\b, :lo12:\hole+8]
    scvtf \d, x9
.endif
.endm
.macro FARITH nm, insn, ta, fa, ba, tb, fb, bb
    ST f\nm\()_\ta\tb\()_\fa\fb
    LDF d0, \ta, H1, \ba
    LDF d1, \tb, H2, \bb
    \insn d0, d0, d1
    SETT H0, T_FLOAT
    str d0, [x20, :lo12:H0+8]
    ST f\nm\()_\ta\tb\()_\fa\fb\()_n
    LDF d0, \ta, H1, \ba
    LDF d1, \tb, H2, \bb
    \insn d0, d0, d1
    str d0, [x20, :lo12:H0+8]
.endm
.macro FARITH_ALL nm, insn
    FARITH \nm,\insn,f,r,x20,f,r,x20
    FARITH \nm,\insn,f,r,x20,f,k,x21
    FARITH \nm,\insn,f,k,x21,f,r,x20
    FARITH \nm,\insn,f,r,x20,i,r,x20
    FARITH \nm,\insn,f,r,x20,i,k,x21
    FARITH \nm,\insn,f,k,x21,i,r,x20
    FARITH \nm,\insn,i,r,x20,f,r,x20
    FARITH \nm,\insn,i,r,x20,f,k,x21
    FARITH \nm,\insn,i,k,x21,f,r,x20
.endm
FARITH_ALL add, fadd
FARITH_ALL sub, fsub
FARITH_ALL mul, fmul

// division: a zero divisor (or NaN) is left to the interpreter (it raises the error)
.macro FDIV ta, fa, ba, tb, fb, bb
    ST fdiv_\ta\tb\()_\fa\fb
    LDF d0, \ta, H1, \ba
    LDF d1, \tb, H2, \bb
    fcmp d1, #0.0
    b.eq JIT_X
    fdiv d0, d0, d1
    SETT H0, T_FLOAT
    str d0, [x20, :lo12:H0+8]
    ST fdiv_\ta\tb\()_\fa\fb\()_n
    LDF d0, \ta, H1, \ba
    LDF d1, \tb, H2, \bb
    fcmp d1, #0.0
    b.eq JIT_X
    fdiv d0, d0, d1
    str d0, [x20, :lo12:H0+8]
.endm
FDIV f,r,x20,f,r,x20
FDIV f,r,x20,f,k,x21
FDIV f,k,x21,f,r,x20
FDIV f,r,x20,i,r,x20
FDIV f,r,x20,i,k,x21
FDIV f,k,x21,i,r,x20
FDIV i,r,x20,f,r,x20
FDIV i,r,x20,f,k,x21
FDIV i,k,x21,f,r,x20

ST idiv_rr                              // int / int gives a float; a zero divisor is the interpreter's
    ldr x1, [x20, :lo12:H2+8]
    cbz x1, JIT_X
    ldr x0, [x20, :lo12:H1+8]
    scvtf d0, x0
    scvtf d1, x1
    fdiv d0, d0, d1
    SETT H0, T_FLOAT
    str d0, [x20, :lo12:H0+8]

ST i2f                                  // slot H0 <- float(int slot H1)
    ldr x0, [x20, :lo12:H1+8]
    scvtf d0, x0
    SETT H0, T_FLOAT
    str d0, [x20, :lo12:H0+8]

ST fsqrt                                // a negative x is an error left to the interpreter
    ldr d0, [x20, :lo12:H1+8]
    fcmp d0, #0.0
    b.mi JIT_X
    fsqrt d0, d0
    SETT H0, T_FLOAT
    str d0, [x20, :lo12:H0+8]

// ---- conditional branches (taken to JIT_T): ints ----------------------------------------------------------------
.macro IBR nm, cc, ncc
    ST ibr_\nm\()_t_rr
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H2+8]
    cmp x0, x1
    b.\cc JIT_T
    ST ibr_\nm\()_t_rk
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x21, :lo12:H2+8]
    cmp x0, x1
    b.\cc JIT_T
    ST ibr_\nm\()_f_rr
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H2+8]
    cmp x0, x1
    b.\ncc JIT_T
    ST ibr_\nm\()_f_rk
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x21, :lo12:H2+8]
    cmp x0, x1
    b.\ncc JIT_T
.endm
IBR lt, lt, ge
IBR le, le, gt
IBR gt, gt, le
IBR ge, ge, lt
IBR eq, eq, ne
IBR ne, ne, eq

// ---- conditional branches: floats (NaN compares false except !=) ------------------------------------------------
.macro FBRANCH cond, pol, ta, fa, ba, tb, fb, bb, cc
    ST fbr_\cond\()_\pol\()_\ta\tb\()_\fa\fb
    LDF d0, \ta, H1, \ba
    LDF d1, \tb, H2, \bb
    fcmp d0, d1
    b.\cc JIT_T
.endm
.macro FBRANCH_COND cond, cct, ccf
    FBRANCH \cond,t,f,r,x20,f,r,x20,\cct
    FBRANCH \cond,t,f,r,x20,f,k,x21,\cct
    FBRANCH \cond,t,f,r,x20,i,r,x20,\cct
    FBRANCH \cond,t,f,r,x20,i,k,x21,\cct
    FBRANCH \cond,t,i,r,x20,f,r,x20,\cct
    FBRANCH \cond,t,i,r,x20,f,k,x21,\cct
    FBRANCH \cond,f,f,r,x20,f,r,x20,\ccf
    FBRANCH \cond,f,f,r,x20,f,k,x21,\ccf
    FBRANCH \cond,f,f,r,x20,i,r,x20,\ccf
    FBRANCH \cond,f,f,r,x20,i,k,x21,\ccf
    FBRANCH \cond,f,i,r,x20,f,r,x20,\ccf
    FBRANCH \cond,f,i,r,x20,f,k,x21,\ccf
.endm
FBRANCH_COND lt, mi, pl
FBRANCH_COND le, ls, hi
FBRANCH_COND gt, gt, le
FBRANCH_COND ge, ge, lt
FBRANCH_COND eq, eq, ne
FBRANCH_COND ne, ne, eq

// a bool slot H1: branch when it is true (t) / false (f)
ST bbr_t
    ldr w0, [x20, :lo12:H1+8]
    cbnz w0, JIT_T
ST bbr_f
    ldr w0, [x20, :lo12:H1+8]
    cbz w0, JIT_T

// generic truthiness of slot H1: nil and false are false, everything else is true
ST tbr_t                                // jump when true
    ldr x0, [x20, :lo12:H1]
    cbz x0, 1f
    cmp x0, #T_BOOL
    b.ne JIT_T
    ldr w1, [x20, :lo12:H1+8]
    cbnz w1, JIT_T
1:
ST tbr_f                                // jump when false
    ldr x0, [x20, :lo12:H1]
    cbz x0, JIT_T
    cmp x0, #T_BOOL
    b.ne 1f
    ldr w1, [x20, :lo12:H1+8]
    cbz w1, JIT_T
1:

ST nilbr_t                              // the tag is 0 for nil
    ldr x0, [x20, :lo12:H1]
    cbz x0, JIT_T
ST nilbr_f
    ldr x0, [x20, :lo12:H1]
    cbnz x0, JIT_T

// ---- ranges ---------------------------------------------------------------------------------------------------
// for-range step: state slots H1 (current), H1+16 (stop), H1+32 (step), all ints. Done -> JIT_T, else the current value goes to slot H0.
ST range_next
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H1+24]
    ldr x8, [x20, :lo12:H1+40]
    cmp x8, #0
    b.le 2f
    cmp x0, x1
    b.ge JIT_T
    b 3f
2:  cmp x0, x1
    b.le JIT_T
3:  SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
    adds x0, x0, x8
    csel x0, x1, x0, vs                 // an overflowing advance clamps to stop
    str x0, [x20, :lo12:H1+8]

ST range_up                             // constant step > 0 (H2)
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H1+24]
    cmp x0, x1
    b.ge JIT_T
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
    LDI32 2, H2
    adds x0, x0, x2
    csel x0, x1, x0, vs
    str x0, [x20, :lo12:H1+8]

ST range_dn                             // constant step < 0 (H2)
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H1+24]
    cmp x0, x1
    b.le JIT_T
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
    LDI32 2, H2
    adds x0, x0, x2
    csel x0, x1, x0, vs
    str x0, [x20, :lo12:H1+8]

ST range_up1
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H1+24]
    cmp x0, x1
    b.ge JIT_T
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
    add x0, x0, #1
    str x0, [x20, :lo12:H1+8]

ST range_dn1
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H1+24]
    cmp x0, x1
    b.le JIT_T
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]
    sub x0, x0, #1
    str x0, [x20, :lo12:H1+8]

// ---- arrays: H3 = offsetof(SArray, len), H4 = offsetof(SArray, data) --------------------------------------------
.macro ELEM_LOAD                        // x0 = array, x1 = index (in range): x2 = type word, x3 = payload of the element
    ldrb w2, [x0, #L_OBJ_XT]            // packed array (note T_BOOL / T_INT / T_FLOAT): 8-byte payloads, the note is the type
    ldr x0, [x0, :lo12:H4]
    sub w4, w2, #1
    cmp w4, #2
    b.ls 1f
    add x4, x0, x1, lsl #4
    ldr x2, [x4]
    ldr x3, [x4, #8]
    b 2f
1:  ldr x3, [x0, x1, lsl #3]
2:
.endm
ST getidx_rr                            // slot H0 <- array(H1)[int(H2)]; out of range -> interpreter (raises)
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H2+8]
    ldr x5, [x0, :lo12:H3]
    cmp x1, x5
    b.hs JIT_X
    ELEM_LOAD
    str x2, [x20, :lo12:H0]
    str x3, [x20, :lo12:H0+8]

ST getidx_rk                            // index is the constant H2
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x21, :lo12:H2+8]
    ldr x5, [x0, :lo12:H3]
    cmp x1, x5
    b.hs JIT_X
    ELEM_LOAD
    str x2, [x20, :lo12:H0]
    str x3, [x20, :lo12:H0+8]

// stores: only into a packed array holding the value's own type (a boxed array, or a value of another type, is the interpreter's: it
// needs the write barrier / unpacks)
.macro SETIDX_BODY bv                   // x0 = array, x1 = index, value slot at \bv + H2
    ldr x5, [x0, :lo12:H3]
    cmp x1, x5
    b.hs JIT_X
    ldr x6, [\bv, :lo12:H2]             // the value's type word
    ldrb w7, [x0, #L_OBJ_XT]
    sub w8, w7, #1
    cmp w8, #2
    b.hi JIT_X                          // a boxed array
    cmp w7, w6
    b.ne JIT_X                          // a different type
    ldr x0, [x0, :lo12:H4]
    ldr x3, [\bv, :lo12:H2+8]
    cmp w6, #T_BOOL
    b.ne 1f
    cmp w3, #0
    cset x3, ne
1:  str x3, [x0, x1, lsl #3]
.endm
ST setidx_rr                            // array(H0)[int(H1)] <- slot H2
    ldr x0, [x20, :lo12:H0+8]
    ldr x1, [x20, :lo12:H1+8]
    SETIDX_BODY x20
ST setidx_rk                            // value is the constant H2
    ldr x0, [x20, :lo12:H0+8]
    ldr x1, [x20, :lo12:H1+8]
    SETIDX_BODY x21

ST alen                                 // slot H0 <- len(array(H1))
    ldr x0, [x20, :lo12:H1+8]
    ldr x0, [x0, :lo12:H3]
    SETT H0, T_INT
    str x0, [x20, :lo12:H0+8]

// for x in array: state slots H1 (the array), H1+16 (next index, an int). Done -> JIT_T, else the element goes to slot H0.
ST arr_next
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H1+24]
    ldr x5, [x0, :lo12:H3]
    cmp x1, x5
    b.ge JIT_T
    add x6, x1, #1
    str x6, [x20, :lo12:H1+24]
    ELEM_LOAD
    str x2, [x20, :lo12:H0]
    str x3, [x20, :lo12:H0+8]

ST arr_next2
    ldr x0, [x20, :lo12:H1+8]
    ldr x1, [x20, :lo12:H1+24]
    ldr x5, [x0, :lo12:H3]
    cmp x1, x5
    b.ge JIT_T
    add x6, x1, #1
    str x6, [x20, :lo12:H1+24]
    SETT H0, T_INT
    str x1, [x20, :lo12:H0+8]
    ELEM_LOAD
    str x2, [x20, :lo12:H0+16]
    str x3, [x20, :lo12:H0+24]

// ---- C helpers (the interpreter's own fast paths): each returns 0 when it does not handle the case, and the instruction then runs in the interpreter
ST hget                                 // slot H0 <- HQ(vm, slot H1, slot H2): table / string / array element
    mov x0, x19
    LDI32 1, H1
    add x1, x20, x1
    LDI32 2, H2
    add x2, x20, x2
    LDI32 3, H0
    add x3, x20, x3
    LDI64 16, HQ
    blr x16
    cbz w0, JIT_X

ST hset                                 // HQ(vm, slot H1, slot H2, slot H3) stores; H0 = the stack top published to the collector
    LDI32 4, H0
    add x4, x20, x4
    str x4, [x19, #L_VM_SP]
    mov x0, x19
    LDI32 1, H1
    add x1, x20, x1
    LDI32 2, H2
    add x2, x20, x2
    LDI32 3, H3
    add x3, x20, x3
    LDI64 16, HQ
    blr x16
    cbz w0, JIT_X
