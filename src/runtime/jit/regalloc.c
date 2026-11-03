#include "internal.h"

/* rbp is not a frame pointer in trace code (the prologue saves it, the epilogue restores it, nothing addresses through it) */
const uint8_t JIT_TRACE_GPR_POOL[11] = {0U, 1U, 2U, 3U, 6U, 7U, 8U, 9U, 14U, 15U, 5U};

void jit_ra_init(JitRegBank *bank, const uint8_t *pool, size_t count) {
    bank->pool = pool;
    bank->count = count;
    bank->used = 0U;
    for (size_t i = 0U; i < sizeof bank->owner / sizeof bank->owner[0]; i++) bank->owner[i] = -1;
}

void jit_ra_reset(JitRegBank *bank) {
    bank->used = 0U;
    for (size_t i = 0U; i < sizeof bank->owner / sizeof bank->owner[0]; i++) bank->owner[i] = -1;
}

uint32_t jit_ra_mask(const JitRegBank *bank) {
    return bank->used;
}

int jit_ra_alloc(JitRegBank *bank, int32_t owner) {
    if (bank == NULL || bank->pool == NULL) return -1;
    for (size_t i = 0U; i < bank->count; i++) {
        uint8_t reg = bank->pool[i];
        if (reg < 32U && (bank->used & (UINT32_C(1) << reg)) == 0U) {
            bank->used |= UINT32_C(1) << reg;
            bank->owner[reg] = owner;
            return (int)reg;
        }
    }
    return -1;
}

int jit_ra_reassign(JitRegBank *bank, int reg, int32_t owner) {
    if (bank == NULL || reg < 0 || reg >= 32 ||
        (bank->used & (UINT32_C(1) << (unsigned)reg)) == 0U) return 0;
    bank->owner[reg] = owner;
    return 1;
}

int32_t jit_ra_owner(const JitRegBank *bank, int reg) {
    return bank != NULL && reg >= 0 && reg < 32 ? bank->owner[reg] : -1;
}

void jit_ra_release(JitRegBank *bank, int reg) {
    if (bank != NULL && reg >= 0 && reg < 32) {
        bank->used &= ~(UINT32_C(1) << (unsigned)reg);
        bank->owner[reg] = -1;
    }
}
