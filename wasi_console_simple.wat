(module
  ;; WASI imports
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))

  ;; Memory for I/O and strings
  (memory 1)
  (export "memory" (memory 0))

  ;; String literals in memory
  (data (i32.const 100) "Hello, WASM!\n")
  (data (i32.const 114) "42\n")
  
  ;; Write string using WASI fd_write
  ;; Parameters: string_offset, string_length
  (func $write_str (param $offset i32) (param $len i32)
    ;; Setup iovec at memory[0]: [string_ptr, string_len]
    (i32.store (i32.const 0) (local.get $offset))
    (i32.store (i32.const 4) (local.get $len))
    
    ;; fd_write(stdout=1, iovec=0, iovec_count=1, bytes_written=8)
    (call $fd_write
      (i32.const 1)   ;; stdout
      (i32.const 0)   ;; iovec pointer
      (i32.const 1)   ;; number of iovecs
      (i32.const 8))  ;; bytes written output
    drop
  )

  ;; Main function
  (func $main (result i32)
    ;; writeln("Hello, WASM!")
    (call $write_str (i32.const 100) (i32.const 13))
    
    ;; writeln(42) - simplified
    (call $write_str (i32.const 114) (i32.const 3))
    
    (i32.const 0)  ;; return 0
  )

  ;; WASI entry point
  (func $_start
    (call $main)
    drop
  )

  (export "_start" (func $_start))
  (export "main" (func $main))
)