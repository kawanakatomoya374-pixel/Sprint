#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/wait.h>
int main(void) {
    int fds[2];
    pipe(fds);
    pid_t pid = fork();
    if (pid == 0) {                       /* child: stdout into the pipe, then run another program */
        close(fds[0]);
        dup2(fds[1], 1);
        close(fds[1]);
        execl("/bin/hello", "hello", "from-exec", (char *)0);
        _exit(99);
    }
    close(fds[1]);
    char buf[4096];
    size_t total = 0;
    ssize_t n;
    char first[200] = {0};
    while ((n = read(fds[0], buf, sizeof buf)) > 0) {
        if (total == 0) { memcpy(first, buf, 40); }
        total += (size_t)n;
    }
    close(fds[0]);
    int st = 0;
    pid_t w = waitpid(pid, &st, 0);
    printf("child %s: captured %zu bytes, first=[%.38s]\n", w == pid ? "reaped" : "NOT reaped", total, first);
    printf("exec'd program status: exited=%d code=%d\n", WIFEXITED(st), WEXITSTATUS(st));
    /* several children with different exit codes */
    int codes = 0;
    for (int i = 1; i <= 3; i++) {
        pid_t c = fork();
        if (c == 0) _exit(i * 10);
        waitpid(c, &st, 0);
        codes += WEXITSTATUS(st);
    }
    printf("three children: sum of codes=%d\n", codes);
    /* memory is copied, not shared */
    int *mem = malloc(100);
    *mem = 1;
    pid_t c = fork();
    if (c == 0) { *mem = 2; _exit(*mem); }
    waitpid(c, &st, 0);
    printf("fork copy: parent sees %d, child exited %d\n", *mem, WEXITSTATUS(st));
    /* wait with no children */
    printf("wait without children: %s\n", wait(&st) == -1 ? "ECHILD" : "??");
    /* sleeping */
    struct timespec t0, t1, d = {0, 120 * 1000 * 1000};
    clock_gettime(CLOCK_MONOTONIC, &t0);
    nanosleep(&d, 0);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
    printf("slept %s\n", ms >= 100 && ms < 1000 ? "about right" : "wrong");
    /* a pipe between two processes, written slowly */
    pipe(fds);
    if (fork() == 0) { close(fds[0]); for (int i = 0; i < 3; i++) { write(fds[1], "tick\n", 5); usleep(30000); } _exit(0); }
    close(fds[1]);
    int ticks = 0;
    while ((n = read(fds[0], buf, sizeof buf)) > 0) ticks += (int)n / 5;
    wait(&st);
    printf("blocking pipe reads: %d ticks\n", ticks);
    return 0;
}
