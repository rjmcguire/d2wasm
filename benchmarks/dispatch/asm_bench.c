/**
 * Dispatch benchmark using inline ARM64 assembly in C.
 * Compile with: clang -O3 -o asm_bench asm_bench.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

typedef struct {
    uint32_t typeId;
    int32_t data;
} Obj;

// Method results table
static int methodResults[256];

__attribute__((constructor))
void init_results(void) {
    for (int i = 0; i < 256; i++) {
        methodResults[i] = i * 7 + 13;
    }
}

// Vtable-style dispatch: load typeId, index into table
__attribute__((noinline))
int vtable_dispatch(Obj* obj) {
    int result;
    int* table = methodResults;
    
    __asm__ volatile (
        "ldr w8, [%1]\n\t"           // Load typeId
        "ldr %w0, [%2, w8, uxtw #2]" // Load table[typeId]
        : "=r" (result)
        : "r" (obj), "r" (table)
        : "w8"
    );
    
    return result + obj->data;
}

// Chain dispatch 4 types
__attribute__((noinline))
int chain_dispatch_4(Obj* obj) {
    int result;
    
    __asm__ volatile (
        "ldr w8, [%1]\n\t"
        "cmp w8, #0\n\t"
        "b.eq 1f\n\t"
        "cmp w8, #1\n\t"
        "b.eq 2f\n\t"
        "cmp w8, #2\n\t"
        "b.eq 3f\n\t"
        "cmp w8, #3\n\t"
        "b.eq 4f\n\t"
        "mov w9, #-1\n\t"
        "b 5f\n\t"
        "1: mov w9, #13\n\t"
        "b 5f\n\t"
        "2: mov w9, #20\n\t"
        "b 5f\n\t"
        "3: mov w9, #27\n\t"
        "b 5f\n\t"
        "4: mov w9, #34\n\t"
        "5: mov %w0, w9"
        : "=r" (result)
        : "r" (obj)
        : "w8", "w9"
    );
    
    return result + obj->data;
}

// Chain dispatch 8 types
__attribute__((noinline))
int chain_dispatch_8(Obj* obj) {
    int result;
    
    __asm__ volatile (
        "ldr w8, [%1]\n\t"
        "cmp w8, #0\n\t" "b.eq 10f\n\t"
        "cmp w8, #1\n\t" "b.eq 11f\n\t"
        "cmp w8, #2\n\t" "b.eq 12f\n\t"
        "cmp w8, #3\n\t" "b.eq 13f\n\t"
        "cmp w8, #4\n\t" "b.eq 14f\n\t"
        "cmp w8, #5\n\t" "b.eq 15f\n\t"
        "cmp w8, #6\n\t" "b.eq 16f\n\t"
        "cmp w8, #7\n\t" "b.eq 17f\n\t"
        "mov w9, #-1\n\t" "b 20f\n\t"
        "10: mov w9, #13\n\t" "b 20f\n\t"
        "11: mov w9, #20\n\t" "b 20f\n\t"
        "12: mov w9, #27\n\t" "b 20f\n\t"
        "13: mov w9, #34\n\t" "b 20f\n\t"
        "14: mov w9, #41\n\t" "b 20f\n\t"
        "15: mov w9, #48\n\t" "b 20f\n\t"
        "16: mov w9, #55\n\t" "b 20f\n\t"
        "17: mov w9, #62\n\t"
        "20: mov %w0, w9"
        : "=r" (result)
        : "r" (obj)
        : "w8", "w9"
    );
    
    return result + obj->data;
}

// Chain dispatch 16 types
__attribute__((noinline))
int chain_dispatch_16(Obj* obj) {
    int result;
    
    __asm__ volatile (
        "ldr w8, [%1]\n\t"
        "cmp w8, #0\n\t"  "b.eq 100f\n\t"
        "cmp w8, #1\n\t"  "b.eq 101f\n\t"
        "cmp w8, #2\n\t"  "b.eq 102f\n\t"
        "cmp w8, #3\n\t"  "b.eq 103f\n\t"
        "cmp w8, #4\n\t"  "b.eq 104f\n\t"
        "cmp w8, #5\n\t"  "b.eq 105f\n\t"
        "cmp w8, #6\n\t"  "b.eq 106f\n\t"
        "cmp w8, #7\n\t"  "b.eq 107f\n\t"
        "cmp w8, #8\n\t"  "b.eq 108f\n\t"
        "cmp w8, #9\n\t"  "b.eq 109f\n\t"
        "cmp w8, #10\n\t" "b.eq 110f\n\t"
        "cmp w8, #11\n\t" "b.eq 111f\n\t"
        "cmp w8, #12\n\t" "b.eq 112f\n\t"
        "cmp w8, #13\n\t" "b.eq 113f\n\t"
        "cmp w8, #14\n\t" "b.eq 114f\n\t"
        "cmp w8, #15\n\t" "b.eq 115f\n\t"
        "mov w9, #-1\n\t" "b 200f\n\t"
        "100: mov w9, #13\n\t"  "b 200f\n\t"
        "101: mov w9, #20\n\t"  "b 200f\n\t"
        "102: mov w9, #27\n\t"  "b 200f\n\t"
        "103: mov w9, #34\n\t"  "b 200f\n\t"
        "104: mov w9, #41\n\t"  "b 200f\n\t"
        "105: mov w9, #48\n\t"  "b 200f\n\t"
        "106: mov w9, #55\n\t"  "b 200f\n\t"
        "107: mov w9, #62\n\t"  "b 200f\n\t"
        "108: mov w9, #69\n\t"  "b 200f\n\t"
        "109: mov w9, #76\n\t"  "b 200f\n\t"
        "110: mov w9, #83\n\t"  "b 200f\n\t"
        "111: mov w9, #90\n\t"  "b 200f\n\t"
        "112: mov w9, #97\n\t"  "b 200f\n\t"
        "113: mov w9, #104\n\t" "b 200f\n\t"
        "114: mov w9, #111\n\t" "b 200f\n\t"
        "115: mov w9, #118\n\t"
        "200: mov %w0, w9"
        : "=r" (result)
        : "r" (obj)
        : "w8", "w9"
    );
    
    return result + obj->data;
}

// Chain dispatch 32 types
__attribute__((noinline))
int chain_dispatch_32(Obj* obj) {
    int result;
    
    __asm__ volatile (
        "ldr w8, [%1]\n\t"
        "cmp w8, #0\n\t"  "b.eq 300f\n\t"
        "cmp w8, #1\n\t"  "b.eq 301f\n\t"
        "cmp w8, #2\n\t"  "b.eq 302f\n\t"
        "cmp w8, #3\n\t"  "b.eq 303f\n\t"
        "cmp w8, #4\n\t"  "b.eq 304f\n\t"
        "cmp w8, #5\n\t"  "b.eq 305f\n\t"
        "cmp w8, #6\n\t"  "b.eq 306f\n\t"
        "cmp w8, #7\n\t"  "b.eq 307f\n\t"
        "cmp w8, #8\n\t"  "b.eq 308f\n\t"
        "cmp w8, #9\n\t"  "b.eq 309f\n\t"
        "cmp w8, #10\n\t" "b.eq 310f\n\t"
        "cmp w8, #11\n\t" "b.eq 311f\n\t"
        "cmp w8, #12\n\t" "b.eq 312f\n\t"
        "cmp w8, #13\n\t" "b.eq 313f\n\t"
        "cmp w8, #14\n\t" "b.eq 314f\n\t"
        "cmp w8, #15\n\t" "b.eq 315f\n\t"
        "cmp w8, #16\n\t" "b.eq 316f\n\t"
        "cmp w8, #17\n\t" "b.eq 317f\n\t"
        "cmp w8, #18\n\t" "b.eq 318f\n\t"
        "cmp w8, #19\n\t" "b.eq 319f\n\t"
        "cmp w8, #20\n\t" "b.eq 320f\n\t"
        "cmp w8, #21\n\t" "b.eq 321f\n\t"
        "cmp w8, #22\n\t" "b.eq 322f\n\t"
        "cmp w8, #23\n\t" "b.eq 323f\n\t"
        "cmp w8, #24\n\t" "b.eq 324f\n\t"
        "cmp w8, #25\n\t" "b.eq 325f\n\t"
        "cmp w8, #26\n\t" "b.eq 326f\n\t"
        "cmp w8, #27\n\t" "b.eq 327f\n\t"
        "cmp w8, #28\n\t" "b.eq 328f\n\t"
        "cmp w8, #29\n\t" "b.eq 329f\n\t"
        "cmp w8, #30\n\t" "b.eq 330f\n\t"
        "cmp w8, #31\n\t" "b.eq 331f\n\t"
        "mov w9, #-1\n\t" "b 400f\n\t"
        "300: mov w9, #13\n\t"  "b 400f\n\t"
        "301: mov w9, #20\n\t"  "b 400f\n\t"
        "302: mov w9, #27\n\t"  "b 400f\n\t"
        "303: mov w9, #34\n\t"  "b 400f\n\t"
        "304: mov w9, #41\n\t"  "b 400f\n\t"
        "305: mov w9, #48\n\t"  "b 400f\n\t"
        "306: mov w9, #55\n\t"  "b 400f\n\t"
        "307: mov w9, #62\n\t"  "b 400f\n\t"
        "308: mov w9, #69\n\t"  "b 400f\n\t"
        "309: mov w9, #76\n\t"  "b 400f\n\t"
        "310: mov w9, #83\n\t"  "b 400f\n\t"
        "311: mov w9, #90\n\t"  "b 400f\n\t"
        "312: mov w9, #97\n\t"  "b 400f\n\t"
        "313: mov w9, #104\n\t" "b 400f\n\t"
        "314: mov w9, #111\n\t" "b 400f\n\t"
        "315: mov w9, #118\n\t" "b 400f\n\t"
        "316: mov w9, #125\n\t" "b 400f\n\t"
        "317: mov w9, #132\n\t" "b 400f\n\t"
        "318: mov w9, #139\n\t" "b 400f\n\t"
        "319: mov w9, #146\n\t" "b 400f\n\t"
        "320: mov w9, #153\n\t" "b 400f\n\t"
        "321: mov w9, #160\n\t" "b 400f\n\t"
        "322: mov w9, #167\n\t" "b 400f\n\t"
        "323: mov w9, #174\n\t" "b 400f\n\t"
        "324: mov w9, #181\n\t" "b 400f\n\t"
        "325: mov w9, #188\n\t" "b 400f\n\t"
        "326: mov w9, #195\n\t" "b 400f\n\t"
        "327: mov w9, #202\n\t" "b 400f\n\t"
        "328: mov w9, #209\n\t" "b 400f\n\t"
        "329: mov w9, #216\n\t" "b 400f\n\t"
        "330: mov w9, #223\n\t" "b 400f\n\t"
        "331: mov w9, #230\n\t"
        "400: mov %w0, w9"
        : "=r" (result)
        : "r" (obj)
        : "w8", "w9"
    );
    
    return result + obj->data;
}

// Chain dispatch 64 types
__attribute__((noinline))
int chain_dispatch_64(Obj* obj) {
    int result;
    
    __asm__ volatile (
        "ldr w8, [%1]\n\t"
        // 0-31
        "cmp w8, #0\n\t"  "b.eq 500f\n\t"
        "cmp w8, #1\n\t"  "b.eq 501f\n\t"
        "cmp w8, #2\n\t"  "b.eq 502f\n\t"
        "cmp w8, #3\n\t"  "b.eq 503f\n\t"
        "cmp w8, #4\n\t"  "b.eq 504f\n\t"
        "cmp w8, #5\n\t"  "b.eq 505f\n\t"
        "cmp w8, #6\n\t"  "b.eq 506f\n\t"
        "cmp w8, #7\n\t"  "b.eq 507f\n\t"
        "cmp w8, #8\n\t"  "b.eq 508f\n\t"
        "cmp w8, #9\n\t"  "b.eq 509f\n\t"
        "cmp w8, #10\n\t" "b.eq 510f\n\t"
        "cmp w8, #11\n\t" "b.eq 511f\n\t"
        "cmp w8, #12\n\t" "b.eq 512f\n\t"
        "cmp w8, #13\n\t" "b.eq 513f\n\t"
        "cmp w8, #14\n\t" "b.eq 514f\n\t"
        "cmp w8, #15\n\t" "b.eq 515f\n\t"
        "cmp w8, #16\n\t" "b.eq 516f\n\t"
        "cmp w8, #17\n\t" "b.eq 517f\n\t"
        "cmp w8, #18\n\t" "b.eq 518f\n\t"
        "cmp w8, #19\n\t" "b.eq 519f\n\t"
        "cmp w8, #20\n\t" "b.eq 520f\n\t"
        "cmp w8, #21\n\t" "b.eq 521f\n\t"
        "cmp w8, #22\n\t" "b.eq 522f\n\t"
        "cmp w8, #23\n\t" "b.eq 523f\n\t"
        "cmp w8, #24\n\t" "b.eq 524f\n\t"
        "cmp w8, #25\n\t" "b.eq 525f\n\t"
        "cmp w8, #26\n\t" "b.eq 526f\n\t"
        "cmp w8, #27\n\t" "b.eq 527f\n\t"
        "cmp w8, #28\n\t" "b.eq 528f\n\t"
        "cmp w8, #29\n\t" "b.eq 529f\n\t"
        "cmp w8, #30\n\t" "b.eq 530f\n\t"
        "cmp w8, #31\n\t" "b.eq 531f\n\t"
        // 32-63
        "cmp w8, #32\n\t" "b.eq 532f\n\t"
        "cmp w8, #33\n\t" "b.eq 533f\n\t"
        "cmp w8, #34\n\t" "b.eq 534f\n\t"
        "cmp w8, #35\n\t" "b.eq 535f\n\t"
        "cmp w8, #36\n\t" "b.eq 536f\n\t"
        "cmp w8, #37\n\t" "b.eq 537f\n\t"
        "cmp w8, #38\n\t" "b.eq 538f\n\t"
        "cmp w8, #39\n\t" "b.eq 539f\n\t"
        "cmp w8, #40\n\t" "b.eq 540f\n\t"
        "cmp w8, #41\n\t" "b.eq 541f\n\t"
        "cmp w8, #42\n\t" "b.eq 542f\n\t"
        "cmp w8, #43\n\t" "b.eq 543f\n\t"
        "cmp w8, #44\n\t" "b.eq 544f\n\t"
        "cmp w8, #45\n\t" "b.eq 545f\n\t"
        "cmp w8, #46\n\t" "b.eq 546f\n\t"
        "cmp w8, #47\n\t" "b.eq 547f\n\t"
        "cmp w8, #48\n\t" "b.eq 548f\n\t"
        "cmp w8, #49\n\t" "b.eq 549f\n\t"
        "cmp w8, #50\n\t" "b.eq 550f\n\t"
        "cmp w8, #51\n\t" "b.eq 551f\n\t"
        "cmp w8, #52\n\t" "b.eq 552f\n\t"
        "cmp w8, #53\n\t" "b.eq 553f\n\t"
        "cmp w8, #54\n\t" "b.eq 554f\n\t"
        "cmp w8, #55\n\t" "b.eq 555f\n\t"
        "cmp w8, #56\n\t" "b.eq 556f\n\t"
        "cmp w8, #57\n\t" "b.eq 557f\n\t"
        "cmp w8, #58\n\t" "b.eq 558f\n\t"
        "cmp w8, #59\n\t" "b.eq 559f\n\t"
        "cmp w8, #60\n\t" "b.eq 560f\n\t"
        "cmp w8, #61\n\t" "b.eq 561f\n\t"
        "cmp w8, #62\n\t" "b.eq 562f\n\t"
        "cmp w8, #63\n\t" "b.eq 563f\n\t"
        "mov w9, #-1\n\t" "b 600f\n\t"
        // Results 0-31
        "500: mov w9, #13\n\t"  "b 600f\n\t"
        "501: mov w9, #20\n\t"  "b 600f\n\t"
        "502: mov w9, #27\n\t"  "b 600f\n\t"
        "503: mov w9, #34\n\t"  "b 600f\n\t"
        "504: mov w9, #41\n\t"  "b 600f\n\t"
        "505: mov w9, #48\n\t"  "b 600f\n\t"
        "506: mov w9, #55\n\t"  "b 600f\n\t"
        "507: mov w9, #62\n\t"  "b 600f\n\t"
        "508: mov w9, #69\n\t"  "b 600f\n\t"
        "509: mov w9, #76\n\t"  "b 600f\n\t"
        "510: mov w9, #83\n\t"  "b 600f\n\t"
        "511: mov w9, #90\n\t"  "b 600f\n\t"
        "512: mov w9, #97\n\t"  "b 600f\n\t"
        "513: mov w9, #104\n\t" "b 600f\n\t"
        "514: mov w9, #111\n\t" "b 600f\n\t"
        "515: mov w9, #118\n\t" "b 600f\n\t"
        "516: mov w9, #125\n\t" "b 600f\n\t"
        "517: mov w9, #132\n\t" "b 600f\n\t"
        "518: mov w9, #139\n\t" "b 600f\n\t"
        "519: mov w9, #146\n\t" "b 600f\n\t"
        "520: mov w9, #153\n\t" "b 600f\n\t"
        "521: mov w9, #160\n\t" "b 600f\n\t"
        "522: mov w9, #167\n\t" "b 600f\n\t"
        "523: mov w9, #174\n\t" "b 600f\n\t"
        "524: mov w9, #181\n\t" "b 600f\n\t"
        "525: mov w9, #188\n\t" "b 600f\n\t"
        "526: mov w9, #195\n\t" "b 600f\n\t"
        "527: mov w9, #202\n\t" "b 600f\n\t"
        "528: mov w9, #209\n\t" "b 600f\n\t"
        "529: mov w9, #216\n\t" "b 600f\n\t"
        "530: mov w9, #223\n\t" "b 600f\n\t"
        "531: mov w9, #230\n\t" "b 600f\n\t"
        // Results 32-63
        "532: mov w9, #237\n\t" "b 600f\n\t"
        "533: mov w9, #244\n\t" "b 600f\n\t"
        "534: mov w9, #251\n\t" "b 600f\n\t"
        "535: mov w9, #258\n\t" "b 600f\n\t"
        "536: mov w9, #265\n\t" "b 600f\n\t"
        "537: mov w9, #272\n\t" "b 600f\n\t"
        "538: mov w9, #279\n\t" "b 600f\n\t"
        "539: mov w9, #286\n\t" "b 600f\n\t"
        "540: mov w9, #293\n\t" "b 600f\n\t"
        "541: mov w9, #300\n\t" "b 600f\n\t"
        "542: mov w9, #307\n\t" "b 600f\n\t"
        "543: mov w9, #314\n\t" "b 600f\n\t"
        "544: mov w9, #321\n\t" "b 600f\n\t"
        "545: mov w9, #328\n\t" "b 600f\n\t"
        "546: mov w9, #335\n\t" "b 600f\n\t"
        "547: mov w9, #342\n\t" "b 600f\n\t"
        "548: mov w9, #349\n\t" "b 600f\n\t"
        "549: mov w9, #356\n\t" "b 600f\n\t"
        "550: mov w9, #363\n\t" "b 600f\n\t"
        "551: mov w9, #370\n\t" "b 600f\n\t"
        "552: mov w9, #377\n\t" "b 600f\n\t"
        "553: mov w9, #384\n\t" "b 600f\n\t"
        "554: mov w9, #391\n\t" "b 600f\n\t"
        "555: mov w9, #398\n\t" "b 600f\n\t"
        "556: mov w9, #405\n\t" "b 600f\n\t"
        "557: mov w9, #412\n\t" "b 600f\n\t"
        "558: mov w9, #419\n\t" "b 600f\n\t"
        "559: mov w9, #426\n\t" "b 600f\n\t"
        "560: mov w9, #433\n\t" "b 600f\n\t"
        "561: mov w9, #440\n\t" "b 600f\n\t"
        "562: mov w9, #447\n\t" "b 600f\n\t"
        "563: mov w9, #454\n\t"
        "600: mov %w0, w9"
        : "=r" (result)
        : "r" (obj)
        : "w8", "w9"
    );
    
    return result + obj->data;
}

#define ITERATIONS 50000000
#define POOL_SIZE 10000

typedef int (*chain_fn)(Obj*);

typedef struct {
    int types;
    chain_fn fn;
} TestCase;

double bench(const char* name, Obj* objs, chain_fn dispatch, long iterations) {
    int sum = 0;
    struct timespec start, end;
    
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (long i = 0; i < iterations; i++) {
        sum += dispatch(&objs[i % POOL_SIZE]);
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    
    double elapsed = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    double ns_per_op = (elapsed * 1e9) / iterations;
    
    // Prevent optimization
    if (sum == 0x12345678) printf("x");
    
    return ns_per_op;
}

void run_test(const char* scenario, int num_types, chain_fn chain, Obj* objs) {
    double vtable_ns = bench("vtable", objs, vtable_dispatch, ITERATIONS);
    double chain_ns = bench("chain", objs, chain, ITERATIONS);
    double ratio = chain_ns / vtable_ns;
    const char* winner = ratio < 1.0 ? "CHAIN" : "VTABLE";
    const char* marker = (ratio < 1.0/7.0 || ratio > 7.0) ? " <<< >7x!" : "";
    
    printf("%-12s %3d types | vtable: %6.2f ns | chain: %6.2f ns | ratio: %5.2fx | %s%s\n",
        scenario, num_types, vtable_ns, chain_ns, ratio, winner, marker);
}

int main() {
    printf("=== ASM Dispatch Benchmark (ARM64) ===\n");
    printf("Measuring actual instruction costs\n\n");
    
    TestCase tests[] = {
        {4, chain_dispatch_4},
        {8, chain_dispatch_8},
        {16, chain_dispatch_16},
        {32, chain_dispatch_32},
        {64, chain_dispatch_64},
    };
    int num_tests = sizeof(tests) / sizeof(tests[0]);
    
    // Uniform distribution
    printf("--- Uniform Distribution ---\n");
    for (int t = 0; t < num_tests; t++) {
        Obj* objs = malloc(POOL_SIZE * sizeof(Obj));
        for (int i = 0; i < POOL_SIZE; i++) {
            objs[i].typeId = i % tests[t].types;
            objs[i].data = i;
        }
        run_test("uniform", tests[t].types, tests[t].fn, objs);
        free(objs);
    }
    
    // Monomorphic
    printf("\n--- Monomorphic (type 0) ---\n");
    for (int t = 0; t < num_tests; t++) {
        Obj* objs = malloc(POOL_SIZE * sizeof(Obj));
        for (int i = 0; i < POOL_SIZE; i++) {
            objs[i].typeId = 0;
            objs[i].data = i;
        }
        run_test("mono", tests[t].types, tests[t].fn, objs);
        free(objs);
    }
    
    // Worst case
    printf("\n--- Worst Case (last type) ---\n");
    for (int t = 0; t < num_tests; t++) {
        Obj* objs = malloc(POOL_SIZE * sizeof(Obj));
        for (int i = 0; i < POOL_SIZE; i++) {
            objs[i].typeId = tests[t].types - 1;
            objs[i].data = i;
        }
        run_test("worst", tests[t].types, tests[t].fn, objs);
        free(objs);
    }
    
    // Random
    printf("\n--- Random Distribution ---\n");
    srand(42);
    for (int t = 0; t < num_tests; t++) {
        Obj* objs = malloc(POOL_SIZE * sizeof(Obj));
        for (int i = 0; i < POOL_SIZE; i++) {
            objs[i].typeId = rand() % tests[t].types;
            objs[i].data = i;
        }
        run_test("random", tests[t].types, tests[t].fn, objs);
        free(objs);
    }
    
    printf("\nNote: ratio < 1 = chain wins, > 1 = vtable wins\n");
    
    return 0;
}
