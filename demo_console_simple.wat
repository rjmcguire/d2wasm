(module
  ;; Import console functions from host environment
  (import "console" "log_i32" (func $console_log_i32 (param i32)))
  (import "console" "log_f64" (func $console_log_f64 (param f64)))
  (import "console" "log_newline" (func $console_log_newline))
  (import "console" "log_string" (func $console_log_string (param i32)))

  ;; String IDs (simple approach)
  (global $STR_HELLO i32 (i32.const 1))
  (global $STR_FINISHED i32 (i32.const 2))

  ;; D equivalent: writeln(42);
  (func $writeln_int_42
    i32.const 42
    call $console_log_i32
    call $console_log_newline
  )

  ;; D equivalent: writeln(3.14);
  (func $writeln_float_pi
    f64.const 3.14
    call $console_log_f64
    call $console_log_newline
  )

  ;; D equivalent: writeln();
  (func $writeln_empty
    call $console_log_newline
  )

  ;; D equivalent: writeln("Hello from D!");
  (func $writeln_string_hello
    global.get $STR_HELLO
    call $console_log_string
    call $console_log_newline
  )

  ;; D equivalent: writeln("Program finished");
  (func $writeln_string_finished
    global.get $STR_FINISHED
    call $console_log_string
    call $console_log_newline
  )

  ;; Main function
  (func $main (result i32)
    call $writeln_string_hello
    call $writeln_int_42
    call $writeln_float_pi
    call $writeln_empty
    call $writeln_string_finished
    i32.const 0  ;; Return 0
  )

  ;; Export main function
  (export "main" (func $main))
)