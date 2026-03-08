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

    /// Configure struct return metadata on an existing descriptor.
    /// Builds ffi_type struct and re-preps CIF for struct return.
    void ffi_configure_struct_return(FFIDescriptor* desc, int struct_size,
                                     int nfields, int* field_kinds);

    /// Generic trampoline — has M3RawCall-compatible signature.
    /// Pass as the function pointer to m3_LinkRawFunctionEx,
    /// with the FFIDescriptor* as userData.
    const(void)* ffi_generic_trampoline(void* runtime, void* ctx,
                                        ulong* sp, void* mem);

    /**
     * Register ObjC classes from the objc_classes custom section.
     *
     * Parses section data, creates ObjC class pairs via objc_allocateClassPair,
     * creates ffi_closures for each method that call back into WASM, and
     * registers each class pair.
     *
     * Returns: number of classes registered, or -1 on error.
     */
    int objc_register_classes_from_section(
        const(ubyte)* section_data, size_t section_len,
        void* runtime, void* module_);
}
