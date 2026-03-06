// Milestone 221: ObjC struct-by-value passing (HFA flattening)
//
// extern(Objective-C) interface methods can now accept struct parameters.
// At the WASM/FFI level, struct params are flattened into individual fields:
//   NSRect (4 doubles) → 4 separate f64 params in the WASM signature
//
// On ARM64, this maps directly to the HFA (Homogeneous Float Aggregate)
// calling convention: doubles go in d0-d3, integers in x2+.
// No FFI trampoline changes needed — existing ARG_F64 handling works.
//
// This eliminates metal_init_window and metal_set_drawable_size from
// the Metal demo bridge.

struct NSRect {
    double x;
    double y;
    double width;
    double height;
}

struct CGSize {
    double width;
    double height;
}

extern(Objective-C)
interface NSWindow {
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect rect, long styleMask, long backing, int defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");
}

extern(Objective-C)
interface CAMetalLayer {
    void setDrawableSize(CGSize size) @selector("setDrawableSize:");
}

// Compile-only: verifies the compiler accepts struct params in ObjC
// interfaces and generates correct flattened WASM signatures + FFI meta.
int main() {
    return 0;
}
