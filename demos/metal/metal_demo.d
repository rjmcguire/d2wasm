// Metal Render Demo — D drives Metal via extern(Objective-C) interfaces
//
// D handles: device init, command queue, shader compilation, pipeline,
// buffer creation, window setup, and game loop orchestration.
// Bridge handles: NSView subclass, window delegate, event loop, render pass.

// ── Struct Types ───────────────────────────────────────────────────

struct NSRect { double x; double y; double width; double height; }
struct CGSize { double width; double height; }

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
}

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(long cstr) @selector("stringWithUTF8String:");
}

extern(Objective-C)
interface NSWindow {
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect rect, long styleMask, long backing, int defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void makeKeyAndOrderFront(long sender) @selector("makeKeyAndOrderFront:");
}

extern(Objective-C)
interface CAMetalLayer {
    static CAMetalLayer layer() @selector("layer");
    void setDevice(long device) @selector("setDevice:");
    void setPixelFormat(long fmt) @selector("setPixelFormat:");
    void setFramebufferOnly(int flag) @selector("setFramebufferOnly:");
    void setDrawableSize(CGSize size) @selector("setDrawableSize:");
}

extern(Objective-C)
interface MTLDevice {
    MTLCommandQueue newCommandQueue() @selector("newCommandQueue");
    MTLLibrary newLibraryWithSource(NSString source, long options, long errPtr) @selector("newLibraryWithSource:options:error:");
    NSString name() @selector("name");
}

extern(Objective-C)
interface MTLLibrary {
    long newFunctionWithName(NSString name) @selector("newFunctionWithName:");
}

extern(Objective-C)
interface MTLCommandQueue {
}

// ── C/Bridge Functions ─────────────────────────────────────────────

extern(C) long MTLCreateSystemDefaultDevice();

// Bridge: things that need ObjC class definitions
extern(C) void metal_setup_view(long window, long metalLayer);
extern(C) void metal_set_delegate(long window);
extern(C) int metal_process_events();
extern(C) int metal_has_click();
extern(C) double metal_get_click_x();
extern(C) double metal_get_click_y();

// Bridge: vertex accumulation (native memory needed for Metal)
extern(C) void metal_add_vertex(double x, double y, double r, double g, double b, double a);
extern(C) void metal_create_buffers(long device);
extern(C) long metal_get_pos_buf();
extern(C) long metal_get_col_buf();
extern(C) int metal_get_vertex_count();

// Bridge: render pass (needs indexed ObjC properties)
extern(C) long metal_create_pipeline(long device, long vertexFunc, long fragmentFunc);
extern(C) void metal_set_clear_color(double r, double g, double b);
extern(C) void metal_render_frame(long cmdQueue, long metalLayer, long pipelineState,
                                  long posBuf, long colBuf, int vertexCount);

// Bridge: native C string pointers (WASM can't pass linear memory addrs to ObjC)
extern(C) long metal_get_shader_source();
extern(C) long metal_get_cstr_vertex_main();
extern(C) long metal_get_cstr_fragment_main();
extern(C) long metal_get_cstr_title();

// ── Math Helpers ───────────────────────────────────────────────────

double sin_approx(double x) {
    double pi = 3.14159265;
    double two_pi = 6.28318530;
    while (x > pi) x = x - two_pi;
    while (x < 0.0 - pi) x = x + two_pi;
    double x2 = x * x;
    double x3 = x2 * x;
    double x5 = x3 * x2;
    double x7 = x5 * x2;
    return x - x3 / 6.0 + x5 / 120.0 - x7 / 5040.0;
}

double cos_approx(double x) {
    return sin_approx(x + 1.5707963);
}

// ── Click Handler ──────────────────────────────────────────────────

void on_click(double x, double y) {
    double r = x * 0.5 + 0.5;
    double g = y * 0.5 + 0.5;
    double b = 1.0 - r;
    metal_set_clear_color(r, g, b);
}

// ── Main ───────────────────────────────────────────────────────────

int main() {
    // App initialization
    NSApplication app = NSApplication.sharedApplication();
    app.setActivationPolicy(0);

    // Metal device & command queue (D-side ObjC calls)
    long devicePtr = MTLCreateSystemDefaultDevice();
    if (devicePtr == 0) return 1;
    MTLDevice device = cast(MTLDevice)devicePtr;
    MTLCommandQueue cmdQueue = device.newCommandQueue();

    // Shader compilation (D-side ObjC calls)
    NSString shaderSrc = NSString.stringWithUTF8String(metal_get_shader_source());
    MTLLibrary library = device.newLibraryWithSource(shaderSrc, 0, 0);
    if (cast(long)library == 0) return 1;

    NSString vertName = NSString.stringWithUTF8String(metal_get_cstr_vertex_main());
    NSString fragName = NSString.stringWithUTF8String(metal_get_cstr_fragment_main());
    long vertexFunc = library.newFunctionWithName(vertName);
    long fragmentFunc = library.newFunctionWithName(fragName);

    // Pipeline (bridge: needs indexed ObjC property)
    long pipelineState = metal_create_pipeline(devicePtr, vertexFunc, fragmentFunc);
    if (pipelineState == 0) return 1;

    // Metal layer (D-side ObjC calls)
    CAMetalLayer metalLayer = CAMetalLayer.layer();
    metalLayer.setDevice(devicePtr);
    metalLayer.setPixelFormat(80);  // MTLPixelFormatBGRA8Unorm
    metalLayer.setFramebufferOnly(1);

    // Window (pure D — struct-by-value via HFA flattening)
    NSRect frame;
    frame.x = 100.0;
    frame.y = 100.0;
    frame.width = 800.0;
    frame.height = 600.0;
    NSWindow window = NSWindow.alloc();
    window = window.initWithContentRect(frame, 15, 2, 0);
    NSString title = NSString.stringWithUTF8String(metal_get_cstr_title());
    window.setTitle(title);

    // Attach metal layer + delegate (bridge: needs NSView subclass)
    long windowPtr = cast(long)window;
    long metalLayerPtr = cast(long)metalLayer;
    CGSize drawSize;
    drawSize.width = 800.0;
    drawSize.height = 600.0;
    metalLayer.setDrawableSize(drawSize);
    metal_setup_view(windowPtr, metalLayerPtr);
    metal_set_delegate(windowPtr);

    // Generate color wheel geometry
    int segments = 64;
    double two_pi = 6.28318530;
    int i = 0;
    while (i < segments) {
        double fi = cast(double) i;
        double fi1 = cast(double)(i + 1);
        double a1 = fi * two_pi / cast(double) segments;
        double a2 = fi1 * two_pi / cast(double) segments;

        double r = sin_approx(a1) * 0.5 + 0.5;
        double g = sin_approx(a1 + 2.094) * 0.5 + 0.5;
        double b = sin_approx(a1 + 4.189) * 0.5 + 0.5;

        metal_add_vertex(0.0, 0.0, 0.1, 0.1, 0.1, 1.0);
        metal_add_vertex(cos_approx(a1) * 0.8, sin_approx(a1) * 0.8, r, g, b, 1.0);
        metal_add_vertex(cos_approx(a2) * 0.8, sin_approx(a2) * 0.8, r, g, b, 1.0);

        i = i + 1;
    }

    // Create Metal buffers from accumulated vertices
    metal_create_buffers(devicePtr);
    long posBuf = metal_get_pos_buf();
    long colBuf = metal_get_col_buf();
    int vertexCount = metal_get_vertex_count();

    // Show window
    window.makeKeyAndOrderFront(0);
    app.activateIgnoringOtherApps(1);

    // Game loop
    while (metal_process_events() != 0) {
        if (metal_has_click() != 0) {
            on_click(metal_get_click_x(), metal_get_click_y());
        }
        metal_render_frame(cast(long)cmdQueue, cast(long)metalLayer,
                          pipelineState, posBuf, colBuf, vertexCount);
    }

    return 0;
}
