#include <stdio.h>
#include <math.h>
static volatile double (*volatile fp)(double) = sqrt;
int main(void){ double s=0; for(long i=0;i<20000000;i++) s+=fp((double)i); printf("%.14g\n", s); return 0; }
