#include "decode.h"
#include "parse.h"
#include "sim.h"

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int path_is_directory(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && (st.st_mode & S_IFDIR);
}

#define MAX_PUZZLES 4096
#define MAX_PATH_LEN 1024
#define TRAIN_CYCLE_CAP 30000

struct puzzle_entry {
    char name[MAX_PATH_LEN];
    struct puzzle_file *pf;
};

static struct puzzle_entry puzzles[MAX_PUZZLES];
static int number_of_puzzles;

static void collect_puzzles(const char *dir)
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
            collect_puzzles(path);
            continue;
        }
        const char *dot = strrchr(e->d_name, '.');
        if (!dot || strcmp(dot, ".puzzle") != 0 || number_of_puzzles >= MAX_PUZZLES)
            continue;
        struct puzzle_file *pf = parse_puzzle_file(path);
        if (!pf)
            continue;
        struct puzzle_entry *p = &puzzles[number_of_puzzles++];
        snprintf(p->name, sizeof(p->name), "%.*s", (int)(dot - e->d_name), e->d_name);
        p->pf = pf;
    }
    closedir(d);
}

static int train_solution(const char *path, int off)
{
    struct solution_file *sf = parse_solution_file(path);
    if (!sf)
        return 0;
    struct puzzle_entry *p = NULL;
    for (int i = 0; i < number_of_puzzles; ++i) {
        if (byte_string_is(sf->puzzle, puzzles[i].name)) {
            p = &puzzles[i];
            break;
        }
    }
    if (!p) {
        free_solution_file(sf);
        return 0;
    }
    struct solution solution = { 0 };
    struct board board = { 0 };
    const char *error = NULL;
    if (!decode_solution(&solution, p->pf, sf, &error)) {
        free_solution_file(sf);
        return 0;
    }
    initial_setup(&solution, &board, sf->area);
    board.collision_detection_disabled = off != 0;
    fprintf(stderr, "train %s [off=%d]\n", path, off);
    int collided = 0;
    while (board.cycle < TRAIN_CYCLE_CAP && !board.complete && !board.collision) {
        run(&solution, &board);
        if (board.area > 20000) {
            fprintf(stderr, "skipping runaway board (%u hexes): %s [off=%d]\n", board.area, path, off);
            break;
        }
    }
    collided = board.collision != 0;
    destroy(&solution, &board);
    free_solution_file(sf);
    return collided;
}

static void collect_solutions(const char *dir)
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
            collect_solutions(path);
            continue;
        }
        const char *dot = strrchr(e->d_name, '.');
        if (!dot || strcmp(dot, ".solution") != 0)
            continue;
        // OFF mode is only well-defined for solutions that do not collide:
        // skip the OFF pass when the ON run reports a collision.
        if (train_solution(path, 0) == 0)
            train_solution(path, 1);
    }
    closedir(d);
}

int main(void)
{
    collect_puzzles("test/puzzle");
    fprintf(stderr, "loaded %d puzzles\n", number_of_puzzles);
    collect_solutions("test/solution");
    fprintf(stderr, "training done\n");
    return 0;
}
