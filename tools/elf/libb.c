int b_counter = 100;
int b_table[4] = {1, 2, 3, 4};
int b_add(int a, int b) { return a + b; }
int (*b_fp)(int, int) = b_add;
__thread int b_tls = 7;
__thread char b_tls2[24] = {1, 2, 3};
int b_tls_get(void) { return b_tls; }
int b_get_counter(void) { return b_counter; }
void b_bump(void) { b_counter++; }
