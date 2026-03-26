pragma(lib, "/System/Library/Frameworks/Metal.framework/Metal");
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");
pragma(lib, "/System/Library/Frameworks/Cocoa.framework/Cocoa");
pragma(lib, "/System/Library/Frameworks/QuartzCore.framework/QuartzCore");

struct CGSize { double width; double height; }

extern(Objective-C)
interface CAMetalLayer {
    static CAMetalLayer layer() @selector("layer");
    void setDevice(long device) @selector("setDevice:");
    void setPixelFormat(long fmt) @selector("setPixelFormat:");
    void setDrawableSize(CGSize size) @selector("setDrawableSize:");
}

extern(C) long MTLCreateSystemDefaultDevice();
extern(C) int sleep(int seconds);

int main() {
    long devicePtr = MTLCreateSystemDefaultDevice();
    if (devicePtr == 0) return 1;

    CAMetalLayer metalLayer = CAMetalLayer.layer();
    metalLayer.setDevice(devicePtr);
    metalLayer.setPixelFormat(80);

    CGSize drawSize;
    drawSize.width = 1024.0;
    drawSize.height = 768.0;
    metalLayer.setDrawableSize(drawSize);

    sleep(1);
    return 42;
}
