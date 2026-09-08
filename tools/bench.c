#include "decode.h"
#include "parse.h"
#include "sim.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: bench <puzzle> <solution> <cycles> [repeats] [nocoll]\n");
        return 1;
    }
    uint64_t target = strtoull(argv[3], NULL, 10);
    int repeats = argc > 4 ? atoi(argv[4]) : 1;
    int nocoll = argc > 5 ? atoi(argv[5]) : 0;

    struct puzzle_file *pf = parse_puzzle_file(argv[1]);
    struct solution_file *sf = parse_solution_file(argv[2]);
    if (!pf || !sf) {
        fprintf(stderr, "couldn't parse input files\n");
        return 2;
    }

    double best = 1e30;
    for (int i = 0; i < repeats; ++i) {
        struct solution solution = { 0 };
        struct board board = { 0 };
        const char *error = NULL;
        if (!decode_solution(&solution, pf, sf, &error)) {
            fprintf(stderr, "decode error: %s\n", error ? error : "?");
            return 2;
        }
        initial_setup(&solution, &board, sf->area);
#ifndef NO_COLL_API
        board.collision_detection_disabled = nocoll != 0;
#endif
        double t0 = now_ms();
        while (board.cycle < target && !board.collision)
            run(&solution, &board);
        double t1 = now_ms();
        double ms = t1 - t0;
        uint64_t executed = board.cycle;
        bool collided = board.collision;
        destroy(&solution, &board);
        if (ms < best)
            best = ms;
        if (i == repeats - 1)
            printf("target=%llu executed=%llu collision=%d total_ms=%.1f best_ms=%.1f ms_per_cycle=%.4f\n",
             (unsigned long long)target, (unsigned long long)executed, collided ? 1 : 0, ms, best,
             executed ? best / (double)executed : 0.0);
    }
    return 0;
}
