;; templates/core/variable_assignment.wat
${VALUE_EXPRESSION}
${SET_INSTRUCTION} $${VARIABLE_NAME}
;; Assignment also leaves the value on the stack in D
${GET_INSTRUCTION} $${VARIABLE_NAME}
