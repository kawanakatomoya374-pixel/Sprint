#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

static int64_t steps(int64_t n){ int64_t c=0; while(n!=1){ if(n%2==0) n/=2; else n=3*n+1; c++; } return c; }
int main(void){ int64_t best=0, n=N(600000); for(int64_t i=1;i<n;i++){ int64_t s=steps(i); if(s>best) best=s; } printf("%lld\n",(long long)best); return 0; }
