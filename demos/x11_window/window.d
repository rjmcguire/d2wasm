// X11 window demo — D drives libX11 via extern(C)
//
// Opens a window, paints a few rectangles and a label, and quits on
// keypress or mouse click. Linux analogue of demos/metal/metal_demo.d.
//
//   ./d2wasm -r demos/x11_window/window.d
//   ./d2wasm --target=native demos/x11_window/window.d -o demos/x11_window/window
//   ./demos/x11_window/window

pragma(lib, "X11");

// Opaque X11 handles are pointer-sized (Display*, Window, GC).
extern(C) long XOpenDisplay(long name);
extern(C) int XDefaultScreen(long dpy);
extern(C) long XRootWindow(long dpy, int screen);
extern(C) long XBlackPixel(long dpy, int screen);
extern(C) long XWhitePixel(long dpy, int screen);
extern(C) long XDefaultGC(long dpy, int screen);
extern(C) long XCreateSimpleWindow(long dpy, long parent, int x, int y,
    int width, int height, int borderWidth, long border, long background);
extern(C) int XStoreName(long dpy, long win, char* title);
extern(C) int XSelectInput(long dpy, long win, long mask);
extern(C) int XMapWindow(long dpy, long win);
extern(C) int XFlush(long dpy);
extern(C) int XNextEvent(long dpy, XEvent* event);
extern(C) int XSetForeground(long dpy, long gc, long pixel);
extern(C) int XFillRectangle(long dpy, long win, long gc, int x, int y, int w, int h);
extern(C) int XDrawString(long dpy, long win, long gc, int x, int y, char* str, int len);
extern(C) int XCloseDisplay(long dpy);

// XEvent is a 192-byte union on 64-bit Xlib (long pad[24]).
// `type` is the leading int; the rest is padding so the size matches.
struct XEvent {
    int type;
    long[23] rest;
}

enum KEY_PRESS = 2;
enum BUTTON_PRESS = 4;
enum EXPOSE = 12;

// XSelectInput mask is a C long — keep it 64-bit so WASM/native FFI types match.
enum long KEY_PRESS_MASK = 1;
enum long BUTTON_PRESS_MASK = 4;
enum long EXPOSURE_MASK = 32768;

void paint(long dpy, long win, long xgc, long black, long white) {
    XSetForeground(dpy, xgc, white);
    XFillRectangle(dpy, win, xgc, 0, 0, 640, 400);

    XSetForeground(dpy, xgc, black);
    XFillRectangle(dpy, win, xgc, 40, 40, 560, 80);
    XFillRectangle(dpy, win, xgc, 40, 160, 200, 160);
    XFillRectangle(dpy, win, xgc, 280, 160, 320, 50);

    XSetForeground(dpy, xgc, white);
    XDrawString(dpy, win, xgc, 60, 88, "d2wasm / X11\0".ptr, 12);

    XSetForeground(dpy, xgc, black);
    XDrawString(dpy, win, xgc, 60, 220, "click or press a key to quit\0".ptr, 28);
    XFlush(dpy);
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

    long win = XCreateSimpleWindow(dpy, root, 100, 100, 640, 400, 2, black, white);
    XStoreName(dpy, win, "d2wasm\0".ptr);
    long eventMask = KEY_PRESS_MASK + BUTTON_PRESS_MASK + EXPOSURE_MASK;
    XSelectInput(dpy, win, eventMask);
    XMapWindow(dpy, win);
    XFlush(dpy);

    XEvent ev;
    int running = 1;
    while (running != 0) {
        XNextEvent(dpy, &ev);
        if (ev.type == EXPOSE)
            paint(dpy, win, xgc, black, white);
        if (ev.type == KEY_PRESS)
            running = 0;
        if (ev.type == BUTTON_PRESS)
            running = 0;
    }

    XCloseDisplay(dpy);
    return 0;
}
