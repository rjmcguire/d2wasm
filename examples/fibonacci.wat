(module
  (memory (export "memory") 1)
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


  (export "fibonacci" (func $fibonacci))
  (export "main" (func $main))
)