#include "decode.h"
#include "parse.h"
#include "sim.h"
#include <dirent.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define MEASURE_TIMES 0

#if MEASURE_TIMES
#include <time.h>
#endif

struct puzzle {
    struct puzzle *next;
    char *filename;
    struct puzzle_file *pf;
};

#define MAX_PATH_LEN 1024
#define MAX_PATHS 8192

static char *paths[MAX_PATHS];
static int number_of_paths;

static int path_is_directory(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && (st.st_mode & S_IFDIR);
}

static char *copy_string(const char *s)
{
    size_t n = strlen(s) + 1;
    char *copy = malloc(n);
    memcpy(copy, s, n);
    return copy;
}

// recurse over dir, collecting regular file paths (like `find dir -type f`)
static void collect_paths(const char *dir)
{
    DIR *d = opendir(dir);
    if (!d)
        return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        char path[MAX_PATH_LEN];
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
        if (path_is_directory(path)) {
            collect_paths(path);
            continue;
        }
        if (number_of_paths < MAX_PATHS)
            paths[number_of_paths++] = copy_string(path);
    }
    closedir(d);
}

static void free_paths(void)
{
    for (int i = 0; i < number_of_paths; ++i)
        free(paths[i]);
    number_of_paths = 0;
}

static int path_ends_with(const char *path, const char *suffix)
{
    size_t len = strlen(path);
    size_t slen = strlen(suffix);
    return len >= slen && strcmp(path + len - slen, suffix) == 0;
}

int main(void)
{
    collect_paths("test/puzzle");
    struct puzzle *puzzles = 0;
    for (int i = 0; i < number_of_paths; ++i) {
        char *buf = paths[i];
        struct puzzle_file *pf = parse_puzzle_file(buf);
        if (!pf) {
            fprintf(stderr, "couldn't parse puzzle at '%s'\n", buf);
            continue;
        }
        size_t last_slash = 0;
        for (size_t j = 0; buf[j]; ++j) {
            if (buf[j] == '/')
                last_slash = j + 1;
        }
        size_t last_dot = 0;
        for (size_t j = last_slash; buf[j]; ++j) {
            if (buf[j] == '.')
                last_dot = j;
        }
        if (last_dot > last_slash) {
            struct puzzle *puzzle = calloc(sizeof(struct puzzle), 1);
            puzzle->filename = malloc(last_dot - last_slash + 1);
            buf[last_dot] = '\0';
            memcpy(puzzle->filename, buf + last_slash, last_dot - last_slash + 1);
            puzzle->pf = pf;
            puzzle->next = puzzles;
            puzzles = puzzle;
        }
    }
    free_paths();
    fprintf(stderr, "all puzzles parsed\n");

    int total_solutions = 0;
    int validated_solutions = 0;
    collect_paths("test/solution");
    for (int i = 0; i < number_of_paths; ++i) {
        char *buf = paths[i];
        if (!path_ends_with(buf, ".solution"))
            continue;
#if MEASURE_TIMES
        struct timespec tstart = {0};
        struct timespec tend = {0};
        clock_gettime(CLOCK_MONOTONIC, &tstart);
#endif
        struct solution_file *sf = parse_solution_file(buf);
        if (!sf) {
            fprintf(stderr, "couldn't parse solution at '%s'\n", buf);
            continue;
        }

        struct puzzle *puzzle = puzzles;
        while (puzzle && !byte_string_is(sf->puzzle, puzzle->filename))
            puzzle = puzzle->next;
        if (!puzzle) {
            fprintf(stderr, "couldn't find puzzle named '%.*s' for '%s'\n", (int)sf->puzzle.length, sf->puzzle.bytes, buf);
            free_solution_file(sf);
            continue;
        }

        struct solution solution = { 0 };
        struct board board = { 0 };
        const char *error;
        if (!decode_solution(&solution, puzzle->pf, sf, &error)) {
            fprintf(stderr, "error in '%s': %s\n", buf, error);
            free_solution_file(sf);
            continue;
        }
        total_solutions++;

        bool expect_collision = sf->cost == 0 && sf->instructions == 0;

        uint64_t cost = solution_file_cost(sf);
        if (sf->cost != cost && !expect_collision) {
            fprintf(stderr, "cost mismatch for '%s'\n", buf);
            fprintf(stderr, "solution file says cost is: %" PRIu32 "\n", sf->cost);
            fprintf(stderr, "adding up its parts, the cost is: %" PRIu64 "\n", cost);
            goto fail;
        }

        uint64_t instructions = solution_instructions(&solution);
        if (sf->instructions != instructions && !expect_collision) {
            fprintf(stderr, "instructions mismatch for '%s'\n", buf);
            fprintf(stderr, "solution file says instruction count is: %" PRIu32 "\n", sf->instructions);
            fprintf(stderr, "counting instructions says instruction count is: %" PRIu64 "\n", instructions);
            goto fail;
        }

        // set up the board.
        initial_setup(&solution, &board, sf->area);

        // run the solution.
        while (board.cycle < 200000 && !board.complete) {
            cycle(&solution, &board);
            if (board.collision) {
                if (expect_collision)
                    goto success;
                fprintf(stderr, "collision in '%s' at %" PRId32 ", %" PRId32 ": %s\n", buf,
                 board.collision_location.u, board.collision_location.v,
                 board.collision_reason);
                break;
            }
        }
        if (sf->cycles != board.cycle) {
            fprintf(stderr, "cycle mismatch for '%s'\n", buf);
            fprintf(stderr, "solution file says cycle count is: %" PRIu32 "\n", sf->cycles);
            fprintf(stderr, "simulation says cycle count is: %" PRIu64 "\n", board.cycle);
            goto fail;
        }
        uint32_t area = used_area(&board);
        if (!puzzle->pf->production_info && sf->area != area) {
            fprintf(stderr, "area mismatch for '%s'\n", buf);
            fprintf(stderr, "solution file says area is: %" PRIu32 "\n", sf->area);
            fprintf(stderr, "simulation says area is: %" PRIu32 "\n", area);
            goto fail;
        }
    success:
#if MEASURE_TIMES
        clock_gettime(CLOCK_MONOTONIC, &tend);
        printf("%.5f C=%" PRIu64 " A=%" PRIu32 " %s\n",
               ((double)tend.tv_sec + 1.0e-9*tend.tv_nsec) -
               ((double)tstart.tv_sec + 1.0e-9*tstart.tv_nsec),
               board.cycle,
               used_area(&board),
               buf);
#endif
        validated_solutions++;
    fail:
        destroy(&solution, &board);
        free_solution_file(sf);
    }
    free_paths();

    fprintf(stderr, "%d / %d solutions validated!\n", validated_solutions, total_solutions);

    struct puzzle *puzzle = puzzles;
    while (puzzle) {
        struct puzzle *next = puzzle->next;
        free_puzzle_file(puzzle->pf);
        free(puzzle->filename);
        free(puzzle);
        puzzle = next;
    }
}
