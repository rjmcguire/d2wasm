// Bug: ObjC method parameter types (UserType) were not resolved against the
// symbol table before HFA detection.  UserType("CGSize").asStruct() returned
// null because declaration was never set, so the struct was passed as an
// integer arg (x2) instead of in float registers (d0-d1).

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
    CGSize drawableSize() @selector("drawableSize");
}

extern(C) long MTLCreateSystemDefaultDevice();

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

    // Read back the drawable size to verify it was set correctly
    CGSize actual = metalLayer.drawableSize();
    if (actual.width < 1023.0) return 2;
    if (actual.width > 1025.0) return 3;
    if (actual.height < 767.0) return 4;
    if (actual.height > 769.0) return 5;

    return 42;
}
