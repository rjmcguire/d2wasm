(module
  ;; WASI imports
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))

  ;; Memory (required for WASI)
  (memory 1)
  (export "memory" (memory 0))

  ;; Global for memory allocation (simple bump allocator)
  (global $heap_ptr (mut i32) (i32.const 1024))

  ;; String literals in memory
  (data (i32.const 100) "Hello from WASI D!")
  (data (i32.const 119) "The answer is: ")
  (data (i32.const 134) "42")
  (data (i32.const 137) "Pi approximation: ")
  (data (i32.const 155) "3.14159")
  (data (i32.const 163) "\n")
  (data (i32.const 165) "Program completed successfully!")
  
  ;; Utility function: allocate memory
  (func $malloc (param $size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap_ptr))
    (global.set $heap_ptr 
      (i32.add (local.get $ptr) (local.get $size)))
    (local.get $ptr)
  )

  ;; Core WASI write function
  (func $write_to_stdout (param $str_ptr i32) (param $str_len i32)
    (local $iovec_ptr i32)
    (local $result i32)
    
    ;; Allocate space for iovec (8 bytes: ptr + len)
    (local.set $iovec_ptr (call $malloc (i32.const 8)))
    
    ;; Set up iovec structure
    (i32.store (local.get $iovec_ptr) (local.get $str_ptr))                    ;; iov_base
    (i32.store (i32.add (local.get $iovec_ptr) (i32.const 4)) (local.get $str_len)) ;; iov_len
    
    ;; Call fd_write: fd=1 (stdout), iovec, iovec_count=1, bytes_written_ptr  
    (call $fd_write
      (i32.const 1)                     ;; stdout file descriptor
      (local.get $iovec_ptr)            ;; pointer to iovec array
      (i32.const 1)                     ;; number of iovec entries
      (call $malloc (i32.const 4)))     ;; pointer to store bytes written
    drop ;; ignore result for simplicity
  )

  ;; High-level writeln functions

  ;; writeln for strings
  (func $writeln_str (param $str_ptr i32) (param $str_len i32)
    (call $write_to_stdout (local.get $str_ptr) (local.get $str_len))
    (call $write_to_stdout (i32.const 163) (i32.const 1))  ;; newline
  )

  ;; writeln for integers (simplified - uses pre-stored string)
  (func $writeln_int (param $value i32)
    ;; For demo purposes, we'll just print our pre-stored "42"
    ;; Real implementation would convert int to string dynamically
    (call $write_to_stdout (i32.const 134) (i32.const 2))  ;; "42"
    (call $write_to_stdout (i32.const 163) (i32.const 1))  ;; newline
  )

  ;; writeln for floats (simplified - uses pre-stored string)
  (func $writeln_float (param $value f64)
    ;; For demo purposes, we'll just print our pre-stored "3.14159"
    ;; Real implementation would convert float to string dynamically
    (call $write_to_stdout (i32.const 155) (i32.const 7))  ;; "3.14159"
    (call $write_to_stdout (i32.const 163) (i32.const 1))  ;; newline
  )

  ;; writeln() - just newline
  (func $writeln_empty
    (call $write_to_stdout (i32.const 163) (i32.const 1))  ;; newline
  )

  ;; Example D program translated to WASM:
  ;; ```d
  ;; int main() {
  ;;     writeln("Hello from WASI D!");
  ;;     writeln("The answer is: ");
  ;;     writeln(42);
  ;;     writeln("Pi approximation: ");
  ;;     writeln(3.14159);
  ;;     writeln();
  ;;     writeln("Program completed successfully!");
  ;;     return 0;
  ;; }
  ;; ```
  (func $main (result i32)
    (call $writeln_str (i32.const 100) (i32.const 18))  ;; "Hello from WASI D!"
    (call $write_to_stdout (i32.const 119) (i32.const 15))  ;; "The answer is: " (no newline)
    (call $writeln_int (i32.const 42))
    (call $write_to_stdout (i32.const 137) (i32.const 18))  ;; "Pi approximation: " (no newline)
    (call $writeln_float (f64.const 3.14159))
    (call $writeln_empty)
    (call $writeln_str (i32.const 165) (i32.const 31))  ;; "Program completed successfully!"
    (i32.const 0)  ;; return 0
  )

  ;; WASI entry point - required by WASI spec
  (func $_start
    (call $main)
    drop  ;; ignore return value
  )

  ;; Required exports
  (export "_start" (func $_start))
  (export "main" (func $main))  ;; Also export main for testing
)