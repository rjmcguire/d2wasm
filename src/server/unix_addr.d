/**
 * Address for the compile server's Unix domain socket.
 * On Windows, Phobos has no UnixAddress, so this builds the Winsock
 * sockaddr_un (AF_UNIX, UTF-8 path, 108-byte sun_path).
 */
module server.unix_addr;

import std.socket;

version (Windows) {
    private struct SockaddrUn {
        align(1):
        ushort family;
        char[108] path;
    }

    class WindowsUnixAddress : Address {
        private SockaddrUn sun;
        private socklen_t len;

        this(scope const(char)[] path) {
            import std.exception : enforce;
            enforce(path.length < sun.path.length,
                new SocketParameterException("Unix socket path too long"));
            sun.family = cast(ushort)AddressFamily.UNIX;
            sun.path[0 .. path.length] = path[];
            sun.path[path.length] = 0;
            len = cast(socklen_t)SockaddrUn.sizeof;
        }

        override @property sockaddr* name() pure nothrow @nogc {
            return cast(sockaddr*)&sun;
        }

        override @property const(sockaddr)* name() const pure nothrow @nogc {
            return cast(const(sockaddr)*)&sun;
        }

        override @property socklen_t nameLen() const pure nothrow @nogc {
            return len;
        }
    }
}

Address unixSocketAddress(string path) {
    version (Windows)
        return new WindowsUnixAddress(path);
    else
        return new UnixAddress(path);
}
