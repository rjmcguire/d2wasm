// Metal Render Demo — D drives Metal via extern(Objective-C) interfaces
//
// D handles: device init, command queue, shader compilation, pipeline,
// buffer creation, window setup, render pass, game loop, view and delegate.
// Bridge handles: event loop (@autoreleasepool), vertex buffers, string constants.

pragma(lib, "/System/Library/Frameworks/Metal.framework/Metal");
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");
pragma(lib, "/System/Library/Frameworks/Cocoa.framework/Cocoa");
pragma(lib, "/System/Library/Frameworks/QuartzCore.framework/QuartzCore");
pragma(lib, "./libmetal_bridge.dylib");

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
    MTLLibrary newLibraryWithSource(NSString source, long options, long errPtr) @selector("newLibraryWithSource:options:error:");
    NSString name() @selector("name");
    long newRenderPipelineStateWithDescriptor(long desc, long error) @selector("newRenderPipelineStateWithDescriptor:error:");
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
    void drawPrimitives(long type, long start, long count)
        @selector("drawPrimitives:vertexStart:vertexCount:");
    void endEncoding() @selector("endEncoding");
}

// ── C/Bridge Functions ─────────────────────────────────────────────

extern(C) long MTLCreateSystemDefaultDevice();

// Bridge: event loop (needs @autoreleasepool), notify
extern(C) int metal_process_events();
extern(C) void metal_notify_close();

// Bridge: vertex accumulation (native memory needed for Metal)
extern(C) void metal_add_vertex(double x, double y, double r, double g, double b, double a);
extern(C) void metal_create_buffers(long device);
extern(C) long metal_get_pos_buf();
extern(C) long metal_get_col_buf();
extern(C) int metal_get_vertex_count();

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

// ── Click State (D globals) ───────────────────────────────────────

int g_hasClick = 0;
double g_clickX = 0.0;
double g_clickY = 0.0;

// ── Clear Color State ─────────────────────────────────────────────

double g_clearR = 0.05;
double g_clearG = 0.05;
double g_clearB = 0.10;

// ── ObjC Classes (D-defined, registered at runtime) ───────────────

extern(Objective-C)
class BridgeWindowDelegate : NSObject {
    static BridgeWindowDelegate myAlloc() @selector("alloc");
    BridgeWindowDelegate myInit() @selector("init");

    void windowWillClose(long notification) @selector("windowWillClose:") {
        metal_notify_close();
    }
}

extern(Objective-C)
class MetalView : NSView {
    static MetalView myAlloc() @selector("alloc");
    MetalView myInitWithFrame(NSRect frame_) @selector("initWithFrame:");

    int acceptsFirstResponder() @selector("acceptsFirstResponder") {
        return 1;
    }

    int acceptsFirstMouse(long event) @selector("acceptsFirstMouse:") {
        return 1;
    }

    void mouseDown(long rawEvent) @selector("mouseDown:") {
        NSEvent event = cast(NSEvent) rawEvent;
        NSPoint loc = event.locationInWindow();
        g_hasClick = 1;
        g_clickX = (loc.x / 800.0) * 2.0 - 1.0;
        g_clickY = (loc.y / 600.0) * 2.0 - 1.0;
    }
}

// ── Click Handler ──────────────────────────────────────────────────

void on_click(double x, double y) {
    double r = x * 0.5 + 0.5;
    double g = y * 0.5 + 0.5;
    double b = 1.0 - r;
    g_clearR = r;
    g_clearG = g;
    g_clearB = b;
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

    // Pipeline (D-side ObjC — expression receivers enable chained calls)
    MTLRenderPipelineDescriptor pipeDesc = MTLRenderPipelineDescriptor.alloc();
    pipeDesc = pipeDesc.init_();
    pipeDesc.setVertexFunction(vertexFunc);
    pipeDesc.setFragmentFunction(fragmentFunc);
    pipeDesc.colorAttachments().objectAtIndexedSubscript(0).setPixelFormat(80);
    long pipelineState = device.newRenderPipelineStateWithDescriptor(cast(long)pipeDesc, 0);
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

    // Attach metal layer + view (D-side ObjC classes)
    CGSize drawSize;
    drawSize.width = 800.0;
    drawSize.height = 600.0;
    metalLayer.setDrawableSize(drawSize);

    frame.x = 0.0;
    frame.y = 0.0;
    MetalView metalView = MetalView.myAlloc().myInitWithFrame(frame);
    metalView.setWantsLayer(1);
    metalView.setLayer(cast(long)metalLayer);
    metalView.setAutoresizingMask(18);

    long cv = window.contentView();
    NSView contentView = cast(NSView) cv;
    contentView.addSubview(cast(long)metalView);

    // Set window delegate (D-side ObjC class)
    BridgeWindowDelegate del = BridgeWindowDelegate.myAlloc().myInit();
    window.setDelegate(cast(long)del);

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
        if (g_hasClick != 0) {
            g_hasClick = 0;
            on_click(g_clickX, g_clickY);
        }

        // Render frame (D-side ObjC — chained calls via expression receivers)
        CAMetalDrawable drawable = metalLayer.nextDrawable();
        if (cast(long)drawable == 0) {
            i = i;  // skip frame if no drawable
        } else {
            MTLRenderPassDescriptor rpd = MTLRenderPassDescriptor.renderPassDescriptor();
            MTLRenderPassColorAttachmentDescriptor att =
                rpd.colorAttachments().objectAtIndexedSubscript(0);
            att.setTexture(drawable.texture());
            att.setLoadAction(2);   // MTLLoadActionClear
            MTLClearColor clearColor;
            clearColor.red = g_clearR;
            clearColor.green = g_clearG;
            clearColor.blue = g_clearB;
            clearColor.alpha = 1.0;
            att.setClearColor(clearColor);
            att.setStoreAction(1);  // MTLStoreActionStore

            MTLCommandBuffer cmdBuf = cmdQueue.commandBuffer();
            MTLRenderCommandEncoder enc = cmdBuf.renderCommandEncoderWithDescriptor(rpd);
            enc.setRenderPipelineState(pipelineState);
            enc.setVertexBuffer(posBuf, 0, 0);
            enc.setVertexBuffer(colBuf, 0, 1);
            enc.drawPrimitives(3, 0, cast(long)vertexCount);  // MTLPrimitiveTypeTriangle
            enc.endEncoding();
            cmdBuf.presentDrawable(drawable);
            cmdBuf.commit();
            cmdBuf.waitUntilCompleted();
        }
    }

    return 0;
}
