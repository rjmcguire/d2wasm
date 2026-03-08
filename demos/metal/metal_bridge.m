/**
 * Metal C Bridge — slim residual requiring Objective-C runtime features
 *
 * Handles: event loop (@autoreleasepool), vertex buffer accumulation
 * (native memory needed for Metal), string constants, and window close notification.
 *
 * D handles: Metal device, command queue, shader compilation, pipeline,
 * buffer creation, window creation, render pass, game loop,
 * MetalView (NSView subclass), and BridgeWindowDelegate.
 */
#import <Metal/Metal.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>

// ── Window close state ──────────────────────────────────────────────

static BOOL g_windowClosed = NO;

/// Called from D's BridgeWindowDelegate.windowWillClose
void metal_notify_close(void) {
    g_windowClosed = YES;
}

/// Poll events; returns 0 when window closed
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

// ── Vertex accumulator ──────────────────────────────────────────────

typedef struct {
    float x, y;
    float r, g, b, a;
} Vertex;

#define MAX_VERTICES 8192
static Vertex g_vertices[MAX_VERTICES];
static int g_vertexCount = 0;

void metal_add_vertex(double x, double y, double r, double g, double b, double a) {
    if (g_vertexCount < MAX_VERTICES) {
        g_vertices[g_vertexCount++] = (Vertex){(float)x, (float)y, (float)r, (float)g, (float)b, (float)a};
    }
}

/// Create Metal buffers from accumulated vertices; stores results in globals
static long g_posBuf = 0;
static long g_colBuf = 0;
static int  g_bufVertexCount = 0;

void metal_create_buffers(long device) {
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
    g_posBuf = (long)[(id<MTLDevice>)device newBufferWithBytes:positions
                                                        length:n * 2 * sizeof(float)
                                                       options:MTLResourceStorageModeShared];
    g_colBuf = (long)[(id<MTLDevice>)device newBufferWithBytes:colors
                                                        length:n * 4 * sizeof(float)
                                                       options:MTLResourceStorageModeShared];
    g_bufVertexCount = n;
}

long metal_get_pos_buf(void)     { return g_posBuf; }
long metal_get_col_buf(void)     { return g_colBuf; }
int  metal_get_vertex_count(void) { return g_bufVertexCount; }

// ── String Constants (native pointers for NSString creation) ────────

static const char *g_shaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VertexOut { float4 position [[position]]; float4 color; };\n"
    "vertex VertexOut vertex_main(uint vid [[vertex_id]],\n"
    "    const device float2 *pos [[buffer(0)]],\n"
    "    const device float4 *col [[buffer(1)]]) {\n"
    "    VertexOut out; out.position = float4(pos[vid], 0.0, 1.0);\n"
    "    out.color = col[vid]; return out; }\n"
    "fragment float4 fragment_main(VertexOut in [[stage_in]]) {\n"
    "    return in.color; }\n";

long metal_get_shader_source(void)  { return (long)g_shaderSource; }
long metal_get_cstr_vertex_main(void)  { return (long)"vertex_main"; }
long metal_get_cstr_fragment_main(void) { return (long)"fragment_main"; }
long metal_get_cstr_title(void)     { return (long)"D \xe2\x86\x92 Metal"; }
