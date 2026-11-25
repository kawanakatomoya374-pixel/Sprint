#include <stdio.h>
#include <stdint.h>
#include <poll.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>
static long ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000L + t.tv_nsec / 1000000L; }
int main(void) {
    int fd = timerfd_create(CLOCK_MONOTONIC, 0);
    struct itimerspec its = { {0, 0}, {0, 100 * 1000000} };
    timerfd_settime(fd, 0, &its, 0);
    long t0 = ms();
    uint64_t n = 0;
    ssize_t r = read(fd, &n, 8);
    long dt = ms() - t0;
    printf("one-shot: read=%ld expirations=%llu waited>=80ms:%d\n", (long)r, (unsigned long long)n, dt >= 80);
    struct itimerspec per = { {0, 50 * 1000000}, {0, 50 * 1000000} };
    timerfd_settime(fd, 0, &per, 0);
    struct pollfd p = { fd, POLLIN, 0 };
    int got = 0;
    for (int i = 0; i < 3; i++) { if (poll(&p, 1, 2000) == 1 && read(fd, &n, 8) == 8) got += (int)n; }
    printf("periodic: expirations=%d\n", got >= 3);
    struct itimerspec off = { {0, 0}, {0, 0} };
    timerfd_settime(fd, 0, &off, 0);
    struct pollfd q = { fd, POLLIN, 0 };
    printf("disarmed: poll=%d\n", poll(&q, 1, 200));
    puts("timerfd ok");
    return 0;
}
