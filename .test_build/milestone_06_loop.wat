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
(func $sum_to  (param $l0 i32)  (result i32)
  (local $l1 i32)
  (local $l2 i32)
  ;; templates/expressions/literal_int.wat
i32.const 0

local.set $l1
;; templates/control_flow/for_statement.wat
;; templates/expressions/literal_int.wat
i32.const 0

local.set $l2
loop $L0
  ;; templates/expressions/binary_operation.wat
;; templates/expressions/variable_access.wat
local.get $l2

;; templates/expressions/variable_access.wat
local.get $l0

i32.lt_s

  if
    ;; templates/core/expression_statement.wat
;; templates/core/variable_assignment.wat
;; templates/expressions/binary_operation.wat
;; templates/expressions/variable_access.wat
local.get $l1

;; templates/expressions/variable_access.wat
local.get $l2

i32.add

local.set $l1
;; Assignment also leaves the value on the stack in D
local.get $l1

;; If the expression left something on the stack, we must drop it
;; to maintain stack height consistency in WASM.



    local.get $l2
local.get $l2
i32.const 1
i32.add
local.set $l2
drop
    br 1
  end
end

;; templates/control_flow/return_statement.wat
;; templates/expressions/variable_access.wat
local.get $l1

return


)


  (export "sum_to" (func $sum_to))
)