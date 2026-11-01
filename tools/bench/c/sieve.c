#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

int main(void){ int64_t n=N(5000000); char*f=malloc((size_t)n+1); memset(f,1,(size_t)n+1); int64_t c=0;
 for(int64_t i=2;i<=n;i++) if(f[i]){ c++; for(int64_t j=i*i;j<=n;j+=i) f[j]=0; }
 printf("%lld\n",(long long)c); free(f); return 0; }
