(module
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 100) "Hello from WASI!\n")
  (data (i32.const 150) "42\n")
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

;; templates/core/function_declaration.wat
(func $main   (result i32)
  
  ;; templates/core/expression_statement.wat
  (call $write_str (i32.const 100) (i32.const 17))

;; If the expression left something on the stack, we must drop it
;; to maintain stack height consistency in WASM.


;; templates/core/expression_statement.wat
  (call $write_str (i32.const 150) (i32.const 3))

;; If the expression left something on the stack, we must drop it
;; to maintain stack height consistency in WASM.


;; templates/control_flow/return_statement.wat
;; templates/expressions/literal_int.wat
i32.const 0

return


)


  (func $_start
    (call $main)
    drop
  )

  (export "main" (func $main))
  (export "_start" (func $_start))
)