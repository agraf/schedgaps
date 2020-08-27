/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Latency Tracer inspired by the Linux tracing hwlat target. It spawns
 * NUM_THREADS threads, each simulating a HT of a virtual machine.
 *
 * All of the threads go busy trying to find execution gaps using rdtsc
 * for a while and then go to sleep. The constant busy and idle state
 * change exposes shortcomings in scheduler implementations.
 */

#define _GNU_SOURCE
#include <stdlib.h>
#include <stdio.h>
#include <sys/time.h>
#include <sys/random.h>
#include <unistd.h>
#include <stdint.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <fcntl.h>

#define NUM_THREADS 16

struct args {
	int id;
	int sleep;
};

static uint64_t tsc_per_sec;
static uint64_t max_diff;
static volatile uint64_t max_lat;
static int marker_fd;
static int online;

static uint64_t rdtsc(void)
{
    unsigned int low,high;
    long val;
    asm volatile("rdtsc" : "=a" (low), "=d" (high));
    val = high;
    val <<= 32;
    val |= low;
    return val;
}

static void die(uint64_t tsc_diff)
{
    pid_t tid = syscall(__NR_gettid);

    dprintf(marker_fd, "XXXXX hwlat took too long XXXXX\n");

    printf("diff: %ldms\n", (tsc_diff * 1000) / tsc_per_sec);
    printf("TID: %d\n", tid);
    printf("TSC: %ld\n", rdtsc());
    exit(1);
}

static void check_diff(uint64_t diff)
{
    if (diff > max_diff)
        die(diff);

    if (diff > max_lat)
        max_lat = diff;
}

static void *t(void *argp)
{
    struct args *arg = argp;
    uint64_t tsc_begin, tsc_before, tsc_after;
    pid_t tid = syscall(__NR_gettid);
    char *s;

    printf("Thread %d -> %d\n", arg->id, (int)tid);

    asprintf(&s, "echo %d >> /sys/fs/cgroup/cpuset/vcpu%d/tasks", tid, arg->id % 2);
    printf("+ %s\n", s);
    if (system(s))
        exit(1);
    asprintf(&s, "echo %d >> /sys/fs/cgroup/cpu/cosched%d/tasks", tid, (arg->id / 2) + 1);
    printf("+ %s\n", s);
    if (system(s))
        exit(1);

    __atomic_fetch_add(&online, 1, __ATOMIC_SEQ_CST);
    while (__atomic_load_n(&online, __ATOMIC_SEQ_CST) != NUM_THREADS) asm("" : : : "memory");

    tsc_begin = tsc_before = tsc_after = rdtsc();
    while (1) {
        tsc_before = rdtsc();
        check_diff(tsc_before - tsc_after);
        tsc_after = rdtsc();
        check_diff(tsc_after - tsc_before);

        if ((tsc_after - tsc_begin) > tsc_per_sec) {
            usleep(arg->sleep);
            tsc_after = tsc_begin = rdtsc();
        }
    }


    return NULL;
}

int main(int argc, char **argv)
{
    unsigned long long tsc_before, tsc_after;
    struct args args[NUM_THREADS] = { };
    pthread_t thread[NUM_THREADS] = { };
    int i;

    marker_fd = open("/sys/kernel/debug/tracing/trace_marker", O_WRONLY);
    if (marker_fd < 0) {
        printf("Could not open trace_marker\n");
        exit(1);
    }

    tsc_before = rdtsc();
    sleep(1);
    tsc_after = rdtsc();

    tsc_per_sec = tsc_after - tsc_before;
    max_diff = tsc_per_sec / 10; /* Search for 100ms gaps */

    srand(5);

    for (i = 0; i < NUM_THREADS; i++) {
	args[i].id = i;
	args[i].sleep = rand() % 1000000;

        pthread_create(&thread[i], NULL, t, &args[i]);
    }

    while (sleep(1) || 1) {
        uint64_t max_lat_ms = (max_lat * 1000) / tsc_per_sec;
        printf("Max latency: %ld ms (%ld ticks, %d online)\n", max_lat_ms, max_lat, online);
        max_lat = 0;
    }

    for (i = 0; i < NUM_THREADS; i++) {
        pthread_join(thread[i], NULL);
    }
}
