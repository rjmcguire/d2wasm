/**
 * Metal C Bridge — thin C-linkage wrappers around Metal/AppKit
 *
 * D (WASM) calls these via FFI trampolines to set up a window,
 * accumulate vertices, and render a single frame with Metal.
 */
#import <Metal/Metal.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>

// ── Vertex accumulator ──────────────────────────────────────────────

typedef struct {
    float x, y;
    float r, g, b, a;
} Vertex;

#define MAX_VERTICES 8192
static Vertex g_vertices[MAX_VERTICES];
static int g_vertexCount = 0;

// ── Metal state ─────────────────────────────────────────────────────

static id<MTLDevice>              g_device;
static id<MTLCommandQueue>        g_commandQueue;
static id<MTLRenderPipelineState> g_pipelineState;
static NSWindow                  *g_window;
static CAMetalLayer              *g_metalLayer;

// ── Click state ────────────────────────────────────────────────────

static double g_clickX = 0.0;
static double g_clickY = 0.0;
static int    g_hasClick = 0;
static BOOL   g_windowClosed = NO;

// ── Mutable clear color ────────────────────────────────────────────

static double g_clearR = 0.05;
static double g_clearG = 0.05;
static double g_clearB = 0.10;

// ── Pre-built Metal buffers (for game loop rendering) ──────────────

static id<MTLBuffer> g_posBuf = nil;
static id<MTLBuffer> g_colBuf = nil;
static int           g_bufVertexCount = 0;

// ── Window delegate ─────────────────────────────────────────────────

@interface BridgeWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation BridgeWindowDelegate
- (void)windowWillClose:(NSNotification *)notification {
    g_windowClosed = YES;
}
@end

static BridgeWindowDelegate *g_windowDelegate;

// ── Custom NSView for mouse event handling ─────────────────────────

@interface MetalView : NSView
@end

@implementation MetalView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)mouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    NSSize size = self.bounds.size;

    // Convert to NDC: (-1,-1) bottom-left to (1,1) top-right
    g_clickX = (loc.x / size.width)  * 2.0 - 1.0;
    g_clickY = (loc.y / size.height) * 2.0 - 1.0;
    g_hasClick = 1;
}

@end

static MetalView *g_metalView = nil;

// ── Embedded MSL shaders ────────────────────────────────────────────

static NSString *g_shaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(uint vid [[vertex_id]],
                             const device float2 *pos [[buffer(0)]],
                             const device float4 *col [[buffer(1)]]) {
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.color = col[vid];
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
)";

// ── C API ───────────────────────────────────────────────────────────

int metal_init(int w, int h) {
    // Ensure NSApplication exists
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // Metal device
    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) return 0;

    g_commandQueue = [g_device newCommandQueue];

    // Compile shaders
    NSError *error = nil;
    id<MTLLibrary> library = [g_device newLibraryWithSource:g_shaderSource
                                                    options:nil
                                                      error:&error];
    if (!library) {
        NSLog(@"Shader compile error: %@", error);
        return 0;
    }

    id<MTLFunction> vertexFunc   = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragment_main"];

    // Pipeline
    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.vertexFunction   = vertexFunc;
    pipeDesc.fragmentFunction = fragmentFunc;
    pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    g_pipelineState = [g_device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
    if (!g_pipelineState) {
        NSLog(@"Pipeline error: %@", error);
        return 0;
    }

    // Window
    NSRect frame = NSMakeRect(100, 100, w, h);
    g_window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [g_window setTitle:@"D \u2192 Metal"];

    g_windowDelegate = [[BridgeWindowDelegate alloc] init];
    [g_window setDelegate:g_windowDelegate];

    // Metal layer
    g_metalLayer = [CAMetalLayer layer];
    g_metalLayer.device = g_device;
    g_metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    g_metalLayer.framebufferOnly = YES;
    g_metalLayer.drawableSize = CGSizeMake(w, h);
    g_metalView = [[MetalView alloc] initWithFrame:g_window.contentView.bounds];
    [g_metalView setWantsLayer:YES];
    [g_metalView setLayer:g_metalLayer];
    g_metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [g_window.contentView addSubview:g_metalView];

    g_vertexCount = 0;
    return 1;
}

long metal_device_name_ptr(void) {
    if (!g_device) return 0;
    return (long)[[g_device name] UTF8String];
}

void metal_add_vertex(double x, double y, double r, double g, double b, double a) {
    if (g_vertexCount < MAX_VERTICES) {
        g_vertices[g_vertexCount++] = (Vertex){(float)x, (float)y, (float)r, (float)g, (float)b, (float)a};
    }
}

// ── Game-loop API ──────────────────────────────────────────────────

void metal_create_buffers(void) {
    if (g_vertexCount == 0) return;

    int n = g_vertexCount;
    float positions[n * 2];
    float colors[n * 4];
    for (int i = 0; i < n; i++) {
        positions[i * 2 + 0] = g_vertices[i].x;
        positions[i * 2 + 1] = g_vertices[i].y;
        colors[i * 4 + 0] = g_vertices[i].r;
        colors[i * 4 + 1] = g_vertices[i].g;
        colors[i * 4 + 2] = g_vertices[i].b;
        colors[i * 4 + 3] = g_vertices[i].a;
    }

    g_posBuf = [g_device newBufferWithBytes:positions
                                     length:n * 2 * sizeof(float)
                                    options:MTLResourceStorageModeShared];
    g_colBuf = [g_device newBufferWithBytes:colors
                                     length:n * 4 * sizeof(float)
                                    options:MTLResourceStorageModeShared];
    g_bufVertexCount = n;

    // Show window
    [g_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

int metal_process_events(void) {
    if (g_windowClosed) return 0;

    @autoreleasepool {
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                           untilDate:[NSDate dateWithTimeIntervalSinceNow:0.016]
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES])) {
            [NSApp sendEvent:event];
            [NSApp updateWindows];
            if (g_windowClosed) return 0;
        }
    }
    return 1;
}

int metal_has_click(void) {
    int result = g_hasClick;
    g_hasClick = 0;
    return result;
}

double metal_get_click_x(void) {
    return g_clickX;
}

double metal_get_click_y(void) {
    return g_clickY;
}

void metal_set_clear_color(double r, double g, double b) {
    g_clearR = r;
    g_clearG = g;
    g_clearB = b;
}

void metal_render_frame(void) {
    if (g_bufVertexCount == 0 || !g_posBuf || !g_colBuf) return;

    id<CAMetalDrawable> drawable = [g_metalLayer nextDrawable];
    if (!drawable) return;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture    = drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(g_clearR, g_clearG, g_clearB, 1.0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cmdBuf = [g_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];

    [enc setRenderPipelineState:g_pipelineState];
    [enc setVertexBuffer:g_posBuf offset:0 atIndex:0];
    [enc setVertexBuffer:g_colBuf offset:0 atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:g_bufVertexCount];
    [enc endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];
}

// ── Legacy one-shot API ────────────────────────────────────────────

void metal_render_and_run(void) {
    if (g_vertexCount == 0) return;

    // Build separate position and color buffers
    int n = g_vertexCount;
    float positions[n * 2];
    float colors[n * 4];
    for (int i = 0; i < n; i++) {
        positions[i * 2 + 0] = g_vertices[i].x;
        positions[i * 2 + 1] = g_vertices[i].y;
        colors[i * 4 + 0] = g_vertices[i].r;
        colors[i * 4 + 1] = g_vertices[i].g;
        colors[i * 4 + 2] = g_vertices[i].b;
        colors[i * 4 + 3] = g_vertices[i].a;
    }

    id<MTLBuffer> posBuf = [g_device newBufferWithBytes:positions
                                                 length:n * 2 * sizeof(float)
                                                options:MTLResourceStorageModeShared];
    id<MTLBuffer> colBuf = [g_device newBufferWithBytes:colors
                                                 length:n * 4 * sizeof(float)
                                                options:MTLResourceStorageModeShared];

    // Render
    id<CAMetalDrawable> drawable = [g_metalLayer nextDrawable];
    if (!drawable) return;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture    = drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.1, 1.0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cmdBuf = [g_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];

    [enc setRenderPipelineState:g_pipelineState];
    [enc setVertexBuffer:posBuf offset:0 atIndex:0];
    [enc setVertexBuffer:colBuf offset:0 atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:n];
    [enc endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    // Show window and run event loop
    [g_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
}
