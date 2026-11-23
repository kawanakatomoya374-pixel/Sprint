#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
int main(int argc, char **argv) {
    printf("glibc hello, argc=%d\n", argc);
    char *p = malloc(1 << 20); memset(p, 1, 1 << 20);
    printf("sqrt(2)=%.6f strlen=%zu\n", sqrt(2.0), strlen("abc"));
    return 3;
}
