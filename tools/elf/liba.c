extern int b_counter;
extern int b_add(int, int);
extern void b_bump(void);
extern int (*b_fp)(int, int);
extern int b_table[4];
__attribute__((weak)) extern int missing_weak;
int a_run(int x) { b_bump(); return b_add(x, b_counter) + b_fp(1, 2); }
int *a_counter_ptr(void) { return &b_counter; }
int *a_table_ptr(void) { return b_table + 2; }
static int local = 5;
int a_local(void) { return local; }
int a_has_missing(void) { return &missing_weak != 0; }
static int impl(void) { return 42; }
static int (*resolve(void))(void) { return impl; }
int a_ifunc(void) __attribute__((ifunc("resolve")));
int a_call_ifunc(void) { return a_ifunc(); }
