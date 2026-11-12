/**
 * Host dynamic loading (dlopen/dlsym on POSIX, LoadLibrary/GetProcAddress
 * on Windows). Used for extern(C) FFI and pragma(lib).
 */
module runtime.host_dl;

version (Windows) {
    import core.sys.windows.winbase : LoadLibraryA, GetProcAddress, GetModuleHandleA;
    import core.sys.windows.windef : HMODULE;

    private __gshared HMODULE[] loadedModules;

    void* hostLoadLibrary(string spec) {
        if (spec.length == 0)
            return null;
        auto h = LoadLibraryA((spec ~ "\0").ptr);
        if (h !is null)
            loadedModules ~= h;
        return cast(void*)h;
    }

    void* hostDlsym(const(char)* name) {
        if (name is null)
            return null;
        auto p = GetProcAddress(GetModuleHandleA(null), name);
        if (p !is null)
            return cast(void*)p;
        foreach (h; loadedModules) {
            p = GetProcAddress(h, name);
            if (p !is null)
                return cast(void*)p;
        }
        static immutable string[] extras = [
            "ucrtbase.dll", "msvcrt.dll", "kernel32.dll", "ntdll.dll"
        ];
        foreach (mod; extras) {
            auto h = GetModuleHandleA(mod.ptr);
            if (h is null)
                continue;
            p = GetProcAddress(h, name);
            if (p !is null)
                return cast(void*)p;
        }
        return null;
    }
} else {
    import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LAZY, RTLD_GLOBAL;
    version (OSX) {
        import core.sys.darwin.dlfcn : RTLD_DEFAULT;
    } else {
        import core.sys.linux.dlfcn : RTLD_DEFAULT;
    }

    void* hostLoadLibrary(string spec) {
        if (spec.length == 0)
            return null;
        return dlopen((spec ~ "\0").ptr, RTLD_LAZY | RTLD_GLOBAL);
    }

    void* hostDlsym(const(char)* name) {
        if (name is null)
            return null;
        return dlsym(RTLD_DEFAULT, name);
    }
}
