;; templates/core/expression_statement.wat
${EXPRESSION_CODE}
;; If the expression left something on the stack, we must drop it
;; to maintain stack height consistency in WASM.
${DROP_IF_NEEDED}
