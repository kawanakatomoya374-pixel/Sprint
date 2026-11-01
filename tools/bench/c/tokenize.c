#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
/* bound is read through a volatile so -O3 cannot fold the whole benchmark into a constant */
static volatile int64_t V;
static int64_t N(int64_t x){ V = x; return V; }

static int dg(int c){return c>=48&&c<=57;}
static int al(int c){return (c>=97&&c<=122)||(c>=65&&c<=90)||c==95;}
int main(void){ const char*u="let x1 = foo(42, bar_baz) + 3 * (y - 17);\nif x1 >= 100 { print(x1) }\n"; size_t ul=strlen(u); int64_t reps=N(20000);
 size_t n=ul*(size_t)reps; char*s=malloc(n); for(int64_t r=0;r<reps;r++)memcpy(s+(size_t)r*ul,u,ul);
 int64_t t=0,nu=0,id=0,sy=0;
 for(int k=0;k<5;k++){ t=nu=id=sy=0; size_t i=0;
  while(i<n){ int c=(unsigned char)s[i];
   if(c==32||c==10)i++;
   else if(dg(c)){size_t j=i;while(j<n&&dg((unsigned char)s[j]))j++;nu++;t++;i=j;}
   else if(al(c)){size_t j=i;while(j<n&&(al((unsigned char)s[j])||dg((unsigned char)s[j])))j++;id++;t++;i=j;}
   else{sy++;t++;i++;} } }
 printf("%lld %lld %lld %lld\n",(long long)t,(long long)nu,(long long)id,(long long)sy); return 0; }
