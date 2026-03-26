// ObjC Metal framework bindings
// Import with: import objc.metal;

module objc.metal;

import objc.foundation;
import objc.appkit;

pragma(lib, "/System/Library/Frameworks/Metal.framework/Metal");
pragma(lib, "/System/Library/Frameworks/QuartzCore.framework/QuartzCore");

struct CGSize { double width; double height; }
struct MTLClearColor { double red; double green; double blue; double alpha; }

extern(Objective-C)
interface CAMetalLayer {
    static CAMetalLayer layer();
    void setDevice(long device);
    void setPixelFormat(long fmt);
    void setFramebufferOnly(int flag);
    void setDrawableSize(CGSize size);
    CGSize drawableSize();
    CAMetalDrawable nextDrawable();
}

extern(Objective-C)
interface CAMetalDrawable {
    long texture();
}

extern(Objective-C)
interface MTLDevice {
    MTLCommandQueue newCommandQueue();
    MTLLibrary newLibraryWithSource(NSString source, long options, long errPtr)
        @selector("newLibraryWithSource:options:error:");
    NSString name();
    long newRenderPipelineStateWithDescriptor(long desc, long error)
        @selector("newRenderPipelineStateWithDescriptor:error:");
    long newBufferWithBytes(ubyte* bytes, long length, long options)
        @selector("newBufferWithBytes:length:options:");
}

extern(Objective-C)
interface MTLLibrary {
    long newFunctionWithName(NSString name);
}

extern(Objective-C)
interface MTLCommandQueue {
    MTLCommandBuffer commandBuffer();
}

extern(Objective-C)
interface MTLCommandBuffer {
    MTLRenderCommandEncoder renderCommandEncoderWithDescriptor(MTLRenderPassDescriptor desc);
    void presentDrawable(CAMetalDrawable drawable);
    void commit();
    void waitUntilCompleted();
}

extern(Objective-C)
interface MTLRenderCommandEncoder {
    void setRenderPipelineState(long state);
    void setVertexBuffer(long buf, long offset, long atIndex)
        @selector("setVertexBuffer:offset:atIndex:");
    void drawPrimitives(long type, long start, long count)
        @selector("drawPrimitives:vertexStart:vertexCount:");
    void endEncoding();
}

extern(Objective-C)
interface MTLRenderPassDescriptor {
    static MTLRenderPassDescriptor renderPassDescriptor();
    MTLRenderPassColorAttachmentDescriptorArray colorAttachments();
}

extern(Objective-C)
interface MTLRenderPassColorAttachmentDescriptor {
    void setTexture(long texture);
    void setLoadAction(long action);
    void setClearColor(MTLClearColor color);
    void setStoreAction(long action);
    void setPixelFormat(long fmt);
}

extern(Objective-C)
interface MTLRenderPassColorAttachmentDescriptorArray {
    MTLRenderPassColorAttachmentDescriptor objectAtIndexedSubscript(long idx);
}

extern(Objective-C)
interface MTLRenderPipelineDescriptor {
    static MTLRenderPipelineDescriptor alloc();
    MTLRenderPipelineDescriptor init_() @selector("init");
    void setVertexFunction(long func);
    void setFragmentFunction(long func);
    MTLRenderPassColorAttachmentDescriptorArray colorAttachments();
}

extern(C) long MTLCreateSystemDefaultDevice();
