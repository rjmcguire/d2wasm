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
extern(C) int XCloseDisplay(long dpy);
extern(C) int usleep(int usec);

struct XEvent {
    int type;
    long[23] rest;
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
    int t = 0;
    int running = 1;
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
            XFlush(dpy);
            t = t + 1;
            usleep(16000);
        }
    }

    XCloseDisplay(dpy);
    return 0;
}
