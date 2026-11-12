/* One NDJSON exchange over an AF_UNIX stream socket.
 *
 * stdin is the request. A trailing newline is added when it is missing.
 * The write side is shut down so the compile server finishes the line
 * instead of waiting out its read timeout. The response is written to stdout.
 *
 * Linux and macOS tests use nc -U when the path is a socket inode.
 * Git Bash does not report Winsock AF_UNIX files as sockets and often has
 * no nc, so those tests use this program.
 */
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef AF_UNIX
#define AF_UNIX 1
#endif

#pragma pack(push, 1)
struct sockaddr_un {
    unsigned short sun_family;
    char sun_path[108];
};
#pragma pack(pop)

typedef SOCKET sock_t;
#define NDJSON_INVALID INVALID_SOCKET
#define ndjson_close closesocket

static void die_sock(const char *what) {
    fprintf(stderr, "unix_ndjson: %s (WSA %d)\n", what, WSAGetLastError());
}

#else
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <errno.h>

typedef int sock_t;
#define NDJSON_INVALID (-1)
#define ndjson_close close

static void die_sock(const char *what) {
    fprintf(stderr, "unix_ndjson: %s (%s)\n", what, strerror(errno));
}
#endif

enum { REQ_MAX = 1024 * 1024 };

int main(int argc, char **argv) {
    char *req = NULL;
    size_t len = 0;
    size_t cap = 4096;
    sock_t s = NDJSON_INVALID;
    struct sockaddr_un addr;
    size_t path_len;
    int rc;

    if (argc != 2) {
        fprintf(stderr, "usage: unix_ndjson <socket-path>\n");
        return 2;
    }
    path_len = strlen(argv[1]);
    if (path_len == 0 || path_len >= sizeof(addr.sun_path)) {
        fprintf(stderr, "unix_ndjson: socket path empty or too long\n");
        return 2;
    }

#if defined(_WIN32)
    {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            die_sock("WSAStartup");
            return 1;
        }
    }
#endif

    req = (char *)malloc(cap);
    if (!req) {
        fprintf(stderr, "unix_ndjson: out of memory\n");
        return 1;
    }
    while (1) {
        size_t got;
        if (len == cap) {
            char *grown;
            if (cap >= REQ_MAX) {
                fprintf(stderr, "unix_ndjson: request too large\n");
                free(req);
                return 1;
            }
            cap *= 2;
            if (cap > REQ_MAX)
                cap = REQ_MAX;
            grown = (char *)realloc(req, cap);
            if (!grown) {
                fprintf(stderr, "unix_ndjson: out of memory\n");
                free(req);
                return 1;
            }
            req = grown;
        }
        got = fread(req + len, 1, cap - len, stdin);
        len += got;
        if (got == 0)
            break;
    }
    if (ferror(stdin)) {
        fprintf(stderr, "unix_ndjson: reading stdin failed\n");
        free(req);
        return 1;
    }
    if (len == 0 || req[len - 1] != '\n') {
        if (len == cap) {
            char *grown = (char *)realloc(req, len + 1);
            if (!grown) {
                fprintf(stderr, "unix_ndjson: out of memory\n");
                free(req);
                return 1;
            }
            req = grown;
        }
        req[len++] = '\n';
    }

    s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s == NDJSON_INVALID) {
        die_sock("socket");
        free(req);
        return 1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, argv[1], path_len);

#if defined(_WIN32)
    /* Match the compile server, which binds the full sockaddr_un. */
    rc = connect(s, (struct sockaddr *)&addr, (int)sizeof(addr));
#else
    rc = connect(s, (struct sockaddr *)&addr,
        (socklen_t)(offsetof(struct sockaddr_un, sun_path) + path_len + 1));
#endif
    if (rc != 0) {
        die_sock("connect");
        fprintf(stderr, "unix_ndjson: path %s\n", argv[1]);
        ndjson_close(s);
        free(req);
        return 1;
    }

    {
        size_t sent = 0;
        while (sent < len) {
#if defined(_WIN32)
            int n = send(s, req + sent, (int)(len - sent), 0);
#else
            ssize_t n = send(s, req + sent, len - sent, 0);
#endif
            if (n <= 0) {
                die_sock("send");
                ndjson_close(s);
                free(req);
                return 1;
            }
            sent += (size_t)n;
        }
    }
    free(req);
    req = NULL;

    /* EOF for the server's read loop. The response is still readable. */
#if defined(_WIN32)
    shutdown(s, SD_SEND);
#else
    shutdown(s, SHUT_WR);
#endif

    {
        char buf[4096];
        int saw_nl = 0;
        while (!saw_nl) {
#if defined(_WIN32)
            int n = recv(s, buf, (int)sizeof(buf), 0);
#else
            ssize_t n = recv(s, buf, sizeof(buf), 0);
#endif
            if (n < 0) {
                die_sock("recv");
                ndjson_close(s);
                return 1;
            }
            if (n == 0)
                break;
            if (fwrite(buf, 1, (size_t)n, stdout) != (size_t)n) {
                fprintf(stderr, "unix_ndjson: writing stdout failed\n");
                ndjson_close(s);
                return 1;
            }
            {
#if defined(_WIN32)
                int i;
                for (i = 0; i < n; i++) {
#else
                ssize_t i;
                for (i = 0; i < n; i++) {
#endif
                    if (buf[i] == '\n') {
                        saw_nl = 1;
                        break;
                    }
                }
            }
        }
        fflush(stdout);
    }

    ndjson_close(s);
#if defined(_WIN32)
    WSACleanup();
#endif
    return 0;
}
