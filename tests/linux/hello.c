#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/utsname.h>
int main(int argc, char **argv, char **envp) {
    printf("hello from a Linux program on SprintOS\n");
    printf("argc=%d", argc);
    for (int i = 0; i < argc; i++) printf(" [%s]", argv[i]);
    printf("\n");
    int ne = 0;
    while (envp[ne]) ne++;
    printf("envp=%d first=%s\n", ne, ne ? envp[0] : "-");
    struct utsname u;
    uname(&u);
    printf("uname: %s %s %s\n", u.sysname, u.release, u.machine);
    char *p = malloc(3 << 20);                       /* big: mmap */
    memset(p, 7, 3 << 20);
    long sum = 0;
    for (int i = 0; i < (3 << 20); i += 4096) sum += p[i];
    printf("big malloc sum=%ld\n", sum);
    char *q[200];
    for (int i = 0; i < 200; i++) { q[i] = malloc(1000 + i); memset(q[i], i, 1000 + i); }
    int ok = 1;
    for (int i = 0; i < 200; i++) if (q[i][999] != (char)i) ok = 0;
    printf("small mallocs ok=%d pid>0=%d\n", ok, getpid() > 0);
    fprintf(stderr, "to stderr\n");
    return 7;
}
