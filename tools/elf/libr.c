static int f0(void) { return 0; } static int f1(void) { return 1; } static int f2(void) { return 2; }
static int f3(void) { return 3; } static int f4(void) { return 4; } static int f5(void) { return 5; }
static int f6(void) { return 6; } static int f7(void) { return 7; } static int f8(void) { return 8; }
int (*r_table[9])(void) = {f0, f1, f2, f3, f4, f5, f6, f7, f8};
int r_call(int i) { return r_table[i](); }
