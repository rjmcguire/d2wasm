(module
  ;; Import WASI fd_write function
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  
  ;; Memory for string data and iovec structures
  (memory 1)
  
  ;; String data for D program output
  ;; Generated data segments from D file:
  (data (i32.const 1024) "42\0A")
  (data (i32.const 1028) "\0A")
  
  ;; Function to write a string using WASI fd_write
  (func $writeln_string (param $ptr i32) (param $len i32)
    (local $iovec_ptr i32)
    (local $nwritten_ptr i32)
    
    ;; Use fixed memory locations
    i32.const 8192
    local.set $iovec_ptr
    
    ;; iovec.iov_base = string pointer
    local.get $iovec_ptr
    local.get $ptr
    i32.store
    
    ;; iovec.iov_len = string length
    local.get $iovec_ptr
    i32.const 4
    i32.add
    local.get $len
    i32.store
    
    ;; Use fixed location for nwritten
    i32.const 8200
    local.set $nwritten_ptr
    
    ;; Call fd_write(stdout=1, iovec_ptr, iovec_count=1, nwritten_ptr)
    i32.const 1  ;; stdout file descriptor
    local.get $iovec_ptr
    i32.const 1  ;; iovec count
    local.get $nwritten_ptr
    call $fd_write
    drop  ;; ignore return value
  )
  
  ;; Main function from D source
  (func $main (result i32)
    ;; writeln(42)
    i32.const 1024
    i32.const 3
    call $writeln_string
    ;; writeln() - empty line
    i32.const 1028
    i32.const 1
    call $writeln_string
    ;; return 0
    i32.const 0
  )
  
  (export "_start" (func $main))
  (export "memory" (memory 0))
)
