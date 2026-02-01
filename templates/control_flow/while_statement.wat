;; templates/control_flow/while_statement.wat
loop $L${LOOP_ID}
  ${CONDITION_EXPRESSION}
  if
    ${BODY_CODE}
    br 1
  end
end
