(module
  ;; Import console functions from host environment
  (import "console" "log" (func $console_log (param i32 i32)))
  (import "console" "log_i32" (func $console_log_i32 (param i32)))
  (import "console" "log_f64" (func $console_log_f64 (param f64)))
  (import "console" "log_newline" (func $console_log_newline))
  (import "memory" "alloc" (func $mem_alloc (param i32) (result i32)))
  (import "memory" "store_string" (func $mem_store_string (param i32 i32) (result i32)))

  ;; Memory (1 page = 64KB)
  (memory 1)

  ;; String literals stored in memory starting at offset 1024
  (data (i32.const 1024) "Hello from D!")
  (data (i32.const 1038) "Program finished")

  ;; D equivalent: writeln("Hello from D!");
  (func $writeln_string_hello
    ;; Load pointer to "Hello from D!" and its length
    i32.const 1024  ;; String pointer
    i32.const 13    ;; String length  
    call $console_log
    call $console_log_newline
  )

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

  ;; D equivalent: writeln("Program finished");
  (func $writeln_string_finished
    ;; Load pointer to "Program finished" and its length
    i32.const 1038  ;; String pointer
    i32.const 16    ;; String length
    call $console_log
    call $console_log_newline
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