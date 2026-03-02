(module
  ;; =======================================================================
  ;; FFI Imports — each maps to the same generic_ffi_trampoline with
  ;; different FFIDescriptors
  ;; =======================================================================

  ;; Runtime lookups: char* → i64
  (import "ffi" "objc_getClass"      (func $objc_getClass      (param i32) (result i64)))
  (import "ffi" "sel_registerName"   (func $sel_registerName   (param i32) (result i64)))

  ;; objc_msgSend variants (different WASM-side signatures)
  (import "ffi" "msgSend_id"         (func $msgSend_id         (param i64 i64) (result i64)))
  (import "ffi" "msgSend_void"       (func $msgSend_void       (param i64 i64)))
  (import "ffi" "msgSend_void_id"    (func $msgSend_void_id    (param i64 i64 i64)))
  (import "ffi" "msgSend_void_i64"   (func $msgSend_void_i64   (param i64 i64 i64)))
  (import "ffi" "msgSend_void_bool"  (func $msgSend_void_bool  (param i64 i64 i32)))

  ;; initWithContentRect:styleMask:backing:defer:
  ;; (self, SEL, x, y, w, h, styleMask, backing, defer) -> id
  (import "ffi" "msgSend_initWindow" (func $msgSend_initWindow
    (param i64 i64 f64 f64 f64 f64 i64 i64 i32) (result i64)))

  ;; Get pre-created delegate instance
  (import "ffi" "get_delegate"       (func $get_delegate       (result i64)))

  ;; Debug
  (import "ffi" "print_ptr"          (func $print_ptr          (param i64)))
  (import "ffi" "print_i32"          (func $print_i32          (param i32)))

  ;; =======================================================================
  ;; Memory — string constants
  ;; =======================================================================
  (memory (export "memory") 1)

  ;;                           offset  string
  (data (i32.const 0)   "NSApplication\00")         ;; 0
  (data (i32.const 16)  "NSWindow\00")              ;; 16
  (data (i32.const 32)  "NSObject\00")              ;; 32
  (data (i32.const 48)  "sharedApplication\00")     ;; 48
  (data (i32.const 80)  "alloc\00")                 ;; 80
  (data (i32.const 96)  "init\00")                  ;; 96
  (data (i32.const 112) "setActivationPolicy:\00")  ;; 112
  (data (i32.const 144) "initWithContentRect:styleMask:backing:defer:\00") ;; 144
  (data (i32.const 208) "makeKeyAndOrderFront:\00")  ;; 208
  (data (i32.const 240) "activateIgnoringOtherApps:\00") ;; 240
  (data (i32.const 272) "setDelegate:\00")           ;; 272
  (data (i32.const 288) "run\00")                    ;; 288
  (data (i32.const 304) "setReleasedWhenClosed:\00") ;; 304

  ;; =======================================================================
  ;; Main — open a macOS window from WASM!
  ;; =======================================================================
  (func (export "main") (result i32)
    (local $app i64)
    (local $sel i64)
    (local $cls i64)
    (local $win i64)
    (local $delegate i64)

    ;; ----- Step 1: Get NSApplication.sharedApplication -----
    ;; NSApplication class
    (local.set $cls (call $objc_getClass (i32.const 0)))     ;; "NSApplication"
    ;; sel sharedApplication
    (local.set $sel (call $sel_registerName (i32.const 48))) ;; "sharedApplication"
    ;; [NSApplication sharedApplication]
    (local.set $app (call $msgSend_id (local.get $cls) (local.get $sel)))
    (call $print_ptr (local.get $app))

    ;; ----- Step 2: setActivationPolicy: NSApplicationActivationPolicyRegular (0) -----
    (local.set $sel (call $sel_registerName (i32.const 112))) ;; "setActivationPolicy:"
    (call $msgSend_void_i64 (local.get $app) (local.get $sel) (i64.const 0))

    ;; ----- Step 3: Create NSWindow -----
    ;; [NSWindow alloc]
    (local.set $cls (call $objc_getClass (i32.const 16)))    ;; "NSWindow"
    (local.set $sel (call $sel_registerName (i32.const 80))) ;; "alloc"
    (local.set $win (call $msgSend_id (local.get $cls) (local.get $sel)))

    ;; [win initWithContentRect:NSMakeRect(100,100,400,300)
    ;;                styleMask:NSWindowStyleMaskTitled|Closable|Miniaturizable|Resizable (15)
    ;;                  backing:NSBackingStoreBuffered (2)
    ;;                    defer:NO]
    (local.set $sel (call $sel_registerName (i32.const 144))) ;; "initWithContentRect:..."
    (local.set $win (call $msgSend_initWindow
      (local.get $win)
      (local.get $sel)
      (f64.const 100)    ;; x
      (f64.const 100)    ;; y
      (f64.const 400)    ;; width
      (f64.const 300)    ;; height
      (i64.const 15)     ;; styleMask (titled|closable|miniaturizable|resizable)
      (i64.const 2)      ;; backing (buffered)
      (i32.const 0)      ;; defer: NO
    ))
    (call $print_ptr (local.get $win))

    ;; ----- Step 4: Show the window -----
    ;; [win makeKeyAndOrderFront:nil]
    (local.set $sel (call $sel_registerName (i32.const 208))) ;; "makeKeyAndOrderFront:"
    (call $msgSend_void_id (local.get $win) (local.get $sel) (i64.const 0))

    ;; ----- Step 5: Activate the app -----
    ;; [NSApp activateIgnoringOtherApps:YES]
    (local.set $sel (call $sel_registerName (i32.const 240))) ;; "activateIgnoringOtherApps:"
    (call $msgSend_void_i64 (local.get $app) (local.get $sel) (i64.const 1))

    ;; ----- Step 6: Set delegate (ffi_closure callback) -----
    (local.set $delegate (call $get_delegate))
    (call $print_ptr (local.get $delegate))

    ;; [NSApp setDelegate:delegate]
    (local.set $sel (call $sel_registerName (i32.const 272))) ;; "setDelegate:"
    (call $msgSend_void_id (local.get $app) (local.get $sel) (local.get $delegate))

    ;; ----- Step 7: Enter event loop (blocks forever, Ctrl-C to exit) -----
    ;; [NSApp run]
    (local.set $sel (call $sel_registerName (i32.const 288))) ;; "run"
    (call $msgSend_void (local.get $app) (local.get $sel))

    ;; Won't reach here until app quits
    (i32.const 0)
  )
)
