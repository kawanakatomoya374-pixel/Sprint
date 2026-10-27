/* Test library for the Sprint ffi module (built by `make` into build/libctest.so). */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

int add_i32(int a, int b) { return a + b; }
int64_t mul_i64(int64_t a, int64_t b) { return a * b; }
double hyp2(double a, double b) { return a * a + b * b; }
float scale_f(float v, float k) { return v * k; }
uint8_t u8_inc(uint8_t v) { return (uint8_t)(v + 1); }
int8_t i8_neg(int8_t v) { return (int8_t)-v; }
uint32_t u32_max(void) { return 0xFFFFFFFFu; }
uint64_t u64_big(void) { return 0xFFFFFFFFFFFFFFFFull; }
int sum6(int a, int b, int c, int d, int e, int f) { return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f; }
double mix(int a, double b, int c, double d) { return a * 1.0 + b * 10.0 + c * 100.0 + d * 1000.0; }
double sum8d(double a, double b, double c, double d, double e, double f, double g, double h) { return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h; }
const char *greeting(void) { return "hello from C"; }
size_t slen(const char *s) { return strlen(s); }
char *dup_upper(const char *s) { size_t n = strlen(s); char *r = malloc(n + 1); for (size_t i = 0; i <= n; i++) r[i] = (char)toupper((unsigned char)s[i]); return r; }
void free_str(char *s) { free(s); }
const char *null_str(void) { return NULL; }

struct Point { int x; int y; };
struct Rec { char tag; double w; short s[3]; struct Point p; const char *name; };
typedef struct { uint8_t r, g, b, a; } Color;

void pt_move(struct Point *p, int dx, int dy) { p->x += dx; p->y += dy; }
int pt_dist2(const struct Point *a, const struct Point *b) { int dx = a->x - b->x, dy = a->y - b->y; return dx * dx + dy * dy; }
struct Point *pt_make(int x, int y) { struct Point *p = malloc(sizeof *p); p->x = x; p->y = y; return p; }
void pt_free(struct Point *p) { free(p); }
int rec_size(void) { return (int)sizeof(struct Rec); }
int rec_off_p(void) { return (int)offsetof(struct Rec, p); }
void rec_fill(struct Rec *r) { r->tag = 'R'; r->w = 2.5; r->s[0] = 1; r->s[1] = -2; r->s[2] = 3; r->p.x = 7; r->p.y = 8; r->name = "rec"; }
uint32_t color_pack(const Color *c) { return ((uint32_t)c->r << 24) | ((uint32_t)c->g << 16) | ((uint32_t)c->b << 8) | c->a; }

double dot(const double *a, const double *b, int n) { double s = 0; for (int i = 0; i < n; i++) s += a[i] * b[i]; return s; }
void fill_squares(int *out, int n) { for (int i = 0; i < n; i++) out[i] = i * i; }
void set_out(int *a, double *b) { *a = 41; *b = 0.5; }

int apply_i(int (*cb)(int), int v) { return cb(v) + 1; }
double apply_d(double (*cb)(double, double), double a, double b) { return cb(a, b) * 2; }
float apply_f(float (*cb)(float), float v) { return cb(v); }
int each_str(const char *const *items, int n, int (*cb)(const char *, int)) { int s = 0; for (int i = 0; i < n; i++) s += cb(items[i], i); return s; }
void sort_ints(int *a, int n, int (*cmp)(const void *, const void *)) { qsort(a, (size_t)n, sizeof *a, cmp); }

/* structs by value (System V classification: INTEGER / SSE eightbytes, and a hidden pointer above 16 bytes) */
struct V2 { double x, y; };
struct IP { int a; int b; };
struct Mix { int64_t n; double d; };
struct Small { char c; short s; };
struct F3 { float a, b, c; };
struct Big { int64_t a, b, c; };
struct Nest { struct IP p; float x, y; };
double v2_len2(struct V2 v) { return v.x * v.x + v.y * v.y; }
struct V2 v2_add(struct V2 a, struct V2 b) { struct V2 r = {a.x + b.x, a.y + b.y}; return r; }
int ip_sum(struct IP p) { return p.a * 10 + p.b; }
struct IP ip_swap(struct IP p) { struct IP r = {p.b, p.a}; return r; }
double mix_val(struct Mix m, int k) { return (double)m.n * k + m.d; }
struct Mix mix_make(int64_t n, double d) { struct Mix m = {n, d}; return m; }
struct Small small_make(int c, int s) { struct Small r = {(char)c, (short)s}; return r; }
int small_sum(struct Small s) { return s.c + s.s; }
float f3_sum(struct F3 f) { return f.a + f.b + f.c; }
struct F3 f3_make(float a, float b, float c) { struct F3 r = {a, b, c}; return r; }
struct Big big_make(int64_t a, int64_t b, int64_t c) { struct Big r = {a, b, c}; return r; }
int64_t big_sum(const struct Big *b) { return b->a + b->b + b->c; }
double nest_val(struct Nest n) { return n.p.a + n.p.b * 2 + n.x * 3.0 + n.y * 4.0; }
