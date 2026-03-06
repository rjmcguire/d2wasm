/*
 * FFI Trampoline — Generic libffi-based bridge for WASM extern(C) calls
 *
 * Provides a single universal trampoline function that marshals WASM values
 * to native calling convention via libffi. Each imported function gets an
 * FFIDescriptor that describes how to translate its arguments.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <ffi/ffi.h>

#include "wasm3.h"
#include "m3_env.h"

/* ArgKind enum — must match emitter.d's ArgKind */
typedef enum {
    ARG_I32  = 0,
    ARG_I64  = 1,
    ARG_F32  = 2,
    ARG_F64  = 3,
    ARG_PTR  = 4,   /* WASM i32 offset → native pointer (memory_base + offset) */
    RET_VOID = 5,
} ArgKind;

typedef struct {
    const char  *name;          /* for debug logging */
    void        *fn_ptr;        /* dlsym'd native function pointer */
    ffi_cif      cif;           /* pre-built libffi call info */
    int          nargs;         /* number of WASM-side args */
    ArgKind      ret_kind;
    ArgKind     *arg_kinds;     /* how to marshal each arg from WASM stack */
    ffi_type   **ffi_arg_types; /* libffi type array */
} FFIDescriptor;

/* ---------------------------------------------------------------------------
 * ArgKind → ffi_type mapping
 * ---------------------------------------------------------------------------*/

static ffi_type *argkind_to_ffi_type(ArgKind k) {
    switch (k) {
        case ARG_I32:  return &ffi_type_sint32;
        case ARG_I64:  return &ffi_type_sint64;
        case ARG_F32:  return &ffi_type_float;
        case ARG_F64:  return &ffi_type_double;
        case ARG_PTR:  return &ffi_type_pointer;
        default:       return &ffi_type_void;
    }
}

static ffi_type *retkind_to_ffi_type(ArgKind k) {
    if (k == RET_VOID) return &ffi_type_void;
    return argkind_to_ffi_type(k);
}

/* ---------------------------------------------------------------------------
 * Descriptor construction (called from D via extern(C))
 * ---------------------------------------------------------------------------*/

FFIDescriptor *ffi_make_descriptor(const char *name, void *fn_ptr,
                                   int ret_kind, int nargs, int *arg_kinds) {
    FFIDescriptor *d = calloc(1, sizeof(FFIDescriptor));
    d->name = name;
    d->fn_ptr = fn_ptr;
    d->nargs = nargs;
    d->ret_kind = (ArgKind)ret_kind;
    d->arg_kinds = calloc(nargs, sizeof(ArgKind));
    d->ffi_arg_types = calloc(nargs, sizeof(ffi_type*));

    for (int i = 0; i < nargs; i++) {
        d->arg_kinds[i] = (ArgKind)arg_kinds[i];
        d->ffi_arg_types[i] = argkind_to_ffi_type(d->arg_kinds[i]);
    }

    ffi_type *ret_ffi = retkind_to_ffi_type(d->ret_kind);

    ffi_status status = ffi_prep_cif(&d->cif, FFI_DEFAULT_ABI, nargs, ret_ffi, d->ffi_arg_types);
    if (status != FFI_OK) {
        fprintf(stderr, "ffi_trampoline: ffi_prep_cif failed for %s (status=%d)\n", name, status);
        free(d->arg_kinds);
        free(d->ffi_arg_types);
        free(d);
        return NULL;
    }

    return d;
}

void ffi_free_descriptor(FFIDescriptor *d) {
    if (!d) return;
    free(d->arg_kinds);
    free(d->ffi_arg_types);
    free(d);
}

/* ---------------------------------------------------------------------------
 * The one generic trampoline (m3ApiRawFunction signature)
 * ---------------------------------------------------------------------------*/

const void *ffi_generic_trampoline(IM3Runtime runtime, IM3ImportContext _ctx,
                                   uint64_t *_sp, void *_mem) {
    (void)runtime;
    FFIDescriptor *desc = (FFIDescriptor *)_ctx->userdata;

    /* wasm3 convention: _sp[0] is the return slot when function has a return value */
    uint64_t *sp = _sp;
    int has_return = (desc->cif.rtype != &ffi_type_void);
    if (has_return) sp++;  /* skip return slot */

    /* Marshal arguments from WASM stack */
    void *arg_values[32];
    union {
        int32_t  i32;
        int64_t  i64;
        float    f32;
        double   f64;
        void    *ptr;
    } arg_storage[32];

    for (int i = 0; i < desc->nargs && i < 32; i++) {
        switch (desc->arg_kinds[i]) {
            case ARG_I32:
                arg_storage[i].i32 = *(int32_t *)sp;
                arg_values[i] = &arg_storage[i].i32;
                sp++;
                break;
            case ARG_I64:
                arg_storage[i].i64 = *(int64_t *)sp;
                arg_values[i] = &arg_storage[i].i64;
                sp++;
                break;
            case ARG_F32:
                arg_storage[i].f32 = *(float *)sp;
                arg_values[i] = &arg_storage[i].f32;
                sp++;
                break;
            case ARG_F64:
                arg_storage[i].f64 = *(double *)sp;
                arg_values[i] = &arg_storage[i].f64;
                sp++;
                break;
            case ARG_PTR: {
                uint32_t offset = *(uint32_t *)sp;
                arg_storage[i].ptr = (void *)((uint8_t *)_mem + offset);
                arg_values[i] = &arg_storage[i].ptr;
                sp++;
                break;
            }
            default:
                break;
        }
    }

    /* Uncomment for FFI call tracing (ObjC calls):
    if (strncmp(desc->name, "__objc_send_", 12) == 0) {
        fprintf(stderr, "[FFI] %s nargs=%d:", desc->name, desc->nargs);
        for (int i = 0; i < desc->nargs; i++) {
            switch (desc->arg_kinds[i]) {
                case ARG_I32:  fprintf(stderr, " i32=%d",    arg_storage[i].i32); break;
                case ARG_I64:  fprintf(stderr, " i64=0x%llx", (long long)arg_storage[i].i64); break;
                case ARG_F64:  fprintf(stderr, " f64=%f",    arg_storage[i].f64); break;
                case ARG_F32:  fprintf(stderr, " f32=%f",    (double)arg_storage[i].f32); break;
                case ARG_PTR:  fprintf(stderr, " ptr=%p",    arg_storage[i].ptr); break;
                default: break;
            }
        }
        fprintf(stderr, "\n");
    }
    */

    /* Call via libffi */
    uint64_t ret_val = 0;
    ffi_call(&desc->cif, FFI_FN(desc->fn_ptr), &ret_val, arg_values);

    /* Uncomment for FFI return value tracing:
    if (has_return && strncmp(desc->name, "__objc_send_", 12) == 0) {
        fprintf(stderr, "[FFI] %s -> 0x%llx\n", desc->name, (long long)ret_val);
    }
    */

    /* Write return value to _sp[0] */
    if (has_return) {
        *((uint64_t *)_sp) = ret_val;
    }

    return NULL;  /* m3ApiSuccess */
}
