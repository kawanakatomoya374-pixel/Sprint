#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

static int64_t fib(int64_t n){ return n < 2 ? n : fib(n-1) + fib(n-2); }
int main(void){ printf("%lld\n",(long long)fib(N(35))); return 0; }
