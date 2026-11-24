#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
static struct sockaddr_in addr(const char *ip, int port) {
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    inet_pton(AF_INET, ip, &a.sin_addr);
    return a;
}
int main(void) {
    char buf[4096];
    /* a TCP client talking to a server on the host (10.0.2.2 is the host in QEMU's user network) */
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = addr("10.0.2.2", 18090);
    int r = connect(s, (struct sockaddr *)&a, sizeof a);
    printf("nettest: connect=%d\n", r);
    const char *req = "GET /hello HTTP/1.0\r\nHost: host\r\n\r\n";
    write(s, req, strlen(req));
    int total = 0; ssize_t n;
    char *body = buf; buf[0] = 0;
    while ((n = read(s, buf + total, sizeof buf - 1 - (size_t)total)) > 0) total += (int)n;
    buf[total] = 0;
    char *nl = strchr(buf, '\r'); if (nl) *nl = 0;
    printf("nettest: http: [%s] total=%d\n", buf, total);
    char *b = strstr(buf + strlen(buf) + 2, "\r\n\r\n");
    (void)body; (void)b;
    close(s);
    /* a bigger transfer */
    s = socket(AF_INET, SOCK_STREAM, 0);
    a = addr("10.0.2.2", 18090);
    connect(s, (struct sockaddr *)&a, sizeof a);
    write(s, "GET /big HTTP/1.0\r\n\r\n", 21);
    long got = 0; unsigned sum = 0;
    char big[8192];
    while ((n = read(s, big, sizeof big)) > 0) { for (ssize_t i = 0; i < n; i++) sum = sum * 31 + (unsigned char)big[i]; got += n; }
    printf("nettest: big=%ld sum=%u\n", got, sum);
    close(s);
    /* nonblocking connect */
    s = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    r = connect(s, (struct sockaddr *)&a, sizeof a);
    printf("nettest: nb connect=%d einprogress=%d\n", r, errno == EINPROGRESS);
    struct pollfd pf = {.fd = s, .events = POLLOUT};
    r = poll(&pf, 1, 5000);
    int err = -1; socklen_t el = sizeof err;
    getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &el);
    printf("nettest: nb poll=%d out=%d so_error=%d\n", r, (pf.revents & POLLOUT) != 0, err);
    close(s);
    /* a closed port */
    s = socket(AF_INET, SOCK_STREAM, 0);
    a = addr("10.0.2.2", 9);
    r = connect(s, (struct sockaddr *)&a, sizeof a);
    printf("nettest: closed port: %s\n", r < 0 && errno == ECONNREFUSED ? "ECONNREFUSED" : strerror(errno));
    close(s);
    /* UDP */
    int u = socket(AF_INET, SOCK_DGRAM, 0);
    a = addr("10.0.2.2", 18091);
    sendto(u, "udp from sprintos", 17, 0, (struct sockaddr *)&a, sizeof a);
    struct pollfd up = {.fd = u, .events = POLLIN};
    r = poll(&up, 1, 3000);
    struct sockaddr_in from; socklen_t fl = sizeof from;
    n = recvfrom(u, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
    printf("nettest: udp: %.*s from %s:%d\n", (int)n, buf, inet_ntoa(from.sin_addr), ntohs(from.sin_port));
    close(u);
    /* the resolver */
    struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM}, *res = 0;
    r = getaddrinfo("sprint.test", "80", &hints, &res);
    printf("nettest: getaddrinfo: %s\n", r == 0 ? inet_ntoa(((struct sockaddr_in *)res->ai_addr)->sin_addr) : gai_strerror(r));
    /* a server: the host connects to it through QEMU's port forward */
    int l = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in la = {.sin_family = AF_INET, .sin_port = htons(7001), .sin_addr.s_addr = htonl(INADDR_ANY)};
    printf("nettest: bind=%d\n", bind(l, (struct sockaddr *)&la, sizeof la));
    listen(l, 4);
    printf("nettest: listening 7001\n"); fflush(stdout);
    struct pollfd lp = {.fd = l, .events = POLLIN};
    r = poll(&lp, 1, 30000);
    int c = accept(l, 0, 0);
    printf("nettest: accepted=%d\n", c >= 0);
    int tot = 0;
    while ((n = read(c, buf, sizeof buf)) > 0) { for (ssize_t i = 0; i < n; i++) if (buf[i] >= 'a' && buf[i] <= 'z') buf[i] -= 32; write(c, buf, (size_t)n); tot += (int)n; }
    printf("nettest: served %d bytes\n", tot);
    close(c); close(l);
    return 0;
}
