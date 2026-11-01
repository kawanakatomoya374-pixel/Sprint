#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

int main(void){ int64_t s=0, n=N(100000000); for(int64_t i=0;i<n;i++) s+=i%7; printf("%lld\n",(long long)s); return 0; }
