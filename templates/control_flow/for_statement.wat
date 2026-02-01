;; templates/control_flow/for_statement.wat
${INIT_CODE}
loop $L${LOOP_ID}
  ${CONDITION_EXPRESSION}
  if
    ${BODY_CODE}
    ${UPDATE_CODE}
    br 1
  end
end
