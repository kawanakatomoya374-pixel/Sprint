#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

int main(void){ int64_t code[]={0,7,3,2,1,1,0,5,2,1,4}, st[8]={0}; int64_t sp=0,pc=0,acc=0,steps=0,n=N(6000000);
 while(steps<n){ int64_t op=code[pc];
  if(op==0){st[sp]=code[pc+1];sp++;pc+=2;} else if(op==1){sp--;acc+=st[sp];pc++;}
  else if(op==2){st[sp-1]=st[sp-1]*3+1;pc++;} else if(op==3){st[sp]=st[sp-1];sp++;pc++;}
  else if(op==4){pc=0;} else pc++;
  steps++; }
 printf("%lld\n",(long long)acc); return 0; }
