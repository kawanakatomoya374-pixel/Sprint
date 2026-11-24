#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/epoll.h>
#include <netinet/in.h>
#include <arpa/inet.h>
int main(void) {
    char buf[256];
    int sv[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    write(sv[0], "ping", 4);
    ssize_t n = read(sv[1], buf, sizeof buf);
    printf("socketpair: %.*s\n", (int)n, buf);
    shutdown(sv[0], SHUT_WR);
    n = read(sv[1], buf, sizeof buf);
    printf("after shutdown: read=%zd\n", n);
    close(sv[0]); close(sv[1]);

    /* a UNIX stream server and a client in another process */
    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un ua = {.sun_family = AF_UNIX};
    strcpy(ua.sun_path, "/tmp/test.sock");
    printf("bind unix: %d\n", bind(ls, (struct sockaddr *)&ua, sizeof ua));
    listen(ls, 4);
    if (fork() == 0) {
        int c = socket(AF_UNIX, SOCK_STREAM, 0);
        if (connect(c, (struct sockaddr *)&ua, sizeof ua) != 0) _exit(1);
        write(c, "hello unix", 10);
        n = read(c, buf, sizeof buf);
        write(c, buf, (size_t)n);                      /* echo the reply back */
        _exit(0);
    }
    int cs = accept(ls, 0, 0);
    n = read(cs, buf, sizeof buf);
    printf("unix server got: %.*s\n", (int)n, buf);
    write(cs, "reply!", 6);
    n = read(cs, buf, sizeof buf);
    printf("unix echo: %.*s\n", (int)n, buf);
    int st; wait(&st);
    close(cs); close(ls);

    /* loopback TCP: a server, a client in another process, poll and epoll */
    int tl = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(tl, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(8080), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    printf("bind tcp: %d\n", bind(tl, (struct sockaddr *)&a, sizeof a));
    listen(tl, 5);
    struct sockaddr_in got; socklen_t gl = sizeof got;
    getsockname(tl, (struct sockaddr *)&got, &gl);
    printf("listening on port %d\n", ntohs(got.sin_port));
    if (fork() == 0) {
        usleep(50000);
        int c = socket(AF_INET, SOCK_STREAM, 0);
        if (connect(c, (struct sockaddr *)&a, sizeof a) != 0) _exit(1);
        for (int i = 0; i < 3; i++) { write(c, "x", 1); usleep(20000); }
        close(c);
        _exit(0);
    }
    int ep = epoll_create1(0);
    struct epoll_event ev = {.events = EPOLLIN, .data.fd = tl};
    epoll_ctl(ep, EPOLL_CTL_ADD, tl, &ev);
    struct epoll_event out[4];
    int r = epoll_wait(ep, out, 4, 5000);
    printf("epoll: %d ready, listener=%d\n", r, r > 0 && out[0].data.fd == tl);
    int conn = accept4(tl, 0, 0, SOCK_NONBLOCK);
    ev.data.fd = conn;
    epoll_ctl(ep, EPOLL_CTL_ADD, conn, &ev);
    int total = 0, loops = 0;
    for (;;) {
        r = epoll_wait(ep, out, 4, 2000);
        if (r <= 0) break;
        int done = 0;
        for (int i = 0; i < r; i++) if (out[i].data.fd == conn) {
            n = read(conn, buf, sizeof buf);
            if (n > 0) total += (int)n; else if (n == 0) done = 1;
        }
        loops++;
        if (done) break;
    }
    printf("tcp loopback: %d bytes then EOF after %d wakeups\n", total, loops > 1);
    wait(&st);
    /* poll with a timeout, nonblocking read */
    struct pollfd pf = {.fd = conn, .events = POLLIN};
    r = poll(&pf, 1, 100);
    printf("poll after close: %d hup=%d\n", r, (pf.revents & POLLHUP) != 0);
    int cl = socket(AF_INET, SOCK_STREAM, 0);
    a.sin_port = htons(9);
    printf("connect refused: %s\n", connect(cl, (struct sockaddr *)&a, sizeof a) < 0 && errno == ECONNREFUSED ? "yes" : "no");
    /* datagrams */
    int d1 = socket(AF_INET, SOCK_DGRAM, 0), d2 = socket(AF_INET, SOCK_DGRAM, 0);
    a.sin_port = htons(5353);
    bind(d1, (struct sockaddr *)&a, sizeof a);
    sendto(d2, "datagram", 8, 0, (struct sockaddr *)&a, sizeof a);
    n = recv(d1, buf, sizeof buf, 0);
    printf("udp loopback: %.*s\n", (int)n, buf);
    return 0;
}
