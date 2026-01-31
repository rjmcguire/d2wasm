# Tree-sitter D Grammar Integration

This directory will contain gdamore's tree-sitter-d grammar as a git submodule.

## Setup Instructions

1. Add the grammar as a git submodule:
   ```bash
   git submodule add https://github.com/gdamore/tree-sitter-d tree-sitter-d
   git submodule update --init --recursive
   ```

2. Install tree-sitter CLI:
   ```bash
   npm install -g tree-sitter-cli
   ```

3. Build the grammar:
   ```bash
   cd tree-sitter-d
   tree-sitter generate
   ```

4. Test the grammar:
   ```bash
   tree-sitter parse ../tests/examples/simple.d
   ```

## Integration Plan

The grammar will be integrated into the compiler through:

1. **D Bindings**: Create D bindings for the tree-sitter C library
2. **Parser Module**: `src/parser/tree_sitter_parser.d` will wrap the C API
3. **Bridge Module**: `src/parser/tree_sitter_bridge.d` converts parse trees to AST

## Architecture

```
D Source Code
     ↓
tree-sitter Parser (C library)
     ↓
Parse Tree (tree-sitter nodes)
     ↓
TreeSitterBridge.d (conversion)
     ↓
AST Nodes (our semantic representation)
     ↓
Feature Validator
     ↓
Semantic Analysis
     ↓
WASM Code Generation
```

## Supported Grammar Features

Based on our feature subset, we need these grammar rules from tree-sitter-d:

- ✅ `function_declaration`
- ✅ `class_declaration` 
- ✅ `struct_declaration`
- ✅ `interface_declaration`
- ✅ `variable_declaration`
- ✅ `enum_declaration`
- ✅ Basic types and expressions
- ✅ Control flow statements
- 🚫 Template declarations (should error)
- 🚫 Import statements (should error)
- 🚫 Module declarations (should error)

## Error Handling Strategy

The bridge will handle tree-sitter errors gracefully:

1. **Syntax Errors**: Convert tree-sitter error nodes to ParseError exceptions
2. **Missing Nodes**: Provide helpful error messages for required fields
3. **Recovery**: Skip malformed nodes where possible, continue parsing
4. **Location Tracking**: Preserve accurate source locations for error reporting