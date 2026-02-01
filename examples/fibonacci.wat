(module
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
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
(func $fibonacci  (param $l0 i32)  (result i32)
  
  ;; templates/control_flow/if_statement.wat
;; templates/expressions/binary_operation.wat
;; templates/expressions/variable_access.wat
local.get $l0

;; templates/expressions/literal_int.wat
i32.const 1

i32.le_s

if
  ;; templates/control_flow/return_statement.wat
;; templates/expressions/variable_access.wat
local.get $l0

return



end

;; templates/control_flow/return_statement.wat
;; templates/expressions/binary_operation.wat
;; templates/core/function_call.wat
;; templates/expressions/binary_operation.wat
;; templates/expressions/variable_access.wat
local.get $l0

;; templates/expressions/literal_int.wat
i32.const 1

i32.sub


call $fibonacci

;; templates/core/function_call.wat
;; templates/expressions/binary_operation.wat
;; templates/expressions/variable_access.wat
local.get $l0

;; templates/expressions/literal_int.wat
i32.const 2

i32.sub


call $fibonacci

i32.add

return


)


;; templates/core/function_declaration.wat
(func $main   (result i32)
  
  ;; templates/control_flow/return_statement.wat
;; templates/core/function_call.wat
;; templates/expressions/literal_int.wat
i32.const 10


call $fibonacci

return


)


  (func $_start
    (call $main)
    drop
  )

  (export "fibonacci" (func $fibonacci))
  (export "main" (func $main))
  (export "_start" (func $_start))
)