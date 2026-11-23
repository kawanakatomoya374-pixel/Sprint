extern int a_run(int);
extern int a_local(void);
int counter_copy_user;
int main_run(int x) { return a_run(x) * 2; }
void _start(void) {}
