// D Code Editor — native macOS, Metal-rendered text, extern(Objective-C)
//
// Architecture: same pattern as demos/metal/metal_demo.d
// All state in EditorState struct created in main(), no module-level globals.
// Compile: d2wasm demos/editor/editor.d -o editor --target=arm64-macos

pragma(lib, "/System/Library/Frameworks/Metal.framework/Metal");
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");
pragma(lib, "/System/Library/Frameworks/Cocoa.framework/Cocoa");
pragma(lib, "/System/Library/Frameworks/QuartzCore.framework/QuartzCore");

// ── Struct Types ───────────────────────────────────────────────────

struct NSPoint { double x; double y; }
struct NSRect { double x; double y; double width; double height; }
struct CGSize { double width; double height; }
struct MTLClearColor { double red; double green; double blue; double alpha; }

// ── ObjC Interfaces ────────────────────────────────────────────────

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
    void release() @selector("release");
}

extern(Objective-C)
interface NSApplication {
    static NSApplication sharedApplication() @selector("sharedApplication");
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    void activateIgnoringOtherApps(int flag) @selector("activateIgnoringOtherApps:");
    NSEvent nextEventMatchingMask(long mask, NSDate untilDate, NSString inMode, int dequeue)
        @selector("nextEventMatchingMask:untilDate:inMode:dequeue:");
    void sendEvent(NSEvent event) @selector("sendEvent:");
    void updateWindows() @selector("updateWindows");
}

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(char* cstr) @selector("stringWithUTF8String:");
    char* UTF8String() @selector("UTF8String");
}

extern(Objective-C)
interface NSWindow {
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect rect, long styleMask, long backing, int defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void makeKeyAndOrderFront(long sender) @selector("makeKeyAndOrderFront:");
    long contentView() @selector("contentView");
    void setDelegate(long del) @selector("setDelegate:");
}

extern(Objective-C)
interface NSView {
    static NSView alloc() @selector("alloc");
    NSView initWithFrame(NSRect frame_) @selector("initWithFrame:");
    void setWantsLayer(int flag) @selector("setWantsLayer:");
    void setLayer(long layer) @selector("setLayer:");
    void setAutoresizingMask(long mask) @selector("setAutoresizingMask:");
    void addSubview(long view) @selector("addSubview:");
    NSRect bounds() @selector("bounds");
}

extern(Objective-C)
interface NSEvent {
    NSPoint locationInWindow() @selector("locationInWindow");
    long type_() @selector("type");
    NSString characters() @selector("characters");
    int keyCode() @selector("keyCode");
    long modifierFlags() @selector("modifierFlags");
}

extern(Objective-C)
interface NSDate {
    static NSDate dateWithTimeIntervalSinceNow(double secs)
        @selector("dateWithTimeIntervalSinceNow:");
}

extern(Objective-C)
interface CAMetalLayer {
    static CAMetalLayer layer() @selector("layer");
    void setDevice(long device) @selector("setDevice:");
    void setPixelFormat(long fmt) @selector("setPixelFormat:");
    void setFramebufferOnly(int flag) @selector("setFramebufferOnly:");
    void setDrawableSize(CGSize size) @selector("setDrawableSize:");
    CAMetalDrawable nextDrawable() @selector("nextDrawable");
}

extern(Objective-C)
interface MTLDevice {
    MTLCommandQueue newCommandQueue() @selector("newCommandQueue");
    MTLLibrary newLibraryWithSource(NSString source, long options, long errPtr)
        @selector("newLibraryWithSource:options:error:");
    NSString name() @selector("name");
    long newRenderPipelineStateWithDescriptor(long desc, long error)
        @selector("newRenderPipelineStateWithDescriptor:error:");
    long newBufferWithBytes(ubyte* bytes, long length, long options)
        @selector("newBufferWithBytes:length:options:");
}

extern(Objective-C)
interface MTLLibrary {
    long newFunctionWithName(NSString name) @selector("newFunctionWithName:");
}

extern(Objective-C)
interface MTLCommandQueue {
    MTLCommandBuffer commandBuffer() @selector("commandBuffer");
}

extern(Objective-C)
interface CAMetalDrawable {
    long texture() @selector("texture");
}

extern(Objective-C)
interface MTLRenderPassColorAttachmentDescriptor {
    void setTexture(long texture) @selector("setTexture:");
    void setLoadAction(long action) @selector("setLoadAction:");
    void setClearColor(MTLClearColor color) @selector("setClearColor:");
    void setStoreAction(long action) @selector("setStoreAction:");
    void setPixelFormat(long fmt) @selector("setPixelFormat:");
}

extern(Objective-C)
interface MTLRenderPassColorAttachmentDescriptorArray {
    MTLRenderPassColorAttachmentDescriptor objectAtIndexedSubscript(long idx)
        @selector("objectAtIndexedSubscript:");
}

extern(Objective-C)
interface MTLRenderPassDescriptor {
    static MTLRenderPassDescriptor renderPassDescriptor() @selector("renderPassDescriptor");
    MTLRenderPassColorAttachmentDescriptorArray colorAttachments() @selector("colorAttachments");
}

extern(Objective-C)
interface MTLRenderPipelineDescriptor {
    static MTLRenderPipelineDescriptor alloc() @selector("alloc");
    MTLRenderPipelineDescriptor init_() @selector("init");
    void setVertexFunction(long func) @selector("setVertexFunction:");
    void setFragmentFunction(long func) @selector("setFragmentFunction:");
    MTLRenderPassColorAttachmentDescriptorArray colorAttachments() @selector("colorAttachments");
}

extern(Objective-C)
interface MTLCommandBuffer {
    MTLRenderCommandEncoder renderCommandEncoderWithDescriptor(MTLRenderPassDescriptor desc)
        @selector("renderCommandEncoderWithDescriptor:");
    void presentDrawable(CAMetalDrawable drawable) @selector("presentDrawable:");
    void commit() @selector("commit");
    void waitUntilCompleted() @selector("waitUntilCompleted");
}

extern(Objective-C)
interface MTLRenderCommandEncoder {
    void setRenderPipelineState(long state) @selector("setRenderPipelineState:");
    void setVertexBuffer(long buf, long offset, long atIndex)
        @selector("setVertexBuffer:offset:atIndex:");
    void setFragmentBuffer(long buf, long offset, long atIndex)
        @selector("setFragmentBuffer:offset:atIndex:");
    void drawPrimitives(long type, long start, long count)
        @selector("drawPrimitives:vertexStart:vertexCount:");
    void endEncoding() @selector("endEncoding");
}

// ── C Functions ─────────────────────────────────────────────────────

extern(C) long MTLCreateSystemDefaultDevice();
extern(C) long objc_autoreleasePoolPush();
extern(C) void objc_autoreleasePoolPop(long pool);

// ── Editor State ────────────────────────────────────────────────────

// Window close flag — must be accessible from ObjC class method
int g_windowClosed = 0;

// Key input queue — set by EditorView.keyDown, consumed by main loop
int g_keyCode = 0;
int g_keyChar = 0;
int g_hasKey = 0;
long g_keyMods = 0;

// ── Text Buffer ─────────────────────────────────────────────────────

struct TextBuffer {
    ubyte[65536] data;
    int len;
    int[2000] lineStart;
    int[2000] lineLen;
    int lineCount;
    int cursorLine;
    int cursorCol;
    int scrollLine;
    int needsRedraw;
}

void initTextBuffer(TextBuffer* buf) {
    buf.len = 0;
    buf.lineCount = 1;
    buf.lineStart[0] = 0;
    buf.lineLen[0] = 0;
    buf.cursorLine = 0;
    buf.cursorCol = 0;
    buf.scrollLine = 0;
    buf.needsRedraw = 1;
}

void recomputeLines(TextBuffer* buf) {
    buf.lineCount = 0;
    int lineStart = 0;
    int i = 0;
    while (i < buf.len) {
        if (buf.data[i] == 10) {
            if (buf.lineCount < 2000) {
                buf.lineStart[buf.lineCount] = lineStart;
                buf.lineLen[buf.lineCount] = i - lineStart;
                buf.lineCount = buf.lineCount + 1;
            }
            lineStart = i + 1;
        }
        i = i + 1;
    }
    // Last line (no trailing newline)
    if (buf.lineCount < 2000) {
        buf.lineStart[buf.lineCount] = lineStart;
        buf.lineLen[buf.lineCount] = buf.len - lineStart;
        buf.lineCount = buf.lineCount + 1;
    }
}

int cursorByteOffset(TextBuffer* buf) {
    if (buf.cursorLine >= buf.lineCount) return buf.len;
    return buf.lineStart[buf.cursorLine] + buf.cursorCol;
}

void insertCharAtCursor(TextBuffer* buf, int ch) {
    if (buf.len >= 65535) return;
    int pos = cursorByteOffset(buf);
    // Shift tail right by 1
    int j = buf.len;
    while (j > pos) {
        buf.data[j] = buf.data[j - 1];
        j = j - 1;
    }
    buf.data[pos] = cast(ubyte) ch;
    buf.len = buf.len + 1;
    buf.cursorCol = buf.cursorCol + 1;
    recomputeLines(buf);
    buf.needsRedraw = 1;
}

void insertNewline(TextBuffer* buf) {
    insertCharAtCursor(buf, 10);
    buf.cursorLine = buf.cursorLine + 1;
    buf.cursorCol = 0;
}

void deleteCharBeforeCursor(TextBuffer* buf) {
    int pos = cursorByteOffset(buf);
    if (pos <= 0) return;
    // Shift tail left by 1
    int j = pos - 1;
    while (j < buf.len - 1) {
        buf.data[j] = buf.data[j + 1];
        j = j + 1;
    }
    buf.len = buf.len - 1;
    // Update cursor
    if (buf.cursorCol > 0) {
        buf.cursorCol = buf.cursorCol - 1;
    } else {
        if (buf.cursorLine > 0) {
            buf.cursorLine = buf.cursorLine - 1;
            recomputeLines(buf);
            if (buf.cursorLine < buf.lineCount) {
                buf.cursorCol = buf.lineLen[buf.cursorLine];
            }
            buf.needsRedraw = 1;
            return;
        }
    }
    recomputeLines(buf);
    buf.needsRedraw = 1;
}

void moveCursorLeft(TextBuffer* buf) {
    if (buf.cursorCol > 0) {
        buf.cursorCol = buf.cursorCol - 1;
    } else {
        if (buf.cursorLine > 0) {
            buf.cursorLine = buf.cursorLine - 1;
            buf.cursorCol = buf.lineLen[buf.cursorLine];
        }
    }
    buf.needsRedraw = 1;
}

void moveCursorRight(TextBuffer* buf) {
    if (buf.cursorLine < buf.lineCount) {
        if (buf.cursorCol < buf.lineLen[buf.cursorLine]) {
            buf.cursorCol = buf.cursorCol + 1;
        } else {
            if (buf.cursorLine < buf.lineCount - 1) {
                buf.cursorLine = buf.cursorLine + 1;
                buf.cursorCol = 0;
            }
        }
    }
    buf.needsRedraw = 1;
}

void moveCursorUp(TextBuffer* buf) {
    if (buf.cursorLine > 0) {
        buf.cursorLine = buf.cursorLine - 1;
        if (buf.cursorCol > buf.lineLen[buf.cursorLine]) {
            buf.cursorCol = buf.lineLen[buf.cursorLine];
        }
    }
    buf.needsRedraw = 1;
}

void moveCursorDown(TextBuffer* buf) {
    if (buf.cursorLine < buf.lineCount - 1) {
        buf.cursorLine = buf.cursorLine + 1;
        if (buf.cursorCol > buf.lineLen[buf.cursorLine]) {
            buf.cursorCol = buf.lineLen[buf.cursorLine];
        }
    }
    buf.needsRedraw = 1;
}

// ── ObjC Classes ────────────────────────────────────────────────────

extern(Objective-C)
class EditorWindowDelegate : NSObject {
    static EditorWindowDelegate myAlloc() @selector("alloc");
    EditorWindowDelegate myInit() @selector("init");

    void windowWillClose(long notification) @selector("windowWillClose:") {
        g_windowClosed = 1;
    }
}

extern(Objective-C)
class EditorView : NSView {
    static EditorView myAlloc() @selector("alloc");
    EditorView myInitWithFrame(NSRect frame_) @selector("initWithFrame:");

    int acceptsFirstResponder() @selector("acceptsFirstResponder") {
        return 1;
    }

    int acceptsFirstMouse(long event) @selector("acceptsFirstMouse:") {
        return 1;
    }

    void keyDown(long rawEvent) @selector("keyDown:") {
        NSEvent event = cast(NSEvent) rawEvent;
        g_keyCode = event.keyCode();
        g_keyMods = event.modifierFlags();
        // Get typed character
        NSString chars = event.characters();
        if (cast(long)chars != 0) {
            char* utf8 = chars.UTF8String();
            if (cast(long)utf8 != 0) {
                g_keyChar = cast(int) cast(ubyte) utf8[0];
            } else {
                g_keyChar = 0;
            }
        } else {
            g_keyChar = 0;
        }
        g_hasKey = 1;
    }
}

// ── Rendering ───────────────────────────────────────────────────────

// Metal shader: renders quads with per-vertex glyph lookup from font buffer
// Vertex buffer layout: 9 floats per vertex (pos.xy, uv.xy, rgba, glyphIdx)
// Font buffer: 1520 bytes of 8x16 bitmap data for ASCII 32-126

string shaderSource() {
    return "#include <metal_stdlib>\n" ~
        "using namespace metal;\n" ~
        "struct VertexOut {\n" ~
        "  float4 position [[position]];\n" ~
        "  float2 texcoord;\n" ~
        "  float4 color;\n" ~
        "  float glyphIndex;\n" ~
        "};\n" ~
        "vertex VertexOut vertex_main(uint vid [[vertex_id]],\n" ~
        "  const device float *data [[buffer(0)]]) {\n" ~
        "  uint b = vid * 9;\n" ~
        "  VertexOut o;\n" ~
        "  o.position = float4(data[b], data[b+1], 0.0, 1.0);\n" ~
        "  o.texcoord = float2(data[b+2], data[b+3]);\n" ~
        "  o.color = float4(data[b+4], data[b+5], data[b+6], data[b+7]);\n" ~
        "  o.glyphIndex = data[b+8];\n" ~
        "  return o;\n" ~
        "}\n" ~
        "fragment float4 fragment_main(VertexOut in [[stage_in]],\n" ~
        "  const device uchar *font [[buffer(0)]]) {\n" ~
        "  int gi = int(in.glyphIndex);\n" ~
        "  int row = clamp(int(in.texcoord.y * 16.0), 0, 15);\n" ~
        "  int col = clamp(int(in.texcoord.x * 8.0), 0, 7);\n" ~
        "  uchar bits = font[gi * 16 + row];\n" ~
        "  if (!((bits >> (7 - col)) & 1)) discard_fragment();\n" ~
        "  return in.color;\n" ~
        "}\n";
}

// Emit one vertex (9 floats) into the batch. Returns new write offset.
int emitVertex(float* verts, int off, float px, float py, float u, float v,
        float r, float g, float b, float gi) {
    verts[off]   = px; verts[off+1] = py;
    verts[off+2] = u;  verts[off+3] = v;
    verts[off+4] = r;  verts[off+5] = g;
    verts[off+6] = b;  verts[off+7] = 1.0;
    verts[off+8] = gi;
    return off + 9;
}

// Add a character quad (6 vertices = 2 triangles) to the vertex batch.
// sx, sy = top-left in NDC, cw/ch = char size in NDC.
void addCharQuad(float* verts, int* count, float sx, float sy,
        float cw, float ch, int charCode, int color) {
    int glyphIdx = charCode - 32;
    if (glyphIdx < 0) glyphIdx = 0;
    if (glyphIdx > 95) glyphIdx = 0;  // 0-94 = printable ASCII, 95 = solid block
    float gi = cast(float) glyphIdx;
    float x1 = sx + cw;
    float y1 = sy - ch;
    // Unpack color: 0xRRGGBB
    float r = cast(float)(cast(float)((color >> 16) & 0xFF) / 255.0);
    float g = cast(float)(cast(float)((color >> 8) & 0xFF) / 255.0);
    float b = cast(float)(cast(float)(color & 0xFF) / 255.0);

    int off = *count * 9;
    off = emitVertex(verts, off, sx, sy, 0.0, 0.0, r, g, b, gi);
    off = emitVertex(verts, off, x1, sy, 1.0, 0.0, r, g, b, gi);
    off = emitVertex(verts, off, sx, y1, 0.0, 1.0, r, g, b, gi);
    off = emitVertex(verts, off, x1, sy, 1.0, 0.0, r, g, b, gi);
    off = emitVertex(verts, off, x1, y1, 1.0, 1.0, r, g, b, gi);
    off = emitVertex(verts, off, sx, y1, 0.0, 1.0, r, g, b, gi);
    *count = *count + 6;
}

// ── 8x16 Bitmap Font Data ───────────────────────────────────────────
// Classic CP437-style monospace font, ASCII 32-126 (95 chars)
// Each char = 16 bytes, 1 bit per pixel, MSB = leftmost

void initFontData(ubyte* font) {
    // Space (32) — all zeros
    int i = 0;
    while (i < 16) { font[i] = 0; i = i + 1; }
    // ! (33)
    font[16] = 0x00; font[17] = 0x00; font[18] = 0x18; font[19] = 0x18;
    font[20] = 0x18; font[21] = 0x18; font[22] = 0x18; font[23] = 0x18;
    font[24] = 0x00; font[25] = 0x18; font[26] = 0x18; font[27] = 0x00;
    font[28] = 0x00; font[29] = 0x00; font[30] = 0x00; font[31] = 0x00;
    // " (34)
    font[32] = 0x00; font[33] = 0x00; font[34] = 0x66; font[35] = 0x66;
    font[36] = 0x66; font[37] = 0x24; font[38] = 0x00; font[39] = 0x00;
    font[40] = 0x00; font[41] = 0x00; font[42] = 0x00; font[43] = 0x00;
    font[44] = 0x00; font[45] = 0x00; font[46] = 0x00; font[47] = 0x00;
    // # (35)
    font[48] = 0x00; font[49] = 0x00; font[50] = 0x00; font[51] = 0x36;
    font[52] = 0x36; font[53] = 0x7F; font[54] = 0x36; font[55] = 0x36;
    font[56] = 0x7F; font[57] = 0x36; font[58] = 0x36; font[59] = 0x00;
    font[60] = 0x00; font[61] = 0x00; font[62] = 0x00; font[63] = 0x00;

    // For now, fill remaining glyphs with simple patterns
    // Letters A-Z (65-90), a-z (97-122), digits 0-9 (48-57)
    // We'll populate key characters and leave others as placeholder blocks

    // Initialize all remaining with a solid block placeholder
    int ch = 4;  // Start from char 36 (after #)
    while (ch < 95) {
        int base = ch * 16;
        int row = 0;
        while (row < 16) {
            font[base + row] = 0x00;
            row = row + 1;
        }
        ch = ch + 1;
    }

    // 0 (48 - glyph index 16)
    setGlyph(font, 16, 0x00,0x00,0x3C,0x66,0x66,0x6E,0x76,0x66,0x66,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // 1
    setGlyph(font, 17, 0x00,0x00,0x18,0x38,0x18,0x18,0x18,0x18,0x18,0x18,0x7E,0x00,0x00,0x00,0x00,0x00);
    // 2
    setGlyph(font, 18, 0x00,0x00,0x3C,0x66,0x06,0x0C,0x18,0x30,0x60,0x66,0x7E,0x00,0x00,0x00,0x00,0x00);
    // 3
    setGlyph(font, 19, 0x00,0x00,0x3C,0x66,0x06,0x06,0x1C,0x06,0x06,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // 4
    setGlyph(font, 20, 0x00,0x00,0x0C,0x1C,0x3C,0x6C,0x6C,0x7E,0x0C,0x0C,0x0C,0x00,0x00,0x00,0x00,0x00);
    // 5
    setGlyph(font, 21, 0x00,0x00,0x7E,0x60,0x60,0x7C,0x06,0x06,0x06,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // 6
    setGlyph(font, 22, 0x00,0x00,0x1C,0x30,0x60,0x7C,0x66,0x66,0x66,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // 7
    setGlyph(font, 23, 0x00,0x00,0x7E,0x66,0x06,0x0C,0x18,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00,0x00);
    // 8
    setGlyph(font, 24, 0x00,0x00,0x3C,0x66,0x66,0x66,0x3C,0x66,0x66,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // 9
    setGlyph(font, 25, 0x00,0x00,0x3C,0x66,0x66,0x66,0x3E,0x06,0x06,0x0C,0x38,0x00,0x00,0x00,0x00,0x00);

    // A (65 - glyph index 33)
    setGlyph(font, 33, 0x00,0x00,0x18,0x3C,0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // B
    setGlyph(font, 34, 0x00,0x00,0x7C,0x66,0x66,0x66,0x7C,0x66,0x66,0x66,0x7C,0x00,0x00,0x00,0x00,0x00);
    // C
    setGlyph(font, 35, 0x00,0x00,0x3C,0x66,0x60,0x60,0x60,0x60,0x60,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // D
    setGlyph(font, 36, 0x00,0x00,0x78,0x6C,0x66,0x66,0x66,0x66,0x66,0x6C,0x78,0x00,0x00,0x00,0x00,0x00);
    // E
    setGlyph(font, 37, 0x00,0x00,0x7E,0x60,0x60,0x60,0x7C,0x60,0x60,0x60,0x7E,0x00,0x00,0x00,0x00,0x00);
    // F
    setGlyph(font, 38, 0x00,0x00,0x7E,0x60,0x60,0x60,0x7C,0x60,0x60,0x60,0x60,0x00,0x00,0x00,0x00,0x00);
    // G
    setGlyph(font, 39, 0x00,0x00,0x3C,0x66,0x60,0x60,0x6E,0x66,0x66,0x66,0x3E,0x00,0x00,0x00,0x00,0x00);
    // H
    setGlyph(font, 40, 0x00,0x00,0x66,0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // I
    setGlyph(font, 41, 0x00,0x00,0x3C,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00,0x00);
    // J
    setGlyph(font, 42, 0x00,0x00,0x0E,0x06,0x06,0x06,0x06,0x06,0x66,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // K
    setGlyph(font, 43, 0x00,0x00,0x66,0x6C,0x78,0x70,0x70,0x78,0x6C,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // L
    setGlyph(font, 44, 0x00,0x00,0x60,0x60,0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00,0x00,0x00,0x00,0x00);
    // M
    setGlyph(font, 45, 0x00,0x00,0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x63,0x63,0x00,0x00,0x00,0x00,0x00);
    // N
    setGlyph(font, 46, 0x00,0x00,0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // O
    setGlyph(font, 47, 0x00,0x00,0x3C,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // P
    setGlyph(font, 48, 0x00,0x00,0x7C,0x66,0x66,0x66,0x7C,0x60,0x60,0x60,0x60,0x00,0x00,0x00,0x00,0x00);
    // Q
    setGlyph(font, 49, 0x00,0x00,0x3C,0x66,0x66,0x66,0x66,0x66,0x66,0x6E,0x3C,0x0E,0x00,0x00,0x00,0x00);
    // R
    setGlyph(font, 50, 0x00,0x00,0x7C,0x66,0x66,0x66,0x7C,0x6C,0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // S
    setGlyph(font, 51, 0x00,0x00,0x3C,0x66,0x60,0x30,0x18,0x0C,0x06,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // T
    setGlyph(font, 52, 0x00,0x00,0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00,0x00);
    // U
    setGlyph(font, 53, 0x00,0x00,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // V
    setGlyph(font, 54, 0x00,0x00,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00,0x00,0x00,0x00,0x00);
    // W
    setGlyph(font, 55, 0x00,0x00,0x63,0x63,0x63,0x63,0x6B,0x6B,0x7F,0x77,0x63,0x00,0x00,0x00,0x00,0x00);
    // X
    setGlyph(font, 56, 0x00,0x00,0x66,0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // Y
    setGlyph(font, 57, 0x00,0x00,0x66,0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00,0x00);
    // Z
    setGlyph(font, 58, 0x00,0x00,0x7E,0x06,0x06,0x0C,0x18,0x30,0x60,0x60,0x7E,0x00,0x00,0x00,0x00,0x00);

    // a (97 - glyph index 65)
    setGlyph(font, 65, 0x00,0x00,0x00,0x00,0x00,0x3C,0x06,0x3E,0x66,0x66,0x3E,0x00,0x00,0x00,0x00,0x00);
    // b
    setGlyph(font, 66, 0x00,0x00,0x60,0x60,0x60,0x7C,0x66,0x66,0x66,0x66,0x7C,0x00,0x00,0x00,0x00,0x00);
    // c
    setGlyph(font, 67, 0x00,0x00,0x00,0x00,0x00,0x3C,0x66,0x60,0x60,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // d
    setGlyph(font, 68, 0x00,0x00,0x06,0x06,0x06,0x3E,0x66,0x66,0x66,0x66,0x3E,0x00,0x00,0x00,0x00,0x00);
    // e
    setGlyph(font, 69, 0x00,0x00,0x00,0x00,0x00,0x3C,0x66,0x7E,0x60,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // f
    setGlyph(font, 70, 0x00,0x00,0x0E,0x18,0x18,0x3E,0x18,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00,0x00);
    // g
    setGlyph(font, 71, 0x00,0x00,0x00,0x00,0x00,0x3E,0x66,0x66,0x66,0x3E,0x06,0x66,0x3C,0x00,0x00,0x00);
    // h
    setGlyph(font, 72, 0x00,0x00,0x60,0x60,0x60,0x7C,0x66,0x66,0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // i
    setGlyph(font, 73, 0x00,0x00,0x18,0x18,0x00,0x38,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00,0x00);
    // j
    setGlyph(font, 74, 0x00,0x00,0x06,0x06,0x00,0x0E,0x06,0x06,0x06,0x06,0x66,0x66,0x3C,0x00,0x00,0x00);
    // k
    setGlyph(font, 75, 0x00,0x00,0x60,0x60,0x60,0x66,0x6C,0x78,0x6C,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // l
    setGlyph(font, 76, 0x00,0x00,0x38,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00,0x00);
    // m
    setGlyph(font, 77, 0x00,0x00,0x00,0x00,0x00,0x76,0x7F,0x6B,0x6B,0x63,0x63,0x00,0x00,0x00,0x00,0x00);
    // n
    setGlyph(font, 78, 0x00,0x00,0x00,0x00,0x00,0x7C,0x66,0x66,0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // o
    setGlyph(font, 79, 0x00,0x00,0x00,0x00,0x00,0x3C,0x66,0x66,0x66,0x66,0x3C,0x00,0x00,0x00,0x00,0x00);
    // p
    setGlyph(font, 80, 0x00,0x00,0x00,0x00,0x00,0x7C,0x66,0x66,0x66,0x7C,0x60,0x60,0x60,0x00,0x00,0x00);
    // q
    setGlyph(font, 81, 0x00,0x00,0x00,0x00,0x00,0x3E,0x66,0x66,0x66,0x3E,0x06,0x06,0x06,0x00,0x00,0x00);
    // r
    setGlyph(font, 82, 0x00,0x00,0x00,0x00,0x00,0x6C,0x76,0x60,0x60,0x60,0x60,0x00,0x00,0x00,0x00,0x00);
    // s
    setGlyph(font, 83, 0x00,0x00,0x00,0x00,0x00,0x3E,0x60,0x3C,0x06,0x06,0x7C,0x00,0x00,0x00,0x00,0x00);
    // t
    setGlyph(font, 84, 0x00,0x00,0x18,0x18,0x18,0x7E,0x18,0x18,0x18,0x18,0x0E,0x00,0x00,0x00,0x00,0x00);
    // u
    setGlyph(font, 85, 0x00,0x00,0x00,0x00,0x00,0x66,0x66,0x66,0x66,0x66,0x3E,0x00,0x00,0x00,0x00,0x00);
    // v
    setGlyph(font, 86, 0x00,0x00,0x00,0x00,0x00,0x66,0x66,0x66,0x66,0x3C,0x18,0x00,0x00,0x00,0x00,0x00);
    // w
    setGlyph(font, 87, 0x00,0x00,0x00,0x00,0x00,0x63,0x63,0x6B,0x6B,0x7F,0x36,0x00,0x00,0x00,0x00,0x00);
    // x
    setGlyph(font, 88, 0x00,0x00,0x00,0x00,0x00,0x66,0x66,0x3C,0x3C,0x66,0x66,0x00,0x00,0x00,0x00,0x00);
    // y
    setGlyph(font, 89, 0x00,0x00,0x00,0x00,0x00,0x66,0x66,0x66,0x66,0x3E,0x06,0x66,0x3C,0x00,0x00,0x00);
    // z
    setGlyph(font, 90, 0x00,0x00,0x00,0x00,0x00,0x7E,0x0C,0x18,0x30,0x60,0x7E,0x00,0x00,0x00,0x00,0x00);

    // Key punctuation
    // ( (40 - glyph index 8)
    setGlyph(font, 8,  0x00,0x00,0x0C,0x18,0x30,0x30,0x30,0x30,0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00);
    // ) (41 - glyph index 9)
    setGlyph(font, 9,  0x00,0x00,0x30,0x18,0x0C,0x0C,0x0C,0x0C,0x0C,0x18,0x30,0x00,0x00,0x00,0x00,0x00);
    // * (42 - glyph index 10)
    setGlyph(font, 10, 0x00,0x00,0x00,0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00,0x00,0x00,0x00,0x00,0x00);
    // + (43 - glyph index 11)
    setGlyph(font, 11, 0x00,0x00,0x00,0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00,0x00,0x00,0x00,0x00,0x00);
    // , (44 - glyph index 12)
    setGlyph(font, 12, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30,0x00,0x00,0x00,0x00);
    // - (45 - glyph index 13)
    setGlyph(font, 13, 0x00,0x00,0x00,0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00);
    // . (46 - glyph index 14)
    setGlyph(font, 14, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00,0x00);
    // / (47 - glyph index 15)
    setGlyph(font, 15, 0x00,0x00,0x02,0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00,0x00,0x00,0x00,0x00,0x00);

    // : (58 - glyph index 26)
    setGlyph(font, 26, 0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00,0x00,0x00);
    // ; (59 - glyph index 27)
    setGlyph(font, 27, 0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30,0x00,0x00,0x00,0x00,0x00);
    // < (60 - glyph index 28)
    setGlyph(font, 28, 0x00,0x00,0x06,0x0C,0x18,0x30,0x60,0x30,0x18,0x0C,0x06,0x00,0x00,0x00,0x00,0x00);
    // = (61 - glyph index 29)
    setGlyph(font, 29, 0x00,0x00,0x00,0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00);
    // > (62 - glyph index 30)
    setGlyph(font, 30, 0x00,0x00,0x60,0x30,0x18,0x0C,0x06,0x0C,0x18,0x30,0x60,0x00,0x00,0x00,0x00,0x00);

    // [ (91 - glyph index 59)
    setGlyph(font, 59, 0x00,0x00,0x3C,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x3C,0x00,0x00,0x00,0x00,0x00);
    // \ (92 - glyph index 60)
    setGlyph(font, 60, 0x00,0x00,0x80,0xC0,0x60,0x30,0x18,0x0C,0x06,0x02,0x00,0x00,0x00,0x00,0x00,0x00);
    // ] (93 - glyph index 61)
    setGlyph(font, 61, 0x00,0x00,0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00,0x00,0x00,0x00,0x00);
    // _ (95 - glyph index 63)
    setGlyph(font, 63, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x7F,0x00,0x00,0x00,0x00);
    // { (123 - glyph index 91)
    setGlyph(font, 91, 0x00,0x00,0x0E,0x18,0x18,0x18,0x70,0x18,0x18,0x18,0x0E,0x00,0x00,0x00,0x00,0x00);
    // | (124 - glyph index 92)
    setGlyph(font, 92, 0x00,0x00,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00,0x00);
    // } (125 - glyph index 93)
    setGlyph(font, 93, 0x00,0x00,0x70,0x18,0x18,0x18,0x0E,0x18,0x18,0x18,0x70,0x00,0x00,0x00,0x00,0x00);
    // ~ (126 - glyph index 94)
    setGlyph(font, 94, 0x00,0x00,0x00,0x00,0x00,0x32,0x7F,0x4C,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00);

    // Solid block (glyph index 95) — used for cursor
    setGlyph(font, 95, 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF);
}

void setGlyph(ubyte* font, int idx, ubyte r0, ubyte r1, ubyte r2, ubyte r3,
        ubyte r4, ubyte r5, ubyte r6, ubyte r7, ubyte r8, ubyte r9,
        ubyte r10, ubyte r11, ubyte r12, ubyte r13, ubyte r14, ubyte r15) {
    int b = idx * 16;
    font[b+0] = r0;  font[b+1] = r1;  font[b+2] = r2;  font[b+3] = r3;
    font[b+4] = r4;  font[b+5] = r5;  font[b+6] = r6;  font[b+7] = r7;
    font[b+8] = r8;  font[b+9] = r9;  font[b+10] = r10; font[b+11] = r11;
    font[b+12] = r12; font[b+13] = r13; font[b+14] = r14; font[b+15] = r15;
}

// ── Main ───────────────────────────────────────────────────────────

int main() {
    // Text buffer
    TextBuffer buf;
    initTextBuffer(&buf);

    // Seed with some content
    string hello = "Hello, editor!\nType here...\nLine 3\n";
    int hi = 0;
    while (hi < 34) {
        buf.data[hi] = cast(ubyte) hello[hi];
        hi = hi + 1;
    }
    buf.len = 34;
    recomputeLines(&buf);

    // Font data (1536 bytes = 96 glyphs * 16 bytes, last is solid block for cursor)
    ubyte[1536] fontData;
    initFontData(fontData.ptr);

    // App initialization
    NSApplication app = NSApplication.sharedApplication();
    app.setActivationPolicy(0);

    // Metal device
    long devicePtr = MTLCreateSystemDefaultDevice();
    if (devicePtr == 0) return 1;
    MTLDevice device = cast(MTLDevice) devicePtr;
    MTLCommandQueue cmdQueue = device.newCommandQueue();

    // Shader compilation
    NSString shaderSrc = NSString.stringWithUTF8String(shaderSource().toStringz());
    MTLLibrary library = device.newLibraryWithSource(shaderSrc, 0, 0);
    if (cast(long) library == 0) return 1;

    NSString vertName = NSString.stringWithUTF8String("vertex_main".toStringz());
    NSString fragName = NSString.stringWithUTF8String("fragment_main".toStringz());
    long vertexFunc = library.newFunctionWithName(vertName);
    long fragmentFunc = library.newFunctionWithName(fragName);

    // Pipeline
    MTLRenderPipelineDescriptor pipeDesc = MTLRenderPipelineDescriptor.alloc();
    pipeDesc = pipeDesc.init_();
    pipeDesc.setVertexFunction(vertexFunc);
    pipeDesc.setFragmentFunction(fragmentFunc);
    pipeDesc.colorAttachments().objectAtIndexedSubscript(0).setPixelFormat(80);
    long pipelineState = device.newRenderPipelineStateWithDescriptor(cast(long) pipeDesc, 0);
    if (pipelineState == 0) return 1;

    // Metal layer
    CAMetalLayer metalLayer = CAMetalLayer.layer();
    metalLayer.setDevice(devicePtr);
    metalLayer.setPixelFormat(80);
    metalLayer.setFramebufferOnly(1);

    // Window
    int winW = 1024;
    int winH = 768;
    NSRect frame;
    frame.x = 100.0;
    frame.y = 100.0;
    frame.width = cast(double) winW;
    frame.height = cast(double) winH;
    NSWindow window = NSWindow.alloc();
    window = window.initWithContentRect(frame, 15, 2, 0);
    NSString title = NSString.stringWithUTF8String("D Editor".toStringz());
    window.setTitle(title);

    // Attach metal layer + view
    CGSize drawSize;
    drawSize.width = cast(double) winW;
    drawSize.height = cast(double) winH;
    metalLayer.setDrawableSize(drawSize);

    frame.x = 0.0;
    frame.y = 0.0;
    EditorView editorView = EditorView.myAlloc().myInitWithFrame(frame);
    editorView.setWantsLayer(1);
    editorView.setLayer(cast(long) metalLayer);
    editorView.setAutoresizingMask(18);

    long cv = window.contentView();
    NSView contentView = cast(NSView) cv;
    contentView.addSubview(cast(long) editorView);

    // Window delegate
    EditorWindowDelegate del = EditorWindowDelegate.myAlloc().myInit();
    window.setDelegate(cast(long) del);

    // Upload font data to Metal buffer (96 glyphs * 16 bytes)
    long fontBuf = device.newBufferWithBytes(
        cast(ubyte*) fontData.ptr, cast(long) 1536, 0);

    // Show window
    window.makeKeyAndOrderFront(0);
    app.activateIgnoringOtherApps(1);

    // Character cell size in NDC
    int cols = winW / 8;   // 128 columns
    int rows = winH / 16;  // 48 rows
    float charW = 2.0 / cast(float) cols;
    float charH = 2.0 / cast(float) rows;

    // Vertex batch (500 chars per batch)
    float[27000] vertexBatch;

    // Event loop
    NSString runLoopMode = NSString.stringWithUTF8String("kCFRunLoopDefaultMode".toStringz());

    while (g_windowClosed == 0) {
        long pool = objc_autoreleasePoolPush();

        // Drain events
        while (1 != 0) {
            NSDate timeout = NSDate.dateWithTimeIntervalSinceNow(0.016);
            NSEvent event = app.nextEventMatchingMask(cast(long) -1, timeout, runLoopMode, 1);
            if (cast(long) event == 0) break;
            app.sendEvent(event);
            app.updateWindows();
            if (g_windowClosed != 0) break;
        }

        objc_autoreleasePoolPop(pool);
        if (g_windowClosed != 0) break;

        // Process key input
        if (g_hasKey != 0) {
            g_hasKey = 0;
            int code = g_keyCode;
            int ch = g_keyChar;

            if (code == 36) {
                // Return
                insertNewline(&buf);
            } else if (code == 51) {
                // Backspace
                deleteCharBeforeCursor(&buf);
            } else if (code == 123) {
                moveCursorLeft(&buf);
            } else if (code == 124) {
                moveCursorRight(&buf);
            } else if (code == 125) {
                moveCursorDown(&buf);
            } else if (code == 126) {
                moveCursorUp(&buf);
            } else if (code == 48) {
                // Tab — insert spaces
                insertCharAtCursor(&buf, 32);
                insertCharAtCursor(&buf, 32);
                insertCharAtCursor(&buf, 32);
                insertCharAtCursor(&buf, 32);
            } else {
                if (ch >= 32 && ch < 127) {
                    insertCharAtCursor(&buf, ch);
                }
            }
        }

        // Auto-scroll to keep cursor visible
        int visRows = rows - 1;
        if (buf.cursorLine < buf.scrollLine) {
            buf.scrollLine = buf.cursorLine;
            buf.needsRedraw = 1;
        }
        if (buf.cursorLine >= buf.scrollLine + visRows) {
            buf.scrollLine = buf.cursorLine - visRows + 1;
            buf.needsRedraw = 1;
        }

        // Render frame
        CAMetalDrawable drawable = metalLayer.nextDrawable();
        if (cast(long) drawable == 0) {
            // skip frame
        } else {
            MTLRenderPassDescriptor rpd = MTLRenderPassDescriptor.renderPassDescriptor();
            MTLRenderPassColorAttachmentDescriptor att =
                rpd.colorAttachments().objectAtIndexedSubscript(0);
            att.setTexture(drawable.texture());
            att.setLoadAction(2);
            MTLClearColor clearColor;
            clearColor.red = 0.12;
            clearColor.green = 0.12;
            clearColor.blue = 0.15;
            clearColor.alpha = 1.0;
            att.setClearColor(clearColor);
            att.setStoreAction(1);

            MTLCommandBuffer cmdBuf = cmdQueue.commandBuffer();
            MTLRenderCommandEncoder enc = cmdBuf.renderCommandEncoderWithDescriptor(rpd);
            enc.setRenderPipelineState(pipelineState);
            enc.setFragmentBuffer(fontBuf, 0, 0);

            // Render visible text lines
            int vertCount = 0;
            int screenRow = 0;
            int line = buf.scrollLine;
            while (line < buf.lineCount && screenRow < visRows) {
                int lineLen = buf.lineLen[line];
                int lineOff = buf.lineStart[line];
                int col = 0;
                while (col < lineLen && col < cols) {
                    int ch = cast(int) buf.data[lineOff + col];
                    float sx = -1.0 + cast(float) col * charW;
                    float sy = 1.0 - cast(float) screenRow * charH;

                    // Default text color: light gray (0xDBDBDB)
                    addCharQuad(vertexBatch.ptr, &vertCount, sx, sy,
                        charW, charH, ch, 0xDBDBDB);

                    // Flush batch if full
                    if (vertCount >= 2994) {  // 499 chars * 6 verts
                        long vbuf = device.newBufferWithBytes(
                            cast(ubyte*) vertexBatch.ptr,
                            cast(long)(vertCount * 9 * 4), 0);
                        enc.setVertexBuffer(vbuf, 0, 0);
                        enc.drawPrimitives(3, 0, cast(long) vertCount);
                        vertCount = 0;
                    }

                    col = col + 1;
                }
                screenRow = screenRow + 1;
                line = line + 1;
            }

            // Render cursor using solid block glyph (index 95 → charCode 127)
            int cursorScreenRow = buf.cursorLine - buf.scrollLine;
            if (cursorScreenRow >= 0 && cursorScreenRow < visRows) {
                float cx = -1.0 + cast(float) buf.cursorCol * charW;
                float cy = 1.0 - cast(float) cursorScreenRow * charH;
                // Use glyph 95 (solid block), charCode 127 maps to 127-32=95
                addCharQuad(vertexBatch.ptr, &vertCount, cx, cy,
                    charW, charH, 127, 0xCCCC33);
            }

            // Flush remaining vertices
            if (vertCount > 0) {
                long vbuf = device.newBufferWithBytes(
                    cast(ubyte*) vertexBatch.ptr,
                    cast(long)(vertCount * 9 * 4), 0);
                enc.setVertexBuffer(vbuf, 0, 0);
                enc.drawPrimitives(3, 0, cast(long) vertCount);
            }

            enc.endEncoding();
            cmdBuf.presentDrawable(drawable);
            cmdBuf.commit();
            cmdBuf.waitUntilCompleted();
        }
    }

    return 0;
}
