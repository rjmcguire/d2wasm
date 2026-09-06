# X11 Plasma

Animated plasma: a sine table and RGB palette are generated at compile
time (`enum SINE = makeSine(); enum PAL = makePalette();`), then each
frame is written into a pixel buffer and blitted with `XPutImage`.

A HUD bar shows host RSS (`getrusage`), the 250 KiB pixel buffer, the
2 KiB CTFE tables, and instantaneous FPS.

Click the window or press a key to quit.

```bash
# JIT in wasm3 (loads libX11 via pragma(lib))
./d2wasm -r demos/x11_plasma/plasma.d

# Native x86-64 ELF
./d2wasm --target=native demos/x11_plasma/plasma.d -o demos/x11_plasma/plasma
./demos/x11_plasma/plasma
```

Needs a working X display (`DISPLAY=:0` on WSLg).
