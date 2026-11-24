#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <pthread.h>
#include <sys/stat.h>
static int slurp(const char *path, char *buf, int cap) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    int n = (int)read(fd, buf, (size_t)cap - 1);
    close(fd);
    if (n >= 0) buf[n] = 0;
    return n;
}
int main(int argc, char **argv) {
    char buf[8192];
    int n = slurp("/proc/self/cmdline", buf, sizeof buf);
    printf("cmdline: %d bytes, first=%s\n", n, buf);
    n = slurp("/proc/self/status", buf, sizeof buf);
    printf("status: Name=%s\n", strstr(buf, "Name:\t") ? strtok(strstr(buf, "Name:\t") + 6, "\n") : "?");
    n = slurp("/proc/cpuinfo", buf, sizeof buf);
    printf("cpuinfo: %s\n", strstr(buf, "SprintOS virtual CPU") ? "ok" : "missing");
    n = slurp("/proc/meminfo", buf, sizeof buf);
    printf("meminfo: %s\n", strstr(buf, "MemTotal:") ? "ok" : "missing");
    n = slurp("/proc/self/maps", buf, sizeof buf);
    int heap = strstr(buf, "[heap]") != NULL, stack = strstr(buf, "[stack]") != NULL;
    printf("maps: %d bytes heap=%d stack=%d exe=%d\n", n, heap, stack, strstr(buf, "/procfs") != NULL || strstr(buf, "procfs") != NULL);
    char link[200];
    ssize_t l = readlink("/proc/self/exe", link, sizeof link - 1);
    link[l > 0 ? l : 0] = 0;
    printf("exe: %s\n", link);
    int fd = open("/lx/input.txt", O_RDONLY);
    char path[64], target[200];
    snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
    l = readlink(path, target, sizeof target - 1);
    target[l > 0 ? l : 0] = 0;
    printf("fd link: %s\n", target);
    DIR *d = opendir("/proc/self/fd");
    int count = 0; struct dirent *e;
    while ((e = readdir(d))) if (e->d_name[0] != '.') count++;
    closedir(d);
    printf("fd entries: %d\n", count);
    struct stat st;
    printf("stat /proc/self: dir=%d\n", stat("/proc/self", &st) == 0 && S_ISDIR(st.st_mode));
    printf("stat /proc/nothing: %d\n", stat("/proc/nothing", &st));
    n = slurp("/proc/uptime", buf, sizeof buf);
    printf("uptime: %s\n", n > 0 && strchr(buf, '.') ? "ok" : "bad");
    /* glibc finds the main thread's stack from /proc/self/maps */
    pthread_attr_t at;
    int r = pthread_getattr_np(pthread_self(), &at);
    void *sp; size_t sz;
    if (r == 0) pthread_attr_getstack(&at, &sp, &sz);
    printf("pthread_getattr_np: %d size>0=%d\n", r, r == 0 && sz > 0);
    return 0;
}
