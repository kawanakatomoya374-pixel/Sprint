#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

int main(void){ double x=0,y=1,vx=0.5,vy=0,dt=0.001; int64_t n=N(10000000);
 for(int64_t i=0;i<n;i++){ double r2=x*x+y*y, r3=r2*sqrt(r2); vx-=x/r3*dt; vy-=y/r3*dt; x+=vx*dt; y+=vy*dt; }
 printf("%.17g\n", x+y); return 0; }
