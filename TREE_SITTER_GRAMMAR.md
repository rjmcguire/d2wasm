# Tree-sitter Grammar Design for D Language Subset

## Overview

This document defines the tree-sitter grammar for our D language subset targeting WASM compilation. The grammar focuses on simplicity, incremental parsing efficiency, and clear AST generation.

## Grammar Design Principles

1. **Unambiguous Parsing**: Clear precedence and associativity rules
2. **Incremental Friendly**: Minimize re-parsing on small changes
3. **Error Recovery**: Graceful handling of syntax errors
4. **AST Clarity**: Grammar rules map clearly to semantic concepts

## Core Grammar Rules

### Top-Level Declarations

```javascript
module.exports = grammar({
  name: 'd_subset',
  
  extras: $ => [
    /\s/, // whitespace
    $.line_comment,
    $.block_comment,
  ],
  
  rules: {
    source_file: $ => repeat($._declaration),
    
    _declaration: $ => choice(
      $.function_declaration,
      $.struct_declaration,
      $.class_declaration,
      $.interface_declaration,
      $.variable_declaration,
      $.enum_declaration,
      $.import_declaration,
    ),
    
    // Import declarations (simplified)
    import_declaration: $ => seq(
      'import',
      $.module_name,
      optional(seq(':', $.import_list)),
      ';'
    ),
    
    module_name: $ => sep1($.identifier, '.'),
    
    import_list: $ => sep1(choice($.identifier, $.import_rename), ','),
    
    import_rename: $ => seq(
      $.identifier,
      '=',
      $.identifier
    ),
  }
});
```

### Type System

```javascript
// Type definitions
_type: $ => choice(
  $.primitive_type,
  $.array_type,
  $.pointer_type,
  $.function_type,
  $.user_defined_type
),

primitive_type: $ => choice(
  'void', 'bool',
  'byte', 'ubyte', 'short', 'ushort',
  'int', 'uint', 'long', 'ulong',
  'float', 'double',
  'char', 'wchar', 'dchar'
),

array_type: $ => choice(
  // Static arrays: int[5]
  seq($._type, '[', $.integer_literal, ']'),
  // Dynamic arrays: int[]
  seq($._type, '[', ']'),
  // Associative arrays: int[string] (future)
  seq($._type, '[', $._type, ']')
),

pointer_type: $ => seq($._type, '*'),

function_type: $ => seq(
  $._type,
  'function',
  $.parameter_list
),

user_defined_type: $ => choice(
  $.identifier,
  $.qualified_identifier
),

qualified_identifier: $ => seq(
  $.identifier,
  repeat1(seq('.', $.identifier))
),
```

### Function Declarations

```javascript
function_declaration: $ => seq(
  optional($.attribute_list),
  field('return_type', $._type),
  field('name', $.identifier),
  field('parameters', $.parameter_list),
  optional($.template_parameters), // for future template support
  optional($.contract_in),
  optional($.contract_out),
  choice(
    field('body', $.compound_statement),
    ';' // forward declaration
  )
),

parameter_list: $ => seq(
  '(',
  optional(sep1($.parameter, ',')),
  ')'
),

parameter: $ => seq(
  optional($.parameter_attributes),
  $._type,
  $.identifier,
  optional(seq('=', $.expression)) // default values
),

parameter_attributes: $ => choice(
  'in', 'out', 'ref', 'lazy'
),

// Contracts
contract_in: $ => seq(
  'in',
  $.compound_statement
),

contract_out: $ => seq(
  'out',
  optional(seq('(', $.identifier, ')')), // result parameter
  $.compound_statement
),

// Attributes
attribute_list: $ => repeat1($.attribute),

attribute: $ => choice(
  '@safe', '@trusted', '@system',
  '@pure', '@nothrow', '@nogc',
  seq('@', $.identifier),
  seq('@', $.identifier, '(', optional($.argument_list), ')')
),
```

### Class and Struct Declarations

```javascript
class_declaration: $ => seq(
  optional($.attribute_list),
  'class',
  field('name', $.identifier),
  optional(seq(':', field('base_classes', $.base_class_list))),
  field('body', $.class_body)
),

struct_declaration: $ => seq(
  optional($.attribute_list),
  'struct',
  field('name', $.identifier),
  field('body', $.struct_body)
),

interface_declaration: $ => seq(
  optional($.attribute_list),
  'interface',
  field('name', $.identifier),
  optional(seq(':', field('base_interfaces', $.base_class_list))),
  field('body', $.interface_body)
),

base_class_list: $ => sep1($.user_defined_type, ','),

class_body: $ => seq(
  '{',
  repeat($._class_member),
  '}'
),

struct_body: $ => seq(
  '{',
  repeat($._struct_member),
  '}'
),

interface_body: $ => seq(
  '{',
  repeat($._interface_member),
  '}'
),

_class_member: $ => choice(
  $.field_declaration,
  $.method_declaration,
  $.constructor_declaration,
  $.destructor_declaration,
  $.visibility_label
),

_struct_member: $ => choice(
  $.field_declaration,
  $.method_declaration,
  $.constructor_declaration
),

_interface_member: $ => choice(
  $.method_signature,
  $.property_signature
),

// Field declarations
field_declaration: $ => seq(
  optional($.attribute_list),
  $._type,
  sep1($.declarator, ','),
  ';'
),

declarator: $ => seq(
  $.identifier,
  optional(seq('=', $.expression)) // initializer
),

// Methods
method_declaration: $ => seq(
  optional($.attribute_list),
  optional($.method_modifiers),
  $._type,
  $.identifier,
  $.parameter_list,
  choice($.compound_statement, ';')
),

method_signature: $ => seq(
  optional($.attribute_list),
  $._type,
  $.identifier,
  $.parameter_list,
  ';'
),

method_modifiers: $ => repeat1(choice(
  'static', 'final', 'override', 'virtual', 'abstract'
)),

// Constructors and destructors
constructor_declaration: $ => seq(
  optional($.attribute_list),
  'this',
  $.parameter_list,
  optional($.constructor_initializer),
  $.compound_statement
),

constructor_initializer: $ => seq(
  ':',
  sep1($.member_initializer, ',')
),

member_initializer: $ => choice(
  seq('super', $.argument_list),
  seq($.identifier, $.argument_list)
),

destructor_declaration: $ => seq(
  optional($.attribute_list),
  '~this',
  '()',
  $.compound_statement
),

visibility_label: $ => seq(
  choice('private', 'protected', 'public', 'package'),
  ':'
),
```

### Expressions

```javascript
// Expression hierarchy with precedence
expression: $ => choice(
  $.assignment_expression,
  $.conditional_expression
),

assignment_expression: $ => prec.right(1, choice(
  seq($.unary_expression, '=', $.expression),
  seq($.unary_expression, '+=', $.expression),
  seq($.unary_expression, '-=', $.expression),
  seq($.unary_expression, '*=', $.expression),
  seq($.unary_expression, '/=', $.expression),
  seq($.unary_expression, '%=', $.expression)
)),

conditional_expression: $ => prec.right(2,
  seq($.logical_or_expression, '?', $.expression, ':', $.conditional_expression)
),

logical_or_expression: $ => prec.left(3,
  choice(
    $.logical_and_expression,
    seq($.logical_or_expression, '||', $.logical_and_expression)
  )
),

logical_and_expression: $ => prec.left(4,
  choice(
    $.equality_expression,
    seq($.logical_and_expression, '&&', $.equality_expression)
  )
),

equality_expression: $ => prec.left(5,
  choice(
    $.relational_expression,
    seq($.equality_expression, '==', $.relational_expression),
    seq($.equality_expression, '!=', $.relational_expression)
  )
),

relational_expression: $ => prec.left(6,
  choice(
    $.additive_expression,
    seq($.relational_expression, '<', $.additive_expression),
    seq($.relational_expression, '>', $.additive_expression),
    seq($.relational_expression, '<=', $.additive_expression),
    seq($.relational_expression, '>=', $.additive_expression)
  )
),

additive_expression: $ => prec.left(7,
  choice(
    $.multiplicative_expression,
    seq($.additive_expression, '+', $.multiplicative_expression),
    seq($.additive_expression, '-', $.multiplicative_expression)
  )
),

multiplicative_expression: $ => prec.left(8,
  choice(
    $.unary_expression,
    seq($.multiplicative_expression, '*', $.unary_expression),
    seq($.multiplicative_expression, '/', $.unary_expression),
    seq($.multiplicative_expression, '%', $.unary_expression)
  )
),

unary_expression: $ => prec(9, choice(
  $.postfix_expression,
  seq('++', $.unary_expression),
  seq('--', $.unary_expression),
  seq('+', $.unary_expression),
  seq('-', $.unary_expression),
  seq('!', $.unary_expression),
  seq('~', $.unary_expression),
  seq('*', $.unary_expression), // dereference
  seq('&', $.unary_expression), // address-of
  $.cast_expression
)),

cast_expression: $ => seq(
  'cast',
  '(',
  $._type,
  ')',
  $.unary_expression
),

postfix_expression: $ => prec.left(10, choice(
  $.primary_expression,
  seq($.postfix_expression, '[', $.expression, ']'), // array access
  seq($.postfix_expression, '.', $.identifier),      // member access
  seq($.postfix_expression, $.argument_list),        // function call
  seq($.postfix_expression, '++'),                   // post-increment
  seq($.postfix_expression, '--')                    // post-decrement
)),

primary_expression: $ => choice(
  $.identifier,
  $.literal,
  seq('(', $.expression, ')'),
  $.new_expression,
  $.this_expression,
  $.super_expression
),

new_expression: $ => seq(
  'new',
  $._type,
  optional($.argument_list)
),

this_expression: $ => 'this',
super_expression: $ => 'super',

argument_list: $ => seq(
  '(',
  optional(sep1($.expression, ',')),
  ')'
),
```

### Statements

```javascript
statement: $ => choice(
  $.expression_statement,
  $.compound_statement,
  $.if_statement,
  $.while_statement,
  $.for_statement,
  $.foreach_statement,
  $.switch_statement,
  $.return_statement,
  $.break_statement,
  $.continue_statement,
  $.declaration_statement
),

expression_statement: $ => seq($.expression, ';'),

compound_statement: $ => seq(
  '{',
  repeat($.statement),
  '}'
),

if_statement: $ => seq(
  'if',
  '(',
  $.expression,
  ')',
  $.statement,
  optional(seq('else', $.statement))
),

while_statement: $ => seq(
  'while',
  '(',
  $.expression,
  ')',
  $.statement
),

for_statement: $ => seq(
  'for',
  '(',
  optional($.for_init),
  ';',
  optional($.expression),
  ';',
  optional($.expression),
  ')',
  $.statement
),

for_init: $ => choice(
  $.expression,
  $.declaration_statement
),

foreach_statement: $ => seq(
  'foreach',
  '(',
  $.foreach_variable_list,
  ';',
  $.expression,
  ')',
  $.statement
),

foreach_variable_list: $ => sep1($.foreach_variable, ','),

foreach_variable: $ => seq(
  optional($._type),
  $.identifier
),

switch_statement: $ => seq(
  'switch',
  '(',
  $.expression,
  ')',
  '{',
  repeat($.case_statement),
  '}'
),

case_statement: $ => choice(
  seq('case', $.expression, ':', repeat($.statement)),
  seq('default', ':', repeat($.statement))
),

return_statement: $ => seq(
  'return',
  optional($.expression),
  ';'
),

break_statement: $ => seq('break', ';'),
continue_statement: $ => seq('continue', ';'),

declaration_statement: $ => choice(
  $.variable_declaration,
  $.function_declaration,
  $.struct_declaration,
  $.class_declaration
),
```

### Literals and Identifiers

```javascript
literal: $ => choice(
  $.integer_literal,
  $.float_literal,
  $.character_literal,
  $.string_literal,
  $.boolean_literal,
  $.null_literal
),

integer_literal: $ => token(choice(
  /[0-9]+/,                    // decimal
  /0[xX][0-9a-fA-F]+/,        // hexadecimal
  /0[bB][01]+/,               // binary
  /0[0-7]+/                   // octal
)),

float_literal: $ => token(choice(
  /[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?[fFL]?/,
  /[0-9]+[eE][+-]?[0-9]+[fFL]?/,
  /[0-9]+[fFL]/
)),

character_literal: $ => token(seq(
  "'",
  choice(
    /[^'\\]/,
    seq('\\', choice(
      /['"\\nrtbfav0]/,
      /x[0-9a-fA-F]{2}/,
      /[0-7]{1,3}/,
      /u[0-9a-fA-F]{4}/,
      /U[0-9a-fA-F]{8}/
    ))
  ),
  "'"
)),

string_literal: $ => token(choice(
  seq('"', repeat(choice(/[^"\\]/, /\\./)), '"'),
  seq('`', repeat(/[^`]/), '`'),  // wysiwyg strings
  seq('r"', repeat(/[^"]/), '"')  // raw strings
)),

boolean_literal: $ => choice('true', 'false'),
null_literal: $ => 'null',

identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,
```

### Comments

```javascript
line_comment: $ => token(seq('//', /.*/)),

block_comment: $ => token(seq(
  '/*',
  repeat(choice(
    /[^*]/,
    seq('*', /[^/]/)
  )),
  '*/'
)),

// Utility function for comma-separated lists
sep1: (rule, separator) => seq(rule, repeat(seq(separator, rule))),
```

## Error Recovery Strategies

### Missing Semicolons
```javascript
// Allow recovery from missing semicolons
_statement_or_error: $ => choice(
  $.statement,
  $.error_recovery_statement
),

error_recovery_statement: $ => seq(
  $.MISSING,
  'SEMICOLON_EXPECTED'
),
```

### Incomplete Declarations
```javascript
// Recover from incomplete function declarations
function_declaration: $ => choice(
  seq(
    optional($.attribute_list),
    $._type,
    $.identifier,
    $.parameter_list,
    choice($.compound_statement, ';')
  ),
  // Error recovery: missing body
  seq(
    optional($.attribute_list),
    $._type,
    $.identifier,
    $.parameter_list,
    $.MISSING
  )
),
```

## Integration with Compiler Pipeline

### AST Node Mapping
Each grammar rule maps to specific AST node types:

```javascript
// Tree-sitter → AST mapping
function_declaration → FunctionDecl
class_declaration → ClassDecl
struct_declaration → StructDecl
expression → Expression (with subtypes)
statement → Statement (with subtypes)
```

### Incremental Parsing Benefits
1. **File Changes**: Only re-parse modified sections
2. **IDE Integration**: Real-time syntax highlighting and error detection
3. **Performance**: Sub-linear parsing time for most edits
4. **Memory Efficiency**: Shared nodes for unchanged code

### Source Location Preservation
Tree-sitter automatically provides:
- **Byte offsets**: Start and end positions in source
- **Line/column**: Human-readable positions
- **Node spans**: Full source range for each syntax element

This grammar design provides a solid foundation for parsing the D language subset while supporting incremental compilation and providing clear error messages with precise source locations.