/* Ordered tables (insertion-ordered open hashing, SPEC 8.4). */
#include "value_int.h"

/* ---------------------------------------------------------------- */
/* tables                                                            */
/* ---------------------------------------------------------------- */
static uint64_t mix64(uint64_t x) {
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ull;
    x ^= x >> 27; x *= 0x94d049bb133111ebull;
    x ^= x >> 31;
    return x;
}

/* integer keys: one multiply, the high half folded into the low bits that pick the slot */
static inline uint64_t hash_int(int64_t i) {
    uint64_t h = (uint64_t)i * 0x9e3779b97f4a7c15ull;
    return h ^ (h >> 32);
}

static uint64_t hash_value(SpValue k) {
    switch (k.type) {
    case T_INT: return hash_int(k.as.i);
    case T_FLOAT: { uint64_t b; memcpy(&b, &k.as.f, 8); return mix64(b); }
    case T_BOOL: return k.as.b ? 0x9e3779b97f4a7c15ull : 0x7f4a7c159e3779b9ull;
    case T_STRING: return mix64(str_hash(AS_STR(k)));
    default: return mix64(k.as.o->id * 0x9e3779b97f4a7c15ull);
    }
}

static int key_eq(SpValue a, SpValue b) {
    if (a.type != b.type) return 0;
    switch (a.type) {
    case T_INT: return a.as.i == b.as.i;
    case T_FLOAT: return sp_feq(a.as.f, b.as.f);
    case T_BOOL: return a.as.b == b.as.b;
    case T_STRING: {
        SString *x = AS_STR(a), *y = AS_STR(b);
        return x == y || (x->len == y->len && str_hash(x) == str_hash(y) && memcmp(x->dp, y->dp, x->len) == 0);
    }
    default: return a.as.o == b.as.o;
    }
}

/* normalise a key for lookup; returns 0 ok, 1 error (pending) */
static int norm_key(VM *vm, SpValue *k) {
    if (k->type == T_NIL) return vm_set_error(vm, E_TYPE, "table key cannot be nil");
    if (k->type == T_FLOAT) {
        double f = k->as.f;
        if (isnan(f)) return vm_set_error(vm, E_VALUE, "table key cannot be NaN");
        if (sp_feq(f, floor(f)) && f >= -9223372036854775808.0 && f < 9223372036854775808.0)
            *k = v_int((int64_t)f);
    }
    return 0;
}

static void t_rebuild(VM *vm, STable *t, int64_t newcap);
STable *vm_new_table(VM *vm, int64_t cap) {
    STable *t = new_obj(vm, sizeof *t, T_TABLE, 1);
    if (cap > 0) t_rebuild(vm, t, cap);   /* exactly the entries a literal holds */
    return t;
}

/* A table of at most TABLE_SMALL entries has no hash index: its entries are scanned (cheaper than hashing, and the index array is saved) */
#define TABLE_SMALL 8
static int64_t t_find(const STable *t, SpValue k, uint64_t h, int64_t *slot_out) {
    if (!t->idx) {
        for (int64_t e = 0; e < t->nent; e++) if (key_eq(t->ents[e].key, k)) return e;
        return -1;
    }
    uint64_t mask = (uint64_t)t->idxcap - 1;
    uint64_t i = h & mask;
    for (;;) {
        const int32_t e = t->idx[i];
        if (e == -1) return -1;
        if (e >= 0 && key_eq(t->ents[e].key, k)) {
            if (slot_out) *slot_out = (int64_t)i;
            return e;
        }
        i = (i + 1) & mask;
    }
}

/* String-key lookup avoids the generic key_eq path. In particular, long strings
 * can have an uncached hash: compute it once for the probe and compare stored
 * strings by cached hash/length/bytes instead of hashing them again per probe. */
static int64_t t_find_sstr(const STable *t, const SString *key, uint32_t h32,
                           int64_t *slot_out, uint64_t *hash_out) {
    uint64_t h = mix64(h32);
    if (hash_out) *hash_out = h;
    if (!t->idx) {
        for (int64_t e = 0; e < t->nent; e++) {
            const TEntry *te = &t->ents[e];
            if (te->key.type != T_STRING) continue;
            const SString *ks = AS_STR(te->key);
            if (ks == key || ((ks->hash == h32 || !ks->hash) && ks->len == key->len && memcmp(ks->dp, key->dp, key->len) == 0)) return e;
        }
        return -1;
    }
    uint64_t mask = (uint64_t)t->idxcap - 1;
    uint64_t i = h & mask;
    for (;;) {
        const int32_t e = t->idx[i];
        if (e == -1) return -1;
        if (e >= 0) {
            const TEntry *te = &t->ents[e];
            if (te->key.type == T_STRING) {
                const SString *ks = AS_STR(te->key);
                if (ks == key || ((ks->hash == h32 || !ks->hash) &&
                                  ks->len == key->len &&
                                  memcmp(ks->dp, key->dp, key->len) == 0)) {
                    if (slot_out) *slot_out = (int64_t)i;
                    return e;
                }
            }
        }
        i = (i + 1) & mask;
    }
}

/* lookup of an integer key: no generic equality call */
static inline int64_t t_find_int(const STable *t, int64_t k, uint64_t h, int64_t *slot_out) {
    if (!t->idx) {
        for (int64_t e = 0; e < t->nent; e++) if (t->ents[e].key.type == T_INT && t->ents[e].key.as.i == k) return e;
        return -1;
    }
    const uint64_t mask = (uint64_t)t->idxcap - 1;
    uint64_t i = h & mask;
    for (;;) {
        const int32_t e = t->idx[i];
        if (e == -1) return -1;
        if (e >= 0) {
            const TEntry *te = &t->ents[e];
            if (te->key.type == T_INT && te->key.as.i == k) {
                if (slot_out) *slot_out = (int64_t)i;
                return e;
            }
        }
        i = (i + 1) & mask;
    }
}

static void t_idx_insert_h(STable *t, int32_t e, uint64_t h) {
    uint64_t mask = (uint64_t)t->idxcap - 1;
    uint64_t i = h & mask;
    while (t->idx[i] >= 0) i = (i + 1) & mask;
    t->idx[i] = e;
}

static void t_idx_insert(STable *t, int32_t e) {
    t_idx_insert_h(t, e, hash_value(t->ents[e].key));
}

static void t_rebuild(VM *vm, STable *t, int64_t newcap) {
    if ((uint64_t)newcap > vm->lim.max_table_entries) vm_fatal(vm, RS_MEMORY, "table size limit exceeded");
    int64_t icap = 0;
    if (newcap > TABLE_SMALL) { icap = 8; while (icap < newcap * 2) icap <<= 1; }
    int32_t *ni = icap ? vm_mem(vm, NULL, 0, (size_t)icap * sizeof(int32_t)) : NULL;
    int64_t n = 0;
    if (t->ents && t->nent == t->count && newcap >= t->cap) {
        /* no dead entries: grow the entry array where it is (no second copy of a big table alive at once) */
        t->ents = vm_mem(vm, t->ents, (size_t)t->cap * sizeof(TEntry), (size_t)newcap * sizeof(TEntry));
        n = t->nent;
    } else {
        TEntry *ne = vm_mem(vm, NULL, 0, (size_t)newcap * sizeof(TEntry));
        for (int64_t i = 0; i < t->nent; i++)
            if (t->ents[i].key.type != T_NIL) ne[n++] = t->ents[i];
        if (t->ents) vm_mem(vm, t->ents, (size_t)t->cap * sizeof(TEntry), 0);
        t->ents = ne;
    }
    if (t->idx) vm_mem(vm, t->idx, (size_t)t->idxcap * sizeof(int32_t), 0);
    t->cap = newcap;
    t->nent = n;
    t->idx = ni;
    t->idxcap = icap;
    if (ni) {
        for (int64_t i = 0; i < icap; i++) ni[i] = -1;
        for (int64_t i = 0; i < n; i++) t_idx_insert(t, (int32_t)i);
    }
}

int table_reserve(VM *vm, STable *t, int64_t n) {
    if (n < t->count) n = t->count;
    if (n > t->cap || !t->ents) t_rebuild(vm, t, n < 4 ? 4 : n);
    return 0;
}

int table_get(VM *vm, STable *t, SpValue key, SpValue *out, int *found) {
    int64_t e;
    if (key.type == T_INT) {
        e = t_find_int(t, key.as.i, hash_int(key.as.i), NULL);
        if (e >= 0) { *out = t->ents[e].val; if (found) *found = 1; }
        else { *out = v_nil(); if (found) *found = 0; }
        return 0;
    }
    if (norm_key(vm, &key)) return 1;
    if (key.type == T_STRING) {
        SString *s = AS_STR(key);
        e = t_find_sstr(t, s, str_hash(s), NULL, NULL);
    } else {
        e = t_find(t, key, hash_value(key), NULL);
    }
    if (e >= 0) { *out = t->ents[e].val; if (found) *found = 1; }
    else { *out = v_nil(); if (found) *found = 0; }
    return 0;
}

/* Same as table_get_str for a key that is already an SString. */
int table_get_sstr(const STable *t, const SString *key, SpValue *out) {
    int64_t e = t_find_sstr(t, key, str_hash_peek(key), NULL, NULL);
    if (e < 0) return 0;
    if (out) *out = t->ents[e].val;
    return 1;
}
int64_t table_find_sstr(const STable *t, const SString *key) {
    return t_find_sstr(t, key, str_hash_peek(key), NULL, NULL);
}
int table_get_str(STable *t, const char *s, size_t len, SpValue *out) {
    if (!t->idx) {
        for (int64_t e = 0; e < t->nent; e++) {
            SpValue k = t->ents[e].key;
            if (k.type == T_STRING && AS_STR(k)->len == len && memcmp(AS_STR(k)->dp, s, len) == 0) { if (out) *out = t->ents[e].val; return 1; }
        }
        return 0;
    }
    uint32_t h32 = str_hash_calc(s, len);
    uint64_t h = mix64(h32);
    uint64_t mask = (uint64_t)t->idxcap - 1;
    uint64_t i = h & mask;
    for (;;) {
        int32_t e = t->idx[i];
        if (e == -1) return 0;
        if (e >= 0) {
            SpValue k = t->ents[e].key;
            if (k.type == T_STRING && (AS_STR(k)->hash == h32 || !AS_STR(k)->hash) && AS_STR(k)->len == len &&
                memcmp(AS_STR(k)->dp, s, len) == 0) {
                if (out) *out = t->ents[e].val;
                return 1;
            }
        }
        i = (i + 1) & mask;
    }
}

int table_set(VM *vm, STable *t, SpValue key, SpValue val) {
    int64_t slot = -1;
    uint64_t h;
    int64_t e;
    if (key.type == T_INT) {
        h = hash_int(key.as.i);
        e = t_find_int(t, key.as.i, h, &slot);
    } else if (norm_key(vm, &key)) {
        return 1;
    } else if (key.type == T_STRING) {
        SString *s = AS_STR(key);
        e = t_find_sstr(t, s, str_hash(s), &slot, &h);
    } else {
        h = hash_value(key);
        e = t_find(t, key, h, &slot);
    }
    if (val.type == T_NIL) { /* delete */
        if (e >= 0) {
            t->ents[e].key = v_nil();
            t->ents[e].val = v_nil();
            if (t->idx) t->idx[slot] = -2;
            t->count--;
            t->version++;
        }
        return 0;
    }
    if (e >= 0) { t->ents[e].val = val; return 0; }
    if (t->nent == t->cap) {
        int64_t nc = t->count * 2 > t->cap ? (t->cap ? t->cap * 2 : 4) : (t->cap ? t->cap : 4);
        t_rebuild(vm, t, nc);
    }
    t->ents[t->nent].key = key;
    t->ents[t->nent].val = val;
    if (t->idx) t_idx_insert_h(t, (int32_t)t->nent, h);
    t->nent++;
    t->count++;
    t->version++;
    return 0;
}

/* the pairs of a table literal (n <= TABLE_SMALL, a fresh table of capacity n): entries are appended directly, a repeated key overwrites
 * the earlier value. Returns 1 when a key needs the general path (nil, a float), 0 when done. */
int table_init_small(STable *t, const SpValue *kv, unsigned n) {
    if (n > TABLE_SMALL || t->idx != NULL || t->cap < (int64_t)n || t->nent != 0) return 1;
    for (unsigned i = 0; i < n; i++) {
        const SpValue k = kv[2 * i], v = kv[2 * i + 1];
        int64_t e;
        if (k.type == T_NIL || k.type == T_FLOAT || v.type == T_NIL) return 1;
        for (e = 0; e < t->nent; e++) {
            const SpValue ek = t->ents[e].key;
            if (ek.type != k.type) continue;
            if (k.type == T_STRING) {
                const SString *x = AS_STR(ek), *y = AS_STR(k);
                if (x == y || (x->len == y->len && memcmp(x->dp, y->dp, x->len) == 0)) break;
            } else if (key_eq(ek, k)) break;
        }
        if (e < t->nent) { t->ents[e].val = v; continue; }
        t->ents[t->nent].key = k;
        t->ents[t->nent].val = v;
        t->nent++;
        t->count++;
        t->version++;
    }
    return 0;
}

void table_set_str(VM *vm, STable *t, const char *s, size_t len, SpValue v) {
    SpValue k = v_obj(T_STRING, vm_new_string(vm, s, len));
    table_set(vm, t, k, v);
}

/* cursor iteration over live entries; returns next cursor or -1 at end */
int64_t table_next(STable *t, int64_t cursor, SpValue *k, SpValue *v) {
    while (cursor < t->nent) {
        if (t->ents[cursor].key.type != T_NIL) {
            if (k) *k = t->ents[cursor].key;
            if (v) *v = t->ents[cursor].val;
            return cursor + 1;
        }
        cursor++;
    }
    return -1;
}
