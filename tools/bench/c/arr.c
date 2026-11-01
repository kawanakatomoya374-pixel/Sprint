#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

int main(void){ int64_t n=N(3000000); int64_t*a=NULL; size_t cap=0,len=0;
 for(int64_t i=0;i<n;i++){ if(len==cap){cap=cap?cap*2:8;a=realloc(a,cap*sizeof*a);} a[len++]=i*2; }
 int64_t t=0; for(size_t i=0;i<len;i++)t+=a[i]; for(size_t i=0;i<len;i++)t+=a[i];
 printf("%lld\n",(long long)t); return 0; }
