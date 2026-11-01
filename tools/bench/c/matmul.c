#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

int main(void){ int n=(int)N(200); int64_t*a=malloc(sizeof(int64_t)*(size_t)n*(size_t)n),*b=malloc(sizeof(int64_t)*(size_t)n*(size_t)n),*c=malloc(sizeof(int64_t)*(size_t)n*(size_t)n);
 for(int i=0;i<n;i++)for(int j=0;j<n;j++){a[i*n+j]=b[i*n+j]=(i*j)%7+1;}
 for(int i=0;i<n;i++)for(int j=0;j<n;j++){int64_t s=0;for(int k=0;k<n;k++)s+=a[i*n+k]*b[k*n+j];c[i*n+j]=s;}
 printf("%lld %lld\n",(long long)c[10*n+10],(long long)c[199*n+199]); return 0; }
