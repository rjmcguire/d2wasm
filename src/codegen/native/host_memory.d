/**
 * Executable / reserved memory for the native backend.
 *
 * POSIX: mmap / mprotect / munmap.
 * Windows: VirtualAlloc / VirtualProtect / VirtualFree with the same
 * reserve-then-commit pattern (PROT_NONE reservation, mprotect commits).
 */
module codegen.native.host_memory;

version (Windows) {
    import core.sys.windows.winbase : VirtualAlloc, VirtualFree, VirtualProtect;
    import core.sys.windows.winnt : MEM_COMMIT, MEM_RESERVE, MEM_RELEASE,
        PAGE_NOACCESS, PAGE_READONLY, PAGE_READWRITE,
        PAGE_EXECUTE_READ, PAGE_EXECUTE_READWRITE;

    enum PROT_NONE = 0;
    enum PROT_READ = 1;
    enum PROT_WRITE = 2;
    enum PROT_EXEC = 4;

    enum MAP_PRIVATE = 0x02;
    enum MAP_ANON = 0x20;
    enum MAP_ANONYMOUS = MAP_ANON;
    enum MAP_JIT = 0;

    enum MAP_FAILED = cast(void*)-1;

    private uint toWinProtect(int prot) nothrow @nogc {
        if (prot == PROT_NONE)
            return PAGE_NOACCESS;
        const bool x = (prot & PROT_EXEC) != 0;
        const bool w = (prot & PROT_WRITE) != 0;
        if (x && w)
            return PAGE_EXECUTE_READWRITE;
        if (x)
            return PAGE_EXECUTE_READ;
        if (w)
            return PAGE_READWRITE;
        if (prot & PROT_READ)
            return PAGE_READONLY;
        return PAGE_NOACCESS;
    }

    void* mmap(void* addr, size_t length, int prot, int flags, int fd, long offset) nothrow @nogc {
        cast(void)flags;
        cast(void)fd;
        cast(void)offset;
        if (length == 0)
            return MAP_FAILED;

        if (prot == PROT_NONE) {
            auto p = VirtualAlloc(addr, length, MEM_RESERVE, PAGE_NOACCESS);
            return p is null ? MAP_FAILED : p;
        }

        auto p = VirtualAlloc(addr, length, MEM_RESERVE | MEM_COMMIT, toWinProtect(prot));
        return p is null ? MAP_FAILED : p;
    }

    int mprotect(void* addr, size_t len, int prot) nothrow @nogc {
        if (addr is null || len == 0)
            return -1;
        const uint protect = toWinProtect(prot);
        if (prot != PROT_NONE) {
            // Commit previously reserved pages; no-op if already committed.
            if (VirtualAlloc(addr, len, MEM_COMMIT, protect) !is null)
                return 0;
        }
        uint oldProtect;
        return VirtualProtect(addr, len, protect, &oldProtect) ? 0 : -1;
    }

    int munmap(void* addr, size_t len) nothrow @nogc {
        cast(void)len;
        if (addr is null)
            return -1;
        // MEM_RELEASE requires size 0 and the original reservation base.
        return VirtualFree(addr, 0, MEM_RELEASE) ? 0 : -1;
    }
} else {
    public import core.sys.posix.sys.mman;

    version (OSX) {
        enum MAP_ANONYMOUS = 0x1000;
        enum MAP_JIT = 0x0800;
    } else {
        alias MAP_ANONYMOUS = MAP_ANON;
        enum MAP_JIT = 0;
    }
}
