/**
 * D bindings for the C FFI trampoline (runtime/ffi_trampoline.c).
 *
 * These functions are used by CTFERuntime to link extern(C) FFI imports
 * at WASM module load time.
 */
module runtime.ffi_bindings;

extern(C) @nogc nothrow {
    /// Opaque FFI descriptor — holds libffi CIF + marshaling info
    struct FFIDescriptor;

    /**
     * Build a descriptor for one native function.
     *
     * Params:
     *   name     = function name (for debug logging)
     *   fn_ptr   = dlsym'd native function pointer
     *   ret_kind = ArgKind for the return type
     *   nargs    = number of parameters
     *   arg_kinds = array of ArgKind values (length == nargs)
     *
     * Returns: heap-allocated descriptor, or null on ffi_prep_cif failure
     */
    FFIDescriptor* ffi_make_descriptor(const(char)* name, void* fn_ptr,
                                       int ret_kind, int nargs, int* arg_kinds);

    /// Free a descriptor returned by ffi_make_descriptor
    void ffi_free_descriptor(FFIDescriptor* desc);

    /// Generic trampoline — has M3RawCall-compatible signature.
    /// Pass as the function pointer to m3_LinkRawFunctionEx,
    /// with the FFIDescriptor* as userData.
    const(void)* ffi_generic_trampoline(void* runtime, void* ctx,
                                        ulong* sp, void* mem);
}
