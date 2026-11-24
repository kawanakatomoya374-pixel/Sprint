#include <stdio.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void){
    int id = shmget(IPC_PRIVATE, 100000, IPC_CREAT | 0600);
    if (id < 0) { puts("shmget failed"); return 1; }
    char *p = shmat(id, 0, 0);
    if (p == (char*)-1) { puts("shmat failed"); return 1; }
    shmctl(id, IPC_RMID, 0);              /* removed, but stays until detached */
    strcpy(p, "parent");
    pid_t c = fork();
    if (c == 0) {
        if (strcmp(p, "parent")) _exit(2);
        strcpy(p, "child wrote");
        shmdt(p);
        _exit(0);
    }
    int st; waitpid(c, &st, 0);
    printf("child status %d, segment says: %s\n", st >> 8, p);
    p[99999] = 1;
    shmdt(p);
    puts("shm ok");
    return 0;
}
