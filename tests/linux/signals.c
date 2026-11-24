#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <setjmp.h>
#include <time.h>
#include <sys/time.h>
#include <sys/wait.h>
static volatile sig_atomic_t usr1, usr2, alrm, chld, ticks;
static volatile int info_signo, info_pid_ok;
static sigjmp_buf jb;
static void on_usr1(int s) { usr1++; }
static void on_usr2(int s, siginfo_t *si, void *uc) { usr2++; info_signo = si->si_signo; info_pid_ok = si->si_pid == getpid() || si->si_pid == 0; }
static void on_alrm(int s) { alrm++; }
static void on_chld(int s) { chld++; }
static void on_tick(int s) { ticks++; }
static void on_segv(int s, siginfo_t *si, void *uc) { printf("SIGSEGV handler: addr=%p\n", si->si_addr); siglongjmp(jb, 1); }
static void on_fpe(int s) { siglongjmp(jb, 2); }
int main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_usr1; sigaction(SIGUSR1, &sa, 0);
    raise(SIGUSR1);
    printf("raise: usr1=%d\n", usr1);
    sa.sa_sigaction = on_usr2; sa.sa_flags = SA_SIGINFO; sigaction(SIGUSR2, &sa, 0);
    kill(getpid(), SIGUSR2);
    printf("kill + siginfo: usr2=%d signo=%d pid_ok=%d\n", usr2, info_signo, info_pid_ok);
    /* blocked signals stay pending until unblocked */
    sigset_t set, old; sigemptyset(&set); sigaddset(&set, SIGUSR1);
    sigprocmask(SIG_BLOCK, &set, &old);
    raise(SIGUSR1);
    sigset_t pend; sigpending(&pend);
    printf("blocked: usr1=%d pending=%d\n", usr1, sigismember(&pend, SIGUSR1));
    sigprocmask(SIG_SETMASK, &old, 0);
    printf("unblocked: usr1=%d\n", usr1);
    /* alarm + pause */
    memset(&sa, 0, sizeof sa); sa.sa_handler = on_alrm; sigaction(SIGALRM, &sa, 0);
    alarm(1);
    int r = pause();
    printf("pause: r=%d errno=%s alrm=%d\n", r, errno == EINTR ? "EINTR" : "other", alrm);
    /* a periodic timer interrupts code that makes no system calls */
    memset(&sa, 0, sizeof sa); sa.sa_handler = on_tick; sigaction(SIGVTALRM, &sa, 0);
    sa.sa_handler = on_tick; sigaction(SIGALRM, &sa, 0);
    struct itimerval it = {{0, 50000}, {0, 50000}};
    setitimer(ITIMER_REAL, &it, 0);
    volatile unsigned long x = 0;
    for (unsigned long i = 0; i < 400000000UL && ticks < 3; i++) x += i;
    struct itimerval off = {{0, 0}, {0, 0}}; setitimer(ITIMER_REAL, &off, 0);
    printf("busy loop interrupted by the timer: ticks>=3 is %d\n", ticks >= 3);
    /* nanosleep is interrupted */
    memset(&sa, 0, sizeof sa); sa.sa_handler = on_alrm; sigaction(SIGALRM, &sa, 0);
    struct itimerval one = {{0, 0}, {0, 100000}}; setitimer(ITIMER_REAL, &one, 0);
    struct timespec d = {2, 0}, rem;
    r = nanosleep(&d, &rem);
    printf("nanosleep: r=%d errno=%s remaining>0=%d\n", r, errno == EINTR ? "EINTR" : "other", rem.tv_sec > 0 || rem.tv_nsec > 0);
    /* SA_RESTART: a blocking read goes on after the handler */
    memset(&sa, 0, sizeof sa); sa.sa_handler = on_alrm; sa.sa_flags = SA_RESTART; sigaction(SIGALRM, &sa, 0);
    int p[2]; pipe(p);
    if (fork() == 0) { usleep(400000); write(p[1], "z", 1); _exit(0); }
    struct itimerval s2 = {{0, 0}, {0, 100000}}; setitimer(ITIMER_REAL, &s2, 0);
    char c; int before = alrm;
    ssize_t n = read(p[0], &c, 1);
    printf("restart: read=%zd c=%c handler ran=%d\n", n, n > 0 ? c : '?', alrm > before);
    wait(0);
    /* SIGCHLD and default termination */
    memset(&sa, 0, sizeof sa); sa.sa_handler = on_chld; sigaction(SIGCHLD, &sa, 0);
    pid_t k = fork();
    if (k == 0) { for (;;) pause(); }
    usleep(100000);
    kill(k, SIGTERM);
    int st; waitpid(k, &st, 0);
    printf("child killed: signaled=%d sig=%d chld=%d\n", WIFSIGNALED(st), WTERMSIG(st), chld > 0);
    /* faults become signals */
    memset(&sa, 0, sizeof sa); sa.sa_sigaction = on_segv; sa.sa_flags = SA_SIGINFO | SA_NODEFER; sigaction(SIGSEGV, &sa, 0);
    if (sigsetjmp(jb, 1) == 0) { volatile int *bad = (int *)0; *bad = 1; }
    printf("recovered from SIGSEGV\n");
    memset(&sa, 0, sizeof sa); sa.sa_handler = on_fpe; sigaction(SIGFPE, &sa, 0);
    volatile int zero = 0;
    if (sigsetjmp(jb, 1) == 0) { volatile int q = 5 / zero; (void)q; }
    printf("recovered from SIGFPE\n");
    /* an unhandled SIGSEGV ends the program with the signal */
    if (fork() == 0) { signal(SIGSEGV, SIG_DFL); volatile int *bad = (int *)8; *bad = 1; _exit(0); }
    wait(&st);
    printf("unhandled fault: signaled=%d sig=%d\n", WIFSIGNALED(st), WTERMSIG(st));
    /* abort() */
    if (fork() == 0) { abort(); }
    wait(&st);
    printf("abort: sig=%d\n", WIFSIGNALED(st) ? WTERMSIG(st) : -1);
    return 0;
}
