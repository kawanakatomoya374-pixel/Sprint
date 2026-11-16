/* Small POSIX compatibility layer for Windows (mingw / clang-mingw). Include after the system headers. On POSIX it is empty. */
#ifndef SP_PLATFORM_H
#define SP_PLATFORM_H
#if defined(_WIN32)
#include <errno.h>
#include <direct.h>
#include <io.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
/* realpath(): absolute, '/'-separated, and (like POSIX) fails with ENOENT when the path does not exist */
static inline char *sp_realpath(const char *path, char *out) {
    char tmp[PATH_MAX];
    if (!_fullpath(tmp, path, sizeof tmp)) return NULL;
    if (_access(tmp, 0) != 0) { errno = ENOENT; return NULL; }
    for (char *p = tmp; *p; p++)
        if (*p == '\\') *p = '/';
    size_t n = strlen(tmp);
    memcpy(out, tmp, n + 1);
    return out;
}
#define realpath(p, o) sp_realpath((p), (o))
#define lstat(p, st) stat((p), (st))
#define mkdir(p, mode) _mkdir(p)
static inline ssize_t getline(char **lineptr, size_t *n, FILE *f) {
    size_t len = 0;
    int c;
    if (!*lineptr || *n == 0) { *n = 128; *lineptr = (char *)malloc(*n); if (!*lineptr) return -1; }
    while ((c = fgetc(f)) != EOF) {
        if (len + 2 > *n) {
            char *g = (char *)realloc(*lineptr, *n * 2);
            if (!g) return -1;
            *lineptr = g;
            *n *= 2;
        }
        (*lineptr)[len++] = (char)c;
        if (c == '\n') break;
    }
    if (len == 0) return -1;
    (*lineptr)[len] = 0;
    return (ssize_t)len;
}
#endif
#endif
