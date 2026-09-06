// Plasma — CTFE sine/palette tables, XPutImage pixel buffer
//
//   ./d2wasm -r demos/x11_plasma/plasma.d
//   ./d2wasm --target=native demos/x11_plasma/plasma.d -o demos/x11_plasma/plasma
//
// Click or press a key to quit.

pragma(lib, "X11");

extern(C) long XOpenDisplay(long name);
extern(C) int XDefaultScreen(long dpy);
extern(C) long XRootWindow(long dpy, int screen);
extern(C) long XBlackPixel(long dpy, int screen);
extern(C) long XWhitePixel(long dpy, int screen);
extern(C) long XDefaultGC(long dpy, int screen);
extern(C) int XDefaultDepth(long dpy, int screen);
extern(C) long XDefaultVisual(long dpy, int screen);
extern(C) long XCreateSimpleWindow(long dpy, long parent, int x, int y,
    int width, int height, int borderWidth, long border, long background);
extern(C) int XStoreName(long dpy, long win, char* title);
extern(C) int XSelectInput(long dpy, long win, long mask);
extern(C) int XMapWindow(long dpy, long win);
extern(C) int XFlush(long dpy);
extern(C) int XPending(long dpy);
extern(C) int XNextEvent(long dpy, XEvent* event);
extern(C) long XCreateImage(long dpy, long visual, int depth, int format, int offset,
    char* data, int width, int height, int bitmapPad, int bytesPerLine);
extern(C) int XPutImage(long dpy, long drawable, long gc, long image,
    int srcX, int srcY, int destX, int destY, int width, int height);
extern(C) int XSetForeground(long dpy, long gc, long pixel);
extern(C) int XFillRectangle(long dpy, long win, long gc, int x, int y, int w, int h);
extern(C) int XDrawString(long dpy, long win, long gc, int x, int y, char* str, int len);
extern(C) int XCloseDisplay(long dpy);
extern(C) int usleep(int usec);
extern(C) int getrusage(int who, RUsage* usage);
extern(C) int gettimeofday(TimeVal* tv, long tz);

struct XEvent {
    int type;
    long[23] rest;
}

// Linux x86-64: timeval + timeval + ru_maxrss + 13 more longs = 144 bytes.
struct RUsage {
    long[4] times;
    long maxrss;
    long[13] rest;
}

struct TimeVal {
    long sec;
    long usec;
}

enum KEY_PRESS = 2;
enum BUTTON_PRESS = 4;
enum EXPOSE = 12;
enum long KEY_PRESS_MASK = 1;
enum long BUTTON_PRESS_MASK = 4;
enum long EXPOSURE_MASK = 32768;
enum ZPIXMAP = 2;

enum W = 320;
enum H = 200;
enum HUD_H = 18;
enum PIX_KB = (W * H * 4) / 1024;
enum TBL_KB = 2;

// Taylor sine, range-reduced. Used only at compile time.
double sin_t(double x) {
    double pi = 3.141592653589793;
    double twopi = 6.283185307179586;
    while (x > pi)
        x = x - twopi;
    while (x < -pi)
        x = x + twopi;
    double x2 = x * x;
    return x * (1.0 - x2 * (0.16666666666666667 - x2 * (0.008333333333333333
        - x2 * 0.0001984126984126984)));
}

int[256] makeSine() {
    int[256] t;
    int i = 0;
    while (i < 256) {
        double a = (cast(double)i) * 0.02454369260617026;
        double s = sin_t(a);
        t[i] = 128 + cast(int)(s * 127.0);
        i = i + 1;
    }
    return t;
}

// Classic plasma palette: purple → magenta → orange → yellow → white.
int[256] makePalette() {
    int[256] p;
    int i = 0;
    while (i < 256) {
        int r;
        int g;
        int b;
        if (i < 64) {
            r = i * 2;
            g = 0;
            b = i * 4;
        } else if (i < 128) {
            r = 128 + (i - 64) * 2;
            g = (i - 64) * 2;
            b = 255 - (i - 64) * 4;
        } else if (i < 192) {
            r = 255;
            g = 128 + (i - 128) * 2;
            b = 0;
        } else {
            r = 255;
            g = 255;
            b = (i - 192) * 4;
        }
        p[i] = (r << 16) | (g << 8) | b;
        i = i + 1;
    }
    return p;
}

enum SINE = makeSine();
enum PAL = makePalette();

int putStr(char* dst, int pos, char* s, int n) {
    int i = 0;
    while (i < n) {
        dst[pos] = s[i];
        pos = pos + 1;
        i = i + 1;
    }
    return pos;
}

int putInt(char* dst, int pos, int v) {
    if (v < 0) {
        dst[pos] = 45;
        pos = pos + 1;
        v = 0 - v;
    }
    if (v == 0) {
        dst[pos] = 48;
        return pos + 1;
    }
    int[12] digits;
    int n = 0;
    while (v > 0) {
        digits[n] = 48 + (v % 10);
        n = n + 1;
        v = v / 10;
    }
    while (n > 0) {
        n = n - 1;
        dst[pos] = cast(char)digits[n];
        pos = pos + 1;
    }
    return pos;
}

int formatHud(char* dst, int rssKb, int fps) {
    int n = 0;
    n = putStr(dst, n, "rss \0".ptr, 4);
    n = putInt(dst, n, rssKb);
    n = putStr(dst, n, "k  pix \0".ptr, 7);
    n = putInt(dst, n, PIX_KB);
    n = putStr(dst, n, "k  tbl \0".ptr, 7);
    n = putInt(dst, n, TBL_KB);
    n = putStr(dst, n, "k  \0".ptr, 3);
    n = putInt(dst, n, fps);
    n = putStr(dst, n, "fps\0".ptr, 3);
    return n;
}

void drawHud(long dpy, long win, long xgc, long black, long white, int rssKb, int fps) {
    char[64] line;
    int n = formatHud(line.ptr, rssKb, fps);
    XSetForeground(dpy, xgc, black);
    XFillRectangle(dpy, win, xgc, 0, H - HUD_H, W, HUD_H);
    XSetForeground(dpy, xgc, white);
    XDrawString(dpy, win, xgc, 6, H - 5, line.ptr, n);
}

void plasmaFrame(int* pix, int t) {
    int y = 0;
    while (y < H) {
        int x = 0;
        while (x < W) {
            int v = SINE[(x + t) & 255];
            v = v + SINE[(y + t + t) & 255];
            v = v + SINE[(x + y + t) & 255];
            v = v + SINE[((x * y) / 64 + t) & 255];
            pix[y * W + x] = PAL[v & 255];
            x = x + 1;
        }
        y = y + 1;
    }
}

int main() {
    long dpy = XOpenDisplay(0);
    if (dpy == 0)
        return 1;

    int screen = XDefaultScreen(dpy);
    long root = XRootWindow(dpy, screen);
    long black = XBlackPixel(dpy, screen);
    long white = XWhitePixel(dpy, screen);
    long xgc = XDefaultGC(dpy, screen);
    int depth = XDefaultDepth(dpy, screen);
    long visual = XDefaultVisual(dpy, screen);

    long win = XCreateSimpleWindow(dpy, root, 80, 80, W, H, 2, black, white);
    XStoreName(dpy, win, "d2wasm plasma\0".ptr);
    long eventMask = KEY_PRESS_MASK + BUTTON_PRESS_MASK + EXPOSURE_MASK;
    XSelectInput(dpy, win, eventMask);
    XMapWindow(dpy, win);

    int[64000] pix;
    long img = XCreateImage(dpy, visual, depth, ZPIXMAP, 0,
        cast(char*)pix.ptr, W, H, 32, W * 4);
    if (img == 0)
        return 2;

    XEvent ev;
    RUsage ru;
    TimeVal tv;
    long lastSec = 0;
    long lastUsec = 0;
    int fps = 0;
    int t = 0;
    int running = 1;
    gettimeofday(&tv, 0);
    lastSec = tv.sec;
    lastUsec = tv.usec;
    while (running != 0) {
        while (XPending(dpy) != 0) {
            XNextEvent(dpy, &ev);
            if (ev.type == KEY_PRESS)
                running = 0;
            if (ev.type == BUTTON_PRESS)
                running = 0;
        }
        if (running != 0) {
            plasmaFrame(pix.ptr, t);
            XPutImage(dpy, win, xgc, img, 0, 0, 0, 0, W, H);
            getrusage(0, &ru);
            gettimeofday(&tv, 0);
            int dt = cast(int)((tv.sec - lastSec) * 1000000 + (tv.usec - lastUsec));
            if (dt > 0)
                fps = 1000000 / dt;
            lastSec = tv.sec;
            lastUsec = tv.usec;
            drawHud(dpy, win, xgc, black, white, cast(int)ru.maxrss, fps);
            XFlush(dpy);
            t = t + 1;
            usleep(16000);
        }
    }

    XCloseDisplay(dpy);
    return 0;
}
