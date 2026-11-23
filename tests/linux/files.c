#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>
int main(void) {
    char buf[4096];
    int fd = open("/lx/input.txt", O_RDONLY);
    printf("open input: %s\n", fd >= 0 ? "ok" : strerror(errno));
    ssize_t n = read(fd, buf, sizeof buf - 1);
    buf[n > 0 ? n : 0] = 0;
    printf("read %zd bytes: %s", n, buf);
    struct stat st;
    fstat(fd, &st);
    printf("size=%ld regular=%d\n", (long)st.st_size, S_ISREG(st.st_mode));
    lseek(fd, 6, SEEK_SET);
    n = read(fd, buf, 5);
    buf[n] = 0;
    printf("seek+read: [%s]\n", buf);
    close(fd);
    mkdir("/lx/out", 0755);
    fd = open("/lx/out/result.bin", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    unsigned char data[10000];
    for (int i = 0; i < 10000; i++) data[i] = (unsigned char)(i * 7);
    write(fd, data, sizeof data);
    close(fd);
    FILE *f = fopen("/lx/out/text.txt", "w");
    fprintf(f, "line %d\nline %d\n", 1, 2);
    fclose(f);
    f = fopen("/lx/out/text.txt", "r");
    char line[100];
    int lines = 0;
    while (fgets(line, sizeof line, f)) lines++;
    fclose(f);
    printf("fopen/fgets lines=%d\n", lines);
    DIR *d = opendir("/lx");
    int count = 0;
    struct dirent *e;
    while ((e = readdir(d))) { if (e->d_name[0] != '.') { printf("entry: %s\n", e->d_name); count++; } }
    closedir(d);
    printf("entries=%d\n", count);
    printf("missing: %s\n", open("/lx/nothere", O_RDONLY) < 0 ? strerror(errno) : "??");
    rename("/lx/out/text.txt", "/lx/out/renamed.txt");
    unlink("/lx/out/result.bin");
    char cwd[100];
    getcwd(cwd, sizeof cwd);
    printf("cwd=%s\n", cwd);
    return 0;
}
