#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
static int send_fd(int s, int fd, const char *msg) {
    struct iovec iov = { (void *)msg, strlen(msg) };
    char ctl[CMSG_SPACE(sizeof(int))];
    memset(ctl, 0, sizeof ctl);
    struct msghdr mh = { 0 };
    mh.msg_iov = &iov; mh.msg_iovlen = 1;
    if (fd >= 0) { mh.msg_control = ctl; mh.msg_controllen = sizeof ctl;
        struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = CMSG_LEN(sizeof(int)); memcpy(CMSG_DATA(c), &fd, sizeof fd); }
    return (int)sendmsg(s, &mh, 0);
}
static int recv_fd(int s, char *buf, int cap, int *fd) {
    struct iovec iov = { buf, (size_t)cap };
    char ctl[CMSG_SPACE(sizeof(int))];
    struct msghdr mh = { 0 };
    mh.msg_iov = &iov; mh.msg_iovlen = 1; mh.msg_control = ctl; mh.msg_controllen = sizeof ctl;
    int n = (int)recvmsg(s, &mh, 0);
    *fd = -1;
    struct cmsghdr *c = CMSG_FIRSTHDR(&mh);
    if (n >= 0 && c && c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) memcpy(fd, CMSG_DATA(c), sizeof(int));
    if (n >= 0) buf[n] = 0;
    return n;
}
int main(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv)) { puts("socketpair failed"); return 1; }
    send(sv[0], "hello", 5, 0);
    send(sv[0], "second message", 14, 0);
    char b[64];
    int n1 = (int)recv(sv[1], b, sizeof b, 0);
    int n2 = (int)recv(sv[1], b, sizeof b, 0);
    printf("boundaries: %d %d\n", n1, n2);
    int f = open("/seq.txt", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    send_fd(sv[0], f, "with fd");
    close(f);
    int got;
    int n = recv_fd(sv[1], b, sizeof b, &got);
    printf("message: %s (%d) fd>=0:%d\n", b, n, got >= 0);
    if (got >= 0) { write(got, "through the passed descriptor\n", 30); close(got); }
    int pid = fork();
    if (pid == 0) {                           /* the child receives a descriptor that the parent sends */
        int fd2; char c[32];
        recv_fd(sv[1], c, sizeof c, &fd2);
        write(fd2, "from the child\n", 15);
        _exit(fd2 >= 0 ? 0 : 3);
    }
    int g2 = open("/seq2.txt", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    send_fd(sv[0], g2, "x");
    int st; waitpid(pid, &st, 0);
    char rb[128] = {0};
    int r = open("/seq.txt", O_RDONLY); int m = (int)read(r, rb, 127); close(r);
    printf("file: %.*s", m, rb);
    char rb2[64] = {0};
    r = open("/seq2.txt", O_RDONLY); m = (int)read(r, rb2, 63); close(r);
    printf("child: %.*s", m, rb2);
    close(sv[0]);
    int n3 = (int)recv(sv[1], b, sizeof b, 0);
    printf("eof: %d child status %d\n", n3, st >> 8);
    puts("seqpacket ok");
    return 0;
}
