#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

typedef struct { int64_t n; } Cl;
static int64_t inc(Cl*c){ c->n+=1; return c->n; }
int main(void){ Cl c={0}; int64_t r=0, n=N(20000000); for(int64_t i=0;i<n;i++) r=inc(&c); printf("%lld\n",(long long)r); return 0; }
