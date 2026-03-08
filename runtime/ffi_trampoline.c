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

/* ===========================================================================
 * ObjC Class Registration — dynamically creates ObjC classes from WASM methods
 *
 * Each method gets an ffi_closure that:
 *   1. Receives native ObjC call (self, _cmd, args...)
 *   2. Marshals args into WASM values
 *   3. Calls the WASM method via m3_Call
 *   4. Marshals return value back to native
 * ===========================================================================*/

#ifdef __APPLE__

#include <objc/runtime.h>
#include <objc/message.h>

/* Callback descriptor for one ObjC method → WASM bridge */
typedef struct {
    IM3Function   wasm_func;
    IM3Runtime    runtime;
    ArgKind       ret_kind;
    int           nargs;       /* user args (excluding self, _cmd) */
    ArgKind      *arg_kinds;
} ObjCCallbackDesc;

/* Track all closures for cleanup */
#define MAX_CLOSURES 256
static void *g_closures[MAX_CLOSURES];
static int g_closure_count = 0;

/*
 * ffi_closure callback: ObjC runtime → WASM method
 *
 * When ObjC sends a message to our registered class, the ffi_closure
 * redirects here. We marshal (self, _cmd, args...) into WASM values
 * and call the WASM exported method via m3_Call.
 */
static void objc_callback_handler(ffi_cif *cif, void *ret, void **args, void *userdata) {
    (void)cif;
    ObjCCallbackDesc *desc = (ObjCCallbackDesc *)userdata;

    /* Total WASM args: self(i64) + _cmd(i64) + user_args */
    int total_args = 2 + desc->nargs;

    /* Pack all arguments into wasm3 stack slots (uint64_t each) */
    uint64_t wasm_args[34];  /* 2 hidden + up to 32 user args */

    /* self → i64 */
    wasm_args[0] = (uint64_t)(*(void **)args[0]);
    /* _cmd → i64 */
    wasm_args[1] = (uint64_t)(*(void **)args[1]);

    /* User args: marshal based on ArgKind */
    for (int i = 0; i < desc->nargs && i < 32; i++) {
        switch (desc->arg_kinds[i]) {
            case ARG_I32:
                wasm_args[2 + i] = (uint64_t)(*(int32_t *)args[2 + i]);
                break;
            case ARG_I64:
                wasm_args[2 + i] = *(uint64_t *)args[2 + i];
                break;
            case ARG_F32: {
                float f = *(float *)args[2 + i];
                memcpy(&wasm_args[2 + i], &f, sizeof(float));
                break;
            }
            case ARG_F64: {
                double d = *(double *)args[2 + i];
                memcpy(&wasm_args[2 + i], &d, sizeof(double));
                break;
            }
            case ARG_PTR:
                wasm_args[2 + i] = (uint64_t)(*(void **)args[2 + i]);
                break;
            default:
                wasm_args[2 + i] = 0;
                break;
        }
    }

    /* Call WASM function */
    const void *stack_ptrs[34];
    for (int i = 0; i < total_args; i++) {
        stack_ptrs[i] = &wasm_args[i];
    }

    M3Result result = m3_Call(desc->wasm_func, total_args, stack_ptrs);
    if (result) {
        fprintf(stderr, "ObjC callback: m3_Call failed: %s\n", result);
        if (ret) memset(ret, 0, 8);
        return;
    }

    /* Marshal return value */
    if (desc->ret_kind != RET_VOID && ret) {
        uint64_t ret_val = 0;
        const void *ret_ptrs[1] = { &ret_val };
        M3Result get_result = m3_GetResults(desc->wasm_func, 1, ret_ptrs);
        if (get_result) {
            fprintf(stderr, "ObjC callback: m3_GetResults failed: %s\n", get_result);
            memset(ret, 0, 8);
            return;
        }

        switch (desc->ret_kind) {
            case ARG_I32:
                *(int32_t *)ret = (int32_t)ret_val;
                break;
            case ARG_I64:
                *(int64_t *)ret = (int64_t)ret_val;
                break;
            case ARG_F32:
                memcpy(ret, &ret_val, sizeof(float));
                break;
            case ARG_F64:
                memcpy(ret, &ret_val, sizeof(double));
                break;
            default:
                *(uint64_t *)ret = ret_val;
                break;
        }
    }
}

/* Helper: read LEB128 unsigned integer from a byte stream */
static uint32_t read_leb128(const uint8_t *data, size_t *pos, size_t len) {
    uint32_t result = 0;
    uint32_t shift = 0;
    while (*pos < len) {
        uint8_t b = data[(*pos)++];
        result |= (uint32_t)(b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
    }
    return result;
}

/* Helper: read a length-prefixed string from byte stream */
static char *read_string(const uint8_t *data, size_t *pos, size_t len) {
    uint32_t slen = read_leb128(data, pos, len);
    if (*pos + slen > len) return NULL;
    char *s = malloc(slen + 1);
    memcpy(s, data + *pos, slen);
    s[slen] = '\0';
    *pos += slen;
    return s;
}

/* Map ArgKind → ffi_type for ObjC closure CIF (native types, not WASM) */
static ffi_type *objc_argkind_to_ffi_type(ArgKind k) {
    switch (k) {
        case ARG_I32:  return &ffi_type_sint32;
        case ARG_I64:  return &ffi_type_sint64;
        case ARG_F32:  return &ffi_type_float;
        case ARG_F64:  return &ffi_type_double;
        case ARG_PTR:  return &ffi_type_pointer;
        default:       return &ffi_type_pointer; /* ObjC id, SEL are pointers */
    }
}

/*
 * Register ObjC classes from the objc_classes custom section in WASM binary.
 *
 * For each class:
 *   1. objc_allocateClassPair(superclass, name, 0)
 *   2. For each method: create ffi_closure → class_addMethod
 *   3. objc_registerClassPair()
 *
 * Returns number of classes registered, or -1 on error.
 */
int objc_register_classes_from_section(
    const uint8_t *section_data, size_t section_len,
    IM3Runtime runtime, IM3Module module)
{
    size_t pos = 0;
    uint32_t class_count = read_leb128(section_data, &pos, section_len);
    int registered = 0;

    for (uint32_t ci = 0; ci < class_count && pos < section_len; ci++) {
        char *class_name = read_string(section_data, &pos, section_len);
        char *super_name = read_string(section_data, &pos, section_len);
        uint32_t method_count = read_leb128(section_data, &pos, section_len);

        if (!class_name || !super_name) {
            fprintf(stderr, "objc_register: failed to read class/super name\n");
            free(class_name); free(super_name);
            continue;
        }

        /* Get superclass */
        Class superclass = objc_getClass(super_name);
        if (!superclass) {
            fprintf(stderr, "objc_register: unknown superclass '%s' for '%s'\n",
                    super_name, class_name);
            free(class_name); free(super_name);
            /* Skip methods */
            for (uint32_t mi = 0; mi < method_count; mi++) {
                free(read_string(section_data, &pos, section_len)); /* selector */
                free(read_string(section_data, &pos, section_len)); /* wasm_export */
                free(read_string(section_data, &pos, section_len)); /* type_enc */
                if (pos < section_len) pos++; /* ret_kind */
                if (pos < section_len) {
                    uint8_t pc = section_data[pos++];
                    pos += pc; /* param_kinds */
                }
            }
            continue;
        }

        /* Allocate new class pair */
        Class newClass = objc_allocateClassPair(superclass, class_name, 0);
        if (!newClass) {
            fprintf(stderr, "objc_register: objc_allocateClassPair failed for '%s' "
                    "(class may already exist)\n", class_name);
            free(class_name); free(super_name);
            /* Skip methods */
            for (uint32_t mi = 0; mi < method_count; mi++) {
                free(read_string(section_data, &pos, section_len));
                free(read_string(section_data, &pos, section_len));
                free(read_string(section_data, &pos, section_len));
                if (pos < section_len) pos++;
                if (pos < section_len) {
                    uint8_t pc = section_data[pos++];
                    pos += pc;
                }
            }
            continue;
        }

        /* Add methods */
        for (uint32_t mi = 0; mi < method_count && pos < section_len; mi++) {
            char *selector_str = read_string(section_data, &pos, section_len);
            char *wasm_export  = read_string(section_data, &pos, section_len);
            char *type_enc     = read_string(section_data, &pos, section_len);

            ArgKind ret_kind = RET_VOID;
            if (pos < section_len) ret_kind = (ArgKind)section_data[pos++];

            int nargs = 0;
            ArgKind *arg_kinds = NULL;
            if (pos < section_len) {
                nargs = section_data[pos++];
                if (nargs > 0 && pos + nargs <= section_len) {
                    arg_kinds = malloc(nargs * sizeof(ArgKind));
                    for (int k = 0; k < nargs; k++)
                        arg_kinds[k] = (ArgKind)section_data[pos++];
                }
            }

            if (!selector_str || !wasm_export || !type_enc) {
                free(selector_str); free(wasm_export); free(type_enc);
                free(arg_kinds);
                continue;
            }

            /* Find the WASM function */
            IM3Function wasm_func = NULL;
            M3Result res = m3_FindFunction(&wasm_func, runtime, wasm_export);
            if (res || !wasm_func) {
                fprintf(stderr, "objc_register: m3_FindFunction('%s') failed: %s\n",
                        wasm_export, res ? res : "not found");
                free(selector_str); free(wasm_export); free(type_enc);
                free(arg_kinds);
                continue;
            }

            /* Build callback descriptor */
            ObjCCallbackDesc *desc = calloc(1, sizeof(ObjCCallbackDesc));
            desc->wasm_func = wasm_func;
            desc->runtime   = runtime;
            desc->ret_kind  = ret_kind;
            desc->nargs     = nargs;
            desc->arg_kinds = arg_kinds;  /* takes ownership */

            /* Build ffi_cif for the ObjC method signature:
             * (id self, SEL _cmd, user_args...) → ret_type */
            int total_native_args = 2 + nargs;
            ffi_type **cif_args = calloc(total_native_args, sizeof(ffi_type *));
            cif_args[0] = &ffi_type_pointer;  /* self (id) */
            cif_args[1] = &ffi_type_pointer;  /* _cmd (SEL) */
            for (int k = 0; k < nargs; k++) {
                cif_args[2 + k] = objc_argkind_to_ffi_type(arg_kinds[k]);
            }
            ffi_type *cif_ret = (ret_kind == RET_VOID) ? &ffi_type_void
                                                        : objc_argkind_to_ffi_type(ret_kind);

            ffi_cif *cif = calloc(1, sizeof(ffi_cif));
            ffi_status ffi_stat = ffi_prep_cif(cif, FFI_DEFAULT_ABI,
                                                total_native_args, cif_ret, cif_args);
            if (ffi_stat != FFI_OK) {
                fprintf(stderr, "objc_register: ffi_prep_cif failed for %s (status=%d)\n",
                        wasm_export, ffi_stat);
                free(desc); free(cif_args); free(cif);
                free(selector_str); free(wasm_export); free(type_enc);
                continue;
            }

            /* Create ffi_closure */
            void *closure_code = NULL;
            ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), &closure_code);
            if (!closure) {
                fprintf(stderr, "objc_register: ffi_closure_alloc failed for %s\n", wasm_export);
                free(desc); free(cif_args); free(cif);
                free(selector_str); free(wasm_export); free(type_enc);
                continue;
            }

            ffi_stat = ffi_prep_closure_loc(closure, cif, objc_callback_handler, desc, closure_code);
            if (ffi_stat != FFI_OK) {
                fprintf(stderr, "objc_register: ffi_prep_closure_loc failed for %s\n", wasm_export);
                ffi_closure_free(closure);
                free(desc); free(cif_args); free(cif);
                free(selector_str); free(wasm_export); free(type_enc);
                continue;
            }

            /* Track closure for later cleanup */
            if (g_closure_count < MAX_CLOSURES)
                g_closures[g_closure_count++] = closure;

            /* Add method to class */
            SEL sel = sel_registerName(selector_str);
            class_addMethod(newClass, sel, (IMP)closure_code, type_enc);

            free(selector_str);
            free(wasm_export);
            free(type_enc);
            /* Note: desc, arg_kinds, cif, cif_args are owned by closure — not freed here */
        }

        /* Register the class pair */
        objc_registerClassPair(newClass);
        registered++;

        free(class_name);
        free(super_name);
    }

    return registered;
}

#else
/* Non-Apple: stub */
int objc_register_classes_from_section(
    const uint8_t *section_data, size_t section_len,
    void *runtime, void *module)
{
    (void)section_data; (void)section_len;
    (void)runtime; (void)module;
    return 0;
}
#endif /* __APPLE__ */
