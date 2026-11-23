#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int counter, ready;
static __thread int tls_value;
static void *worker(void *arg) {
    long id = (long)arg;
    tls_value = (int)id * 100;
    for (int i = 0; i < 500; i++) { pthread_mutex_lock(&mu); counter++; pthread_mutex_unlock(&mu); }
    struct timespec d = {0, (long)(id + 1) * 10 * 1000 * 1000};
    nanosleep(&d, 0);
    pthread_mutex_lock(&mu);
    ready++;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    if (tls_value != (int)id * 100) return (void *)-1;
    return (void *)(id * 2);
}
int main(void) {
    pthread_t t[4];
    for (long i = 0; i < 4; i++) pthread_create(&t[i], 0, worker, (void *)i);
    pthread_mutex_lock(&mu);
    while (ready < 4) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
    long sum = 0;
    for (int i = 0; i < 4; i++) { void *r; pthread_join(t[i], &r); sum += (long)r; }
    printf("threads done: counter=%d sum=%ld main tls=%d\n", counter, sum, tls_value);
    /* many short threads */
    int made = 0;
    for (int i = 0; i < 20; i++) { pthread_t x; if (pthread_create(&x, 0, worker, (void *)0) == 0) { pthread_join(x, 0); made++; } }
    printf("short threads: %d counter=%d\n", made, counter);
    return 0;
}
