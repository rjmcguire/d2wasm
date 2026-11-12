/**
 * Windows file watcher.
 *
 * Uses ReadDirectoryChangesW on each watched directory. start() blocks
 * until stop(). Change paths are the directory joined with the notified name.
 */
module watcher.win32_watcher;

version (Windows):

import watcher.watcher : IFileWatcher;
import core.sys.windows.windows;
import core.sys.windows.winnt : FILE_NOTIFY_INFORMATION;
import std.conv : to;
import std.path : absolutePath, buildPath, dirName;
import std.file : isDir;
import std.stdio : stderr;
import std.utf : toUTF16z;

class Win32Watcher : IFileWatcher {
    private {
        string[] watchPaths;
        bool running;
        void delegate(string[]) changeCallback;
        HANDLE stopEvent;
    }

    void setCallback(void delegate(string[]) callback) {
        changeCallback = callback;
    }

    void addPath(string path) {
        auto abs = absolutePath(path);
        if (!isDir(abs))
            abs = absolutePath(dirName(abs));
        watchPaths ~= abs;
    }

    void removePath(string path) {
        import std.algorithm : countUntil, remove;
        auto abs = absolutePath(path);
        auto idx = watchPaths.countUntil(abs);
        if (idx >= 0)
            watchPaths = watchPaths.remove(idx);
    }

    void start() {
        if (running || watchPaths.length == 0)
            return;
        running = true;
        stopEvent = CreateEventW(null, TRUE, FALSE, null);
        if (stopEvent is null) {
            running = false;
            return;
        }

        Watch[] watches;
        scope (exit) {
            foreach (ref w; watches)
                w.close();
            if (stopEvent !is null) {
                CloseHandle(stopEvent);
                stopEvent = null;
            }
            running = false;
        }

        foreach (dir; watchPaths) {
            Watch w;
            if (!w.open(dir)) {
                stderr.writeln("Watch mode: cannot watch ", dir);
                w.close();
                return;
            }
            if (!w.arm()) {
                stderr.writeln("Watch mode: cannot arm ", dir);
                w.close();
                return;
            }
            watches ~= w;
        }

        HANDLE[] waitOn;
        waitOn ~= stopEvent;
        foreach (ref w; watches)
            waitOn ~= w.event;

        while (running) {
            auto which = WaitForMultipleObjects(cast(DWORD)waitOn.length, waitOn.ptr, FALSE, INFINITE);
            if (!running || which == WAIT_OBJECT_0)
                break;
            if (which < WAIT_OBJECT_0 || which >= WAIT_OBJECT_0 + waitOn.length)
                break;
            auto index = which - WAIT_OBJECT_0 - 1;
            auto paths = watches[index].collect();
            if (paths.length > 0 && changeCallback !is null)
                changeCallback(paths);
            if (!watches[index].arm())
                break;
        }
    }

    void stop() {
        running = false;
        if (stopEvent !is null)
            SetEvent(stopEvent);
    }

    bool isRunning() const {
        return running;
    }
}

private struct Watch {
    string dir;
    HANDLE handle = INVALID_HANDLE_VALUE;
    HANDLE event;
    OVERLAPPED overlapped;
    ubyte[] buffer;

    bool open(string directory) {
        dir = directory;
        handle = CreateFileW(
            toUTF16z(directory),
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null);
        if (handle == INVALID_HANDLE_VALUE)
            return false;
        event = CreateEventW(null, FALSE, FALSE, null);
        if (event is null)
            return false;
        overlapped.hEvent = event;
        buffer = new ubyte[64 * 1024];
        return true;
    }

    bool arm() {
        enum filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_SIZE
            | FILE_NOTIFY_CHANGE_LAST_WRITE;
        return ReadDirectoryChangesW(
            handle, buffer.ptr, cast(DWORD)buffer.length, FALSE, filter,
            null, &overlapped, null) != 0;
    }

    string[] collect() {
        DWORD bytes;
        if (!GetOverlappedResult(handle, &overlapped, &bytes, FALSE) || bytes == 0)
            return null;
        string[] paths;
        size_t offset;
        while (offset + 12 <= bytes) {
            auto info = cast(FILE_NOTIFY_INFORMATION*)(buffer.ptr + offset);
            if (offset + 12 + info.FileNameLength > bytes)
                break;
            auto nchars = info.FileNameLength / wchar.sizeof;
            if (nchars > 0) {
                auto chars = info.FileName[0 .. nchars];
                paths ~= buildPath(dir, to!string(chars));
            }
            if (info.NextEntryOffset == 0)
                break;
            offset += info.NextEntryOffset;
        }
        return paths;
    }

    void close() {
        if (handle != INVALID_HANDLE_VALUE) {
            CancelIoEx(handle, &overlapped);
            CloseHandle(handle);
            handle = INVALID_HANDLE_VALUE;
        }
        if (event !is null) {
            CloseHandle(event);
            event = null;
        }
    }
}

unittest {
    auto watcher = new Win32Watcher();
    assert(!watcher.isRunning());
    watcher.addPath(".");
    assert(watcher.watchPaths.length == 1);
}
