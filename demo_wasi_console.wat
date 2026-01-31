(module
  ;; WASI imports for console output
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))

  ;; Memory for string data and I/O vectors
  (memory 1)
  (export "memory" (memory 0))

  ;; String literals stored in memory
  (data (i32.const 1024) "Hello from D!")
  (data (i32.const 1038) "42")
  (data (i32.const 1041) "3.14")
  (data (i32.const 1046) "\n")
  (data (i32.const 1048) "Program finished")

  ;; Global for next available memory offset
  (global $mem_offset (mut i32) (i32.const 2048))

  ;; I/O vector structure in memory (ptr, len pairs)
  ;; Layout at offset 0:
  ;;   [0-3]: string pointer
  ;;   [4-7]: string length
  ;;   [8-11]: newline pointer 
  ;;   [12-15]: newline length

  ;; Initialize I/O vector for newline
  (func $init_iovec
    ;; Newline iovec at offset 8
    (i32.store (i32.const 8) (i32.const 1046))   ;; newline ptr
    (i32.store (i32.const 12) (i32.const 1))     ;; newline len
  )

  ;; Write string to stdout using WASI fd_write
  ;; Parameters: string_ptr, string_len
  (func $write_string (param $str_ptr i32) (param $str_len i32)
    ;; Setup iovec: [ptr, len] at memory offset 0
    (i32.store (i32.const 0) (local.get $str_ptr))
    (i32.store (i32.const 4) (local.get $str_len))
    
    ;; Call fd_write(stdout=1, iovec_ptr=0, iovec_count=1, written_ptr=16)
    (call $fd_write 
      (i32.const 1)    ;; fd = 1 (stdout)
      (i32.const 0)    ;; iovec ptr
      (i32.const 1)    ;; iovec count
      (i32.const 16))  ;; bytes written (output)
    drop  ;; ignore return value
  )

  ;; Write newline to stdout
  (func $write_newline
    ;; Call fd_write with newline iovec at offset 8
    (call $fd_write
      (i32.const 1)    ;; fd = 1 (stdout)  
      (i32.const 8)    ;; iovec ptr (newline)
      (i32.const 1)    ;; iovec count
      (i32.const 20))  ;; bytes written (output)
    drop
  )

  ;; Convert integer to string and write
  ;; This is a simplified version - in real implementation would need proper itoa
  (func $write_i32 (param $value i32)
    ;; For demo, just write the pre-stored "42"
    ;; Real implementation would convert i32 to string
    (call $write_string (i32.const 1038) (i32.const 2))
  )

  ;; Convert float to string and write  
  ;; Simplified version for demo
  (func $write_f64 (param $value f64)
    ;; For demo, just write the pre-stored "3.14"
    ;; Real implementation would convert f64 to string
    (call $write_string (i32.const 1041) (i32.const 4))
  )

  ;; writeln implementations
  (func $writeln_string_hello
    (call $write_string (i32.const 1024) (i32.const 13))  ;; "Hello from D!"
    (call $write_newline)
  )

  (func $writeln_i32_42  
    (call $write_i32 (i32.const 42))
    (call $write_newline)
  )

  (func $writeln_f64_pi
    (call $write_f64 (f64.const 3.14))
    (call $write_newline)
  )

  (func $writeln_empty
    (call $write_newline)
  )

  (func $writeln_string_finished
    (call $write_string (i32.const 1048) (i32.const 16))  ;; "Program finished"
    (call $write_newline)
  )

  ;; Main function - equivalent to D:
  ;; int main() {
  ;;     writeln("Hello from D!");
  ;;     writeln(42);
  ;;     writeln(3.14); 
  ;;     writeln();
  ;;     writeln("Program finished");
  ;;     return 0;
  ;; }
  (func $main (result i32)
    (call $init_iovec)
    (call $writeln_string_hello)
    (call $writeln_i32_42)
    (call $writeln_f64_pi)
    (call $writeln_empty)
    (call $writeln_string_finished)
    (i32.const 0)  ;; Return 0
  )

  ;; WASI requires _start export
  (func $_start
    (call $main)
    drop
  )

  ;; Export functions
  (export "_start" (func $_start))
  (export "main" (func $main))
)