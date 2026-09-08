#include "decode.h"
#include "parse.h"
#include "sim.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct live_atom {
    int32_t u;
    int32_t v;
    uint64_t atom;
};
static int compare_live(const void *x, const void *y)
{
    const struct live_atom *a = x, *b = y;
    if (a->u != b->u)
        return a->u < b->u ? -1 : 1;
    if (a->v != b->v)
        return a->v < b->v ? -1 : 1;
    if (a->atom != b->atom)
        return a->atom < b->atom ? -1 : 1;
    return 0;
}

int main(int argc, char **argv)
{
    int off = 0;
    if (argc < 4) {
        fprintf(stderr, "usage: state_dump <puzzle> <solution> <cycles> [off]\n");
        return 1;
    }
    if (argc > 4)
        off = argv[4][0] == '1';
    uint64_t target = strtoull(argv[3], NULL, 10);
    struct puzzle_file *pf = parse_puzzle_file(argv[1]);
    struct solution_file *sf = parse_solution_file(argv[2]);
    if (!pf || !sf) {
        fprintf(stderr, "couldn't parse input files\n");
        return 2;
    }
    struct solution solution = { 0 };
    struct board board = { 0 };
    const char *error = NULL;
    if (!decode_solution(&solution, pf, sf, &error)) {
        fprintf(stderr, "decode error: %s\n", error ? error : "?");
        return 2;
    }
    initial_setup(&solution, &board, sf->area);
    if (off)
        board.collision_detection_disabled = true;
    while (board.cycle < target && !board.collision)
        run(&solution, &board);

    printf("off=%d\n", off);
    printf("cycle=%llu\n", (unsigned long long)board.cycle);
    printf("collision=%d\n", board.collision ? 1 : 0);
    printf("complete=%d\n", board.complete ? 1 : 0);
    printf("board.area=%u\n", board.area);
    printf("used_area=%u\n", used_area(&board));
    printf("overlap=%llu\n", (unsigned long long)board.overlap);
    printf("overlapped_atoms=%u\n", board.number_of_overlapped_atoms);
    printf("output_cycles=%llu\n", (unsigned long long)board.number_of_output_cycles);
    for (uint64_t i = 0; i < board.number_of_output_cycles; ++i)
        printf("output_cycle[%llu]=%llu\n", (unsigned long long)i,
         (unsigned long long)board.output_cycles[i]);
    printf("chain_atoms=%u\n", board.number_of_chain_atoms);

    size_t capacity = BOARD_CAPACITY(&board);
    struct live_atom *live = calloc(capacity, sizeof(struct live_atom));
    size_t count = 0;
    for (size_t i = 0; i < capacity; ++i) {
        struct atom_at_position ap = board.grid.atoms_at_positions[i];
        if (!(ap.atom & VALID) || (ap.atom & REMOVED))
            continue;
        live[count++] = (struct live_atom){ ap.position.u, ap.position.v, ap.atom };
    }
    qsort(live, count, sizeof(struct live_atom), compare_live);
    printf("live_atoms=%zu\n", count);
    for (size_t i = 0; i < count; ++i)
        printf("atom %d %d %016llx\n", live[i].u, live[i].v,
         (unsigned long long)live[i].atom);
    free(live);
    destroy(&solution, &board);
    return 0;
}
