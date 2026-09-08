#include "decode.h"
#include "parse.h"
#include "sim.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t hash_state(struct board *b, uint64_t *out_count)
{
    uint64_t h = 1469598103934665603ull;
    size_t capacity = BOARD_CAPACITY(b);
    uint64_t count = 0;
    for (size_t i = 0; i < capacity; ++i) {
        struct atom_at_position ap = b->grid.atoms_at_positions[i];
        if (!(ap.atom & VALID))
            continue;
        if (ap.atom & REMOVED)
            continue; // area marks are intentionally absent in OFF mode.
        count++;
        h = (h ^ (uint32_t)ap.position.u) * 1099511628211ull;
        h = (h ^ (uint32_t)ap.position.v) * 1099511628211ull;
        h = (h ^ ap.atom) * 1099511628211ull;
    }
    if (out_count)
        *out_count = count;
    return h;
}

static void print_state(struct board *b)
{
    size_t capacity = BOARD_CAPACITY(b);
    for (size_t i = 0; i < capacity; ++i) {
        struct atom_at_position ap = b->grid.atoms_at_positions[i];
        if (!(ap.atom & VALID) || (ap.atom & REMOVED))
            continue;
        printf("  atom %d %d %016llx\n", ap.position.u, ap.position.v, (unsigned long long)ap.atom);
    }
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: divergence <puzzle> <solution> <cycles>\n");
        return 1;
    }
    uint64_t target = strtoull(argv[3], NULL, 10);
    struct puzzle_file *pf = parse_puzzle_file(argv[1]);
    struct solution_file *sf = parse_solution_file(argv[2]);
    if (!pf || !sf) {
        fprintf(stderr, "couldn't parse input files\n");
        return 2;
    }
    struct solution on_sol = { 0 }, off_sol = { 0 };
    struct board on_board = { 0 }, off_board = { 0 };
    const char *error = NULL;
    if (!decode_solution(&on_sol, pf, sf, &error) || !decode_solution(&off_sol, pf, sf, &error))
        return 2;
    initial_setup(&on_sol, &on_board, sf->area);
    initial_setup(&off_sol, &off_board, sf->area);
    off_board.collision_detection_disabled = true;
    for (uint64_t i = 0; i < target; ++i) {
        run(&on_sol, &on_board);
        run(&off_sol, &off_board);
        uint64_t on_count, off_count;
        uint64_t on_h = hash_state(&on_board, &on_count);
        uint64_t off_h = hash_state(&off_board, &off_count);
        if (on_h != off_h || on_count != off_count || on_board.complete != off_board.complete) {
            printf("first divergence at cycle %llu (counts live %llu vs %llu, complete %d vs %d, on.collision=%d)\n",
             (unsigned long long)(i + 1), (unsigned long long)on_count, (unsigned long long)off_count,
             on_board.complete, off_board.complete, on_board.collision);
            printf("ON (%d atoms):\n", (int)on_count);
            print_state(&on_board);
            printf("OFF (%d atoms):\n", (int)off_count);
            print_state(&off_board);
            return 0;
        }
        if (on_board.collision) {
            printf("ON collided at cycle %llu, stopping comparison\n", (unsigned long long)(i + 1));
            return 0;
        }
    }
    printf("no divergence within %llu cycles\n", (unsigned long long)target);
    return 0;
}
