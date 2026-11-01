#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

typedef struct { int64_t x,y; } P;
static P*add(const P*a,const P*o){ P*p=malloc(sizeof*p); p->x=a->x+o->x; p->y=a->y+o->y; return p; }
int main(void){ P*p=calloc(1,sizeof*p); P d={1,2}; int64_t s=0,n=N(3000000);
 for(int64_t i=0;i<n;i++){ P*q=add(p,&d); free(p); p=q; s+=(p->x*p->x+p->y*p->y)%3; }
 printf("%lld\n",(long long)s); return 0; }
