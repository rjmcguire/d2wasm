/*
 * Windows stand-in for ffi_trampoline.c when libffi is not linked.
 * extern(C) FFI imports are skipped (ffi_make_descriptor returns NULL).
 */
#include <stddef.h>
#include <stdint.h>

typedef struct FFIDescriptor FFIDescriptor;

void ffi_set_ptr_return_base(uint32_t base) { (void)base; }
void ffi_reset_ptr_return_bump(void) {}

const char *ffi_get_callback_error(void) { return NULL; }
void ffi_clear_callback_error(void) {}

FFIDescriptor *ffi_make_descriptor(const char *name, void *fn_ptr,
                                   int ret_kind, int nargs, int *arg_kinds) {
    (void)name;
    (void)fn_ptr;
    (void)ret_kind;
    (void)nargs;
    (void)arg_kinds;
    return NULL;
}

void ffi_free_descriptor(FFIDescriptor *d) { (void)d; }

void ffi_configure_struct_return(FFIDescriptor *d, int struct_size,
                                 int nfields, int *field_kinds) {
    (void)d;
    (void)struct_size;
    (void)nfields;
    (void)field_kinds;
}

const void *ffi_generic_trampoline(void *runtime, void *ctx, uint64_t *sp, void *mem) {
    (void)runtime;
    (void)ctx;
    (void)sp;
    (void)mem;
    return NULL;
}

int objc_register_classes_from_section(const uint8_t *section_data, size_t section_len,
                                       void *runtime, void *module_) {
    (void)section_data;
    (void)section_len;
    (void)runtime;
    (void)module_;
    return -1;
}
