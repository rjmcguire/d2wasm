/*
 * FFI Trampoline Experiment — Steps 3-6
 *
 * Step 3: Generic libffi trampoline with FFIDescriptor
 * Step 4: Struct arguments (CGRect as 4 x f64) via ARG_STRUCT_CGRECT
 * Step 5: Open a macOS window from WASM
 * Step 6: ObjC delegate callback via ffi_closure
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>

#include <ffi/ffi.h>
#include <objc/runtime.h>
#include <objc/message.h>

#include "wasm3.h"
#include "m3_env.h"

// ---------------------------------------------------------------------------
// FFI Descriptor — describes how to marshal one native function
// ---------------------------------------------------------------------------

typedef enum {
    ARG_I32,             // WASM i32 → native int32_t
    ARG_I64,             // WASM i64 → native int64_t (opaque handles)
    ARG_F32,             // WASM f32 → native float
    ARG_F64,             // WASM f64 → native double
    ARG_PTR_WASM,        // WASM i32 offset → native char* (memory_base + offset)
    ARG_BOOL,            // WASM i32 → native BOOL (int8_t on ARM64)
    ARG_STRUCT_CGRECT,   // 4 x WASM f64 → CGRect struct {origin.x, origin.y, size.width, size.height}
    RET_VOID = 100,      // sentinel for void return
} ArgKind;

typedef struct {
    double x, y, width, height;
} CGRect_t;

// libffi struct type for CGRect (4 doubles — ARM64 passes as HFA in d0-d3)
static ffi_type cgrect_ffi_type;
static ffi_type *cgrect_elements[5]; // 4 doubles + NULL terminator
static bool cgrect_type_inited = false;

static void init_cgrect_type(void) {
    if (cgrect_type_inited) return;
    cgrect_elements[0] = &ffi_type_double;
    cgrect_elements[1] = &ffi_type_double;
    cgrect_elements[2] = &ffi_type_double;
    cgrect_elements[3] = &ffi_type_double;
    cgrect_elements[4] = NULL;
    cgrect_ffi_type.size = 0;
    cgrect_ffi_type.alignment = 0;
    cgrect_ffi_type.type = FFI_TYPE_STRUCT;
    cgrect_ffi_type.elements = cgrect_elements;
    cgrect_type_inited = true;
}

typedef struct {
    const char  *name;          // for debug logging
    void        *fn_ptr;        // dlsym'd native function pointer
    ffi_cif      cif;           // pre-built libffi call info
    int          nargs;         // number of logical WASM-side args
    int          nargs_native;  // number of native args (may differ due to struct expansion)
    ArgKind      ret_kind;
    ArgKind     *arg_kinds;     // how to marshal each arg from WASM stack
    ffi_type   **ffi_arg_types; // libffi type array
} FFIDescriptor;

// ---------------------------------------------------------------------------
// Descriptor construction
// ---------------------------------------------------------------------------

static ffi_type *argkind_to_ffi_type(ArgKind k) {
    switch (k) {
        case ARG_I32:            return &ffi_type_sint32;
        case ARG_I64:            return &ffi_type_sint64;
        case ARG_F32:            return &ffi_type_float;
        case ARG_F64:            return &ffi_type_double;
        case ARG_PTR_WASM:       return &ffi_type_pointer;
        case ARG_BOOL:           return &ffi_type_sint8;
        case ARG_STRUCT_CGRECT:  init_cgrect_type(); return &cgrect_ffi_type;
        default:                 return &ffi_type_void;
    }
}

static ffi_type *retkind_to_ffi_type(ArgKind k) {
    if (k == RET_VOID) return &ffi_type_void;
    return argkind_to_ffi_type(k);
}

static FFIDescriptor *make_ffi_desc_v(const char *name, void *fn_ptr, ArgKind ret_kind, int nargs, va_list ap) {
    FFIDescriptor *d = calloc(1, sizeof(FFIDescriptor));
    d->name = name;
    d->fn_ptr = fn_ptr;
    d->nargs = nargs;
    d->ret_kind = ret_kind;
    d->arg_kinds = calloc(nargs, sizeof(ArgKind));
    d->ffi_arg_types = calloc(nargs, sizeof(ffi_type*));
    d->nargs_native = nargs;

    for (int i = 0; i < nargs; i++) {
        d->arg_kinds[i] = va_arg(ap, int);
        d->ffi_arg_types[i] = argkind_to_ffi_type(d->arg_kinds[i]);
    }

    ffi_type *ret_ffi = retkind_to_ffi_type(ret_kind);

    ffi_status status = ffi_prep_cif(&d->cif, FFI_DEFAULT_ABI, nargs, ret_ffi, d->ffi_arg_types);
    if (status != FFI_OK) {
        fprintf(stderr, "FATAL: ffi_prep_cif failed for %s (status=%d)\n", name, status);
        exit(1);
    }

    return d;
}

static FFIDescriptor *make_ffi_desc(const char *name, void *fn_ptr, ArgKind ret_kind, int nargs, ...) {
    va_list ap;
    va_start(ap, nargs);
    FFIDescriptor *d = make_ffi_desc_v(name, fn_ptr, ret_kind, nargs, ap);
    va_end(ap);
    return d;
}

// ---------------------------------------------------------------------------
// The one generic trampoline
// ---------------------------------------------------------------------------

static m3ApiRawFunction(generic_ffi_trampoline)
{
    FFIDescriptor *desc = (FFIDescriptor *)_ctx->userdata;

    // Reserve slot for return value (wasm3 convention: _sp[0] is return)
    uint64_t *sp = _sp;
    int has_return = (desc->cif.rtype != &ffi_type_void);
    if (has_return) sp++; // skip return slot

    // Marshal arguments from WASM stack
    void *arg_values[16];
    union { int32_t i32; int64_t i64; float f32; double f64; void *ptr; int8_t b; CGRect_t rect; } arg_storage[16];

    for (int i = 0; i < desc->nargs; i++) {
        switch (desc->arg_kinds[i]) {
            case ARG_I32: {
                arg_storage[i].i32 = *(int32_t *)sp;
                arg_values[i] = &arg_storage[i].i32;
                sp++;
                break;
            }
            case ARG_I64: {
                arg_storage[i].i64 = *(int64_t *)sp;
                arg_values[i] = &arg_storage[i].i64;
                sp++;
                break;
            }
            case ARG_F32: {
                // wasm3 stores f32 in a 64-bit slot
                arg_storage[i].f32 = *(float *)sp;
                arg_values[i] = &arg_storage[i].f32;
                sp++;
                break;
            }
            case ARG_F64: {
                arg_storage[i].f64 = *(double *)sp;
                arg_values[i] = &arg_storage[i].f64;
                sp++;
                break;
            }
            case ARG_PTR_WASM: {
                uint32_t offset = *(uint32_t *)sp;
                arg_storage[i].ptr = (void *)((uint8_t *)_mem + offset);
                arg_values[i] = &arg_storage[i].ptr;
                sp++;
                break;
            }
            case ARG_BOOL: {
                arg_storage[i].b = (int8_t)(*(int32_t *)sp);
                arg_values[i] = &arg_storage[i].b;
                sp++;
                break;
            }
            case ARG_STRUCT_CGRECT: {
                // Read 4 f64 values from WASM stack
                arg_storage[i].rect.x      = *(double *)sp; sp++;
                arg_storage[i].rect.y      = *(double *)(sp); sp++;
                arg_storage[i].rect.width  = *(double *)(sp); sp++;
                arg_storage[i].rect.height = *(double *)(sp); sp++;
                arg_values[i] = &arg_storage[i].rect;
                break;
            }
            default: break;
        }
    }

    // Call via libffi
    uint64_t ret_val = 0;
    ffi_call(&desc->cif, FFI_FN(desc->fn_ptr), &ret_val, arg_values);

    printf("[ffi] %s => 0x%llx\n", desc->name, (unsigned long long)ret_val);

    // Write return value
    if (has_return) {
        *((uint64_t *)_sp) = ret_val;
    }

    m3ApiSuccess();
}

// ---------------------------------------------------------------------------
// Utility: print_ptr(i64) -> void, print_i32(i32) -> void
// ---------------------------------------------------------------------------

static m3ApiRawFunction(wasm_print_ptr)
{
    m3ApiGetArg(int64_t, ptr);
    printf("[wasm] pointer = 0x%llx\n", (unsigned long long)ptr);
    m3ApiSuccess();
}

static m3ApiRawFunction(wasm_print_i32)
{
    m3ApiGetArg(int32_t, val);
    printf("[wasm] i32 = %d\n", val);
    m3ApiSuccess();
}

// ---------------------------------------------------------------------------
// Step 6: ObjC delegate via ffi_closure
// ---------------------------------------------------------------------------

// The C function that will be called when applicationDidFinishLaunching: fires
static void delegate_didFinishLaunching(ffi_cif *cif, void *ret, void *args[], void *userdata) {
    (void)cif; (void)ret; (void)userdata;
    printf("[delegate] applicationDidFinishLaunching: called!\n");
}

// applicationShouldTerminateAfterLastWindowClosed: returns YES
static BOOL delegate_shouldTerminate(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    printf("[delegate] applicationShouldTerminateAfterLastWindowClosed: -> YES\n");
    return 1;
}

// Create a WASMAppDelegate class at runtime with applicationDidFinishLaunching: method
static void *create_delegate_class(void) {
    Class superclass = (Class)objc_getClass("NSObject");
    Class delegateClass = objc_allocateClassPair(superclass, "WASMAppDelegate", 0);
    if (!delegateClass) {
        fprintf(stderr, "FATAL: objc_allocateClassPair failed\n");
        exit(1);
    }

    // Create an ffi_closure for applicationDidFinishLaunching: IMP
    ffi_cif *cif = calloc(1, sizeof(ffi_cif));
    ffi_type **arg_types = calloc(3, sizeof(ffi_type*));
    arg_types[0] = &ffi_type_pointer;
    arg_types[1] = &ffi_type_pointer;
    arg_types[2] = &ffi_type_pointer;
    ffi_prep_cif(cif, FFI_DEFAULT_ABI, 3, &ffi_type_void, arg_types);

    void *closure_code = NULL;
    ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), &closure_code);
    if (!closure) {
        fprintf(stderr, "FATAL: ffi_closure_alloc failed\n");
        exit(1);
    }

    ffi_status status = ffi_prep_closure_loc(closure, cif, delegate_didFinishLaunching, NULL, closure_code);
    if (status != FFI_OK) {
        fprintf(stderr, "FATAL: ffi_prep_closure_loc failed\n");
        exit(1);
    }

    // Add methods
    class_addMethod(delegateClass, sel_registerName("applicationDidFinishLaunching:"),
                    (IMP)closure_code, "v@:@");
    class_addMethod(delegateClass, sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"),
                    (IMP)delegate_shouldTerminate, "B@:@");

    objc_registerClassPair(delegateClass);
    printf("[host] created WASMAppDelegate class with ffi_closure IMP\n");

    // Instantiate: [[WASMAppDelegate alloc] init]
    id delegate = ((id(*)(id, SEL))objc_msgSend)((id)delegateClass, sel_registerName("alloc"));
    delegate = ((id(*)(id, SEL))objc_msgSend)(delegate, sel_registerName("init"));
    printf("[host] delegate instance: %p\n", delegate);

    return delegate;
}

// Host function for WASM to get the delegate pointer
static void *g_delegate = NULL;

static m3ApiRawFunction(wasm_get_delegate)
{
    m3ApiReturnType(int64_t);
    m3ApiReturn((int64_t)(uintptr_t)g_delegate);
}

// ---------------------------------------------------------------------------

static void fatal(const char *msg, M3Result err) {
    if (err) {
        fprintf(stderr, "FATAL: %s — %s\n", msg, err);
    } else {
        fprintf(stderr, "FATAL: %s\n", msg);
    }
    exit(1);
}

int main(int argc, char **argv) {
    // Line-buffer stdout so we see output before event loop blocks
    setvbuf(stdout, NULL, _IOLBF, 0);

    // dlopen libobjc
    void *libobjc = dlopen("/usr/lib/libobjc.dylib", RTLD_LAZY);
    if (!libobjc)
        libobjc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY);
    if (!libobjc)
        fatal("dlopen libobjc failed", NULL);

    // dlsym ObjC runtime functions
    void *fn_getClass    = dlsym(libobjc, "objc_getClass");
    void *fn_selRegister = dlsym(libobjc, "sel_registerName");
    void *fn_msgSend     = dlsym(libobjc, "objc_msgSend");

    if (!fn_getClass)    fatal("dlsym objc_getClass", NULL);
    if (!fn_selRegister) fatal("dlsym sel_registerName", NULL);
    if (!fn_msgSend)     fatal("dlsym objc_msgSend", NULL);

    printf("[host] objc_getClass    @ %p\n", fn_getClass);
    printf("[host] sel_registerName @ %p\n", fn_selRegister);
    printf("[host] objc_msgSend     @ %p\n", fn_msgSend);

    // Step 6: Create delegate before WASM runs
    g_delegate = create_delegate_class();

    // Build FFI descriptors for different objc_msgSend signatures
    FFIDescriptor *desc_getClass    = make_ffi_desc("objc_getClass",       fn_getClass,    ARG_I64, 1, ARG_PTR_WASM);
    FFIDescriptor *desc_selRegister = make_ffi_desc("sel_registerName",    fn_selRegister, ARG_I64, 1, ARG_PTR_WASM);

    // (id, SEL) -> id
    FFIDescriptor *desc_msgSend_id  = make_ffi_desc("msgSend(id,SEL)->id", fn_msgSend, ARG_I64, 2, ARG_I64, ARG_I64);

    // (id, SEL) -> void
    FFIDescriptor *desc_msgSend_v   = make_ffi_desc("msgSend(id,SEL)->v",  fn_msgSend, (ArgKind)RET_VOID, 2, ARG_I64, ARG_I64);

    // (id, SEL, id) -> void
    FFIDescriptor *desc_msgSend_v_id = make_ffi_desc("msgSend(id,SEL,id)->v", fn_msgSend, (ArgKind)RET_VOID, 3, ARG_I64, ARG_I64, ARG_I64);

    // (id, SEL, i64) -> void  — setActivationPolicy:, activateIgnoringOtherApps:
    FFIDescriptor *desc_msgSend_v_i64 = make_ffi_desc("msgSend(id,SEL,i64)->v", fn_msgSend, (ArgKind)RET_VOID, 3, ARG_I64, ARG_I64, ARG_I64);

    // (id, SEL, CGRect, u64, u64, i32) -> id — initWithContentRect:styleMask:backing:defer:
    // WASM sends: i64 self, i64 SEL, f64 x, f64 y, f64 w, f64 h, i64 style, i64 backing, i32 defer
    // Native: 6 args: id, SEL, CGRect(struct), u64, u64, i32
    FFIDescriptor *desc_msgSend_initWindow = make_ffi_desc("msgSend(initWindow)->id", fn_msgSend, ARG_I64, 6,
        ARG_I64, ARG_I64, ARG_STRUCT_CGRECT, ARG_I64, ARG_I64, ARG_BOOL);

    // (id, SEL, BOOL) -> void — setReleasedWhenClosed:
    FFIDescriptor *desc_msgSend_v_bool = make_ffi_desc("msgSend(id,SEL,BOOL)->v", fn_msgSend, (ArgKind)RET_VOID, 3, ARG_I64, ARG_I64, ARG_BOOL);

    // Load WASM module
    FILE *f = fopen("test.wasm", "rb");
    if (!f) fatal("could not open test.wasm", NULL);
    fseek(f, 0, SEEK_END);
    size_t wasmSize = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *wasmBytes = malloc(wasmSize);
    fread(wasmBytes, 1, wasmSize, f);
    fclose(f);
    printf("[host] loaded test.wasm (%zu bytes)\n", wasmSize);

    // Set up wasm3
    IM3Environment env = m3_NewEnvironment();
    IM3Runtime runtime = m3_NewRuntime(env, 64 * 1024, NULL);

    IM3Module module;
    M3Result err = m3_ParseModule(env, &module, wasmBytes, wasmSize);
    if (err) fatal("m3_ParseModule", err);

    err = m3_LoadModule(runtime, module);
    if (err) fatal("m3_LoadModule", err);

    // Link all FFI functions through the generic trampoline
    err = m3_LinkRawFunctionEx(module, "ffi", "objc_getClass",    "I(i)",  &generic_ffi_trampoline, desc_getClass);
    if (err) fatal("link objc_getClass", err);

    err = m3_LinkRawFunctionEx(module, "ffi", "sel_registerName", "I(i)",  &generic_ffi_trampoline, desc_selRegister);
    if (err) fatal("link sel_registerName", err);

    // Different objc_msgSend variants (different WASM signatures)
    err = m3_LinkRawFunctionEx(module, "ffi", "msgSend_id",       "I(II)",     &generic_ffi_trampoline, desc_msgSend_id);
    if (err) fatal("link msgSend_id", err);

    err = m3_LinkRawFunctionEx(module, "ffi", "msgSend_void",     "v(II)",     &generic_ffi_trampoline, desc_msgSend_v);
    if (err) fatal("link msgSend_void", err);

    err = m3_LinkRawFunctionEx(module, "ffi", "msgSend_void_id",  "v(III)",    &generic_ffi_trampoline, desc_msgSend_v_id);
    if (err) fatal("link msgSend_void_id", err);

    err = m3_LinkRawFunctionEx(module, "ffi", "msgSend_void_i64", "v(III)",    &generic_ffi_trampoline, desc_msgSend_v_i64);
    if (err) fatal("link msgSend_void_i64", err);

    // initWithContentRect: self(i64), SEL(i64), x(f64), y(f64), w(f64), h(f64), style(i64), backing(i64), defer(i32)
    err = m3_LinkRawFunctionEx(module, "ffi", "msgSend_initWindow", "I(IIFFFFIIi)", &generic_ffi_trampoline, desc_msgSend_initWindow);
    if (err) fatal("link msgSend_initWindow", err);

    err = m3_LinkRawFunctionEx(module, "ffi", "msgSend_void_bool", "v(IIi)", &generic_ffi_trampoline, desc_msgSend_v_bool);
    if (err) fatal("link msgSend_void_bool", err);

    // Delegate getter
    err = m3_LinkRawFunction(module, "ffi", "get_delegate", "I()", &wasm_get_delegate);
    if (err) fatal("link get_delegate", err);

    // Utility
    err = m3_LinkRawFunction(module, "ffi", "print_ptr", "v(I)", &wasm_print_ptr);
    if (err) fatal("link print_ptr", err);

    err = m3_LinkRawFunction(module, "ffi", "print_i32", "v(i)", &wasm_print_i32);
    if (err) fatal("link print_i32", err);

    // Find and call main
    IM3Function mainFn;
    err = m3_FindFunction(&mainFn, runtime, "main");
    if (err) fatal("m3_FindFunction", err);

    printf("[host] === calling WASM main() ===\n");
    err = m3_CallV(mainFn);
    if (err) fatal("m3_CallV", err);

    int32_t result;
    err = m3_GetResultsV(mainFn, &result);
    if (err) fatal("m3_GetResults", err);

    printf("[host] main() returned %d\n", result);

    // Cleanup
    m3_FreeRuntime(runtime);
    m3_FreeEnvironment(env);
    free(wasmBytes);
    dlclose(libobjc);

    return 0;
}
