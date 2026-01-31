# Template-Driven Code Generation Strategy

## Executive Summary

**Problem**: Current D-to-WASM compiler has significant frontend-backend disconnect, WASM generation bugs, and cannot handle real multi-function D programs.

**Solution**: Replace complex WASM generation logic with simple, proven-correct WAT templates for each D language construct.

**Goal**: Transform from "complex codegen with bugs" to "simple template substitution with correctness."

## Current State Analysis

### 🚨 **Critical Issues Identified**
1. **Frontend-Backend Disconnect**: Parser mocks everything as `"parsed_function"`
2. **Stack Management Bugs**: Expression statements use wrong logic for dropping values
3. **Limited Scope**: Cannot compile multi-function files like `fibonacci.d`
4. **Complex Generation**: `generateStatement()` logic is brittle and error-prone

### 📊 **Architecture Gaps**
- Tree-sitter bridge has TODOs for most D constructs
- Missing heap management for classes/structs  
- Virtual dispatch (vtables) not implemented
- No real function call support

## Template-Driven Solution

### 🎯 **Core Principle**
**Every D language construct maps to exactly one WAT template with parameter substitution.**

### 🏗️ **Architecture Transformation**
```
Current:  D AST → Complex Logic → WASM Instructions → WAT
Proposed: D AST → Template Selection → Parameter Substitution → WAT
```

### ✅ **Benefits**
- **Correctness**: Each template independently tested and verified
- **Simplicity**: No complex WASM generation logic
- **Maintainability**: Easy to understand and modify templates
- **Parallel Development**: Templates can be built while fixing parser
- **Debugging**: Template bugs are localized and obvious

## Implementation Strategy

### Phase 1: Template Infrastructure (Week 1)

#### **1.1 Template Engine Design**
```d
// Template substitution interface
interface TemplateEngine {
    string substitute(string templateName, string[string] parameters);
    void loadTemplate(string name, string watContent);
    string[] getAvailableTemplates();
}

class SimpleTemplateEngine : TemplateEngine {
    private string[string] templates;
    
    string substitute(string templateName, string[string] parameters) {
        string template = templates[templateName];
        foreach (key, value; parameters) {
            template = template.replace("${" ~ key ~ "}", value);
        }
        return template;
    }
}
```

#### **1.2 Template Repository Structure**
```
templates/
├── core/
│   ├── function_declaration.wat
│   ├── function_call.wat
│   ├── variable_assignment.wat
│   └── expression_statement.wat
├── control_flow/
│   ├── if_statement.wat
│   ├── while_loop.wat
│   ├── for_loop.wat
│   └── return_statement.wat
├── expressions/
│   ├── binary_operation.wat
│   ├── variable_access.wat
│   ├── literal_int.wat
│   └── literal_string.wat
└── advanced/
    ├── class_method_call.wat
    ├── array_access.wat
    └── heap_allocation.wat
```

#### **1.3 Template Validation Framework**
```bash
# Each template has corresponding test
templates/core/function_declaration.wat
tests/templates/function_declaration_test.wat
tests/templates/function_declaration_expected.txt
```

### Phase 2: Core Language Templates (Week 2)

#### **2.1 Critical Templates (Priority 1)**

**Function Declaration Template:**
```wat
;; templates/core/function_declaration.wat
(func $${FUNCTION_NAME} ${PARAMETER_LIST} ${RETURN_TYPE}
  ${LOCAL_VARIABLES}
  ${FUNCTION_BODY}
)
```

**Function Call Template:**
```wat
;; templates/core/function_call.wat  
${ARGUMENTS}
call $${FUNCTION_NAME}
```

**Expression Statement Template:**
```wat
;; templates/core/expression_statement.wat
${EXPRESSION_CODE}
;; Always drop result for expression statements - fixes current bug!
drop
```

**Variable Assignment Template:**
```wat
;; templates/core/variable_assignment.wat
${VALUE_EXPRESSION}
local.set $${VARIABLE_NAME}
```

#### **2.2 Control Flow Templates (Priority 2)**

**If Statement Template:**
```wat
;; templates/control_flow/if_statement.wat
${CONDITION_EXPRESSION}
if ${RESULT_TYPE}
  ${THEN_BODY}
${ELSE_CLAUSE}
end
```

**While Loop Template:**
```wat
;; templates/control_flow/while_loop.wat
loop $loop_${LOOP_ID}
  ${CONDITION_EXPRESSION}
  i32.eqz
  br_if $loop_${LOOP_ID}_end
  ${LOOP_BODY}
  br $loop_${LOOP_ID}
end $loop_${LOOP_ID}_end
```

#### **2.3 Template Parameter Mapping**

**D Construct → Template Parameters:**
```d
// Function declaration: int fibonacci(int n)
templateParams = [
    "FUNCTION_NAME": "fibonacci",
    "PARAMETER_LIST": "(param $n i32)",
    "RETURN_TYPE": "(result i32)",
    "LOCAL_VARIABLES": "",
    "FUNCTION_BODY": generateFunctionBody(astNode.body)
];

// Function call: fibonacci(n-1)
templateParams = [
    "ARGUMENTS": "local.get $n\ni32.const 1\ni32.sub",
    "FUNCTION_NAME": "fibonacci"
];
```

### Phase 3: Template-Driven Codegen Integration (Week 3)

#### **3.1 Replace WasmGenerator**
```d
// New template-driven generator
class TemplateWasmGenerator {
    private TemplateEngine templateEngine;
    
    string generateFunction(FunctionDecl func) {
        auto params = buildFunctionParameters(func);
        return templateEngine.substitute("function_declaration", params);
    }
    
    string generateFunctionCall(CallExpression call) {
        auto params = buildCallParameters(call);
        return templateEngine.substitute("function_call", params);
    }
    
    // No more complex generateStatement() logic!
    string generateStatement(Statement stmt) {
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            auto exprCode = generateExpression(exprStmt.expression);
            return templateEngine.substitute("expression_statement", 
                ["EXPRESSION_CODE": exprCode]);
        }
        // ... delegate to other template methods
    }
}
```

#### **3.2 Template Parameter Builders**
```d
// Clean parameter building logic
string[string] buildFunctionParameters(FunctionDecl func) {
    string[string] params;
    params["FUNCTION_NAME"] = func.name;
    params["PARAMETER_LIST"] = buildParameterList(func.parameters);
    params["RETURN_TYPE"] = buildReturnType(func.returnType);
    params["LOCAL_VARIABLES"] = buildLocalVariables(func);
    params["FUNCTION_BODY"] = buildFunctionBody(func.body_);
    return params;
}
```

### Phase 4: Advanced Features (Week 4)

#### **4.1 Heap Management Templates**
```wat
;; templates/advanced/heap_allocation.wat
;; Allocate ${SIZE} bytes
i32.const ${SIZE}
call $malloc
```

#### **4.2 Class Method Templates**
```wat
;; templates/advanced/class_method_call.wat
${OBJECT_REFERENCE}
${ARGUMENTS}
;; Load vtable pointer
local.get ${OBJECT_REFERENCE}
i32.load  ;; vtable pointer
;; Call virtual method at offset ${VTABLE_OFFSET}
i32.const ${VTABLE_OFFSET}
i32.add
i32.load  ;; function pointer
call_indirect ${FUNCTION_SIGNATURE}
```

## Template Design Principles

### ✅ **What Templates Should Cover**
- **Language constructs only** (following AGENTS.md principles)
- **Syntactic transformations** (D syntax → WASM syntax)
- **Proper stack management** (eliminate current bugs)
- **Memory layout patterns** (local variables, parameters)

### 🚫 **What Templates Should NOT Cover**
- **Algorithm implementations** (no fibonacci templates!)
- **Application logic** (no domain-specific patterns)
- **Optimization strategies** (keep templates simple)
- **Runtime behavior** (templates are compile-time only)

### 📋 **Template Quality Standards**
1. **One template per language construct**
2. **Minimal parameter surface** (fewer substitutions = fewer bugs)
3. **Stack-correct by design** (proper WASM stack discipline)
4. **Independently testable** (each template has unit tests)
5. **Human readable** (templates should be reviewable WAT)

## Migration Strategy

### 🔄 **Incremental Replacement**
1. **Keep current system running** while building templates
2. **Replace one construct at a time** (start with function declarations)
3. **A/B test template vs current** (compare generated WAT)
4. **Gradually deprecate complex logic** as templates prove themselves

### 📊 **Success Metrics**
- **Correctness**: Generated WAT compiles and runs correctly
- **Simplicity**: Template substitution vs complex generation logic
- **Coverage**: All D subset constructs have templates
- **Performance**: Template approach compiles faster than current

### 🧪 **Validation Process**
1. **Template Unit Tests**: Each template tested in isolation
2. **Integration Tests**: Templates work together correctly
3. **Real D Programs**: Can compile actual D files (fibonacci.d, etc.)
4. **Regression Tests**: Ensure templates don't break existing functionality

## Risk Assessment & Mitigation

### ⚠️ **Potential Risks**
1. **Template Complexity**: Templates become too complex
   - **Mitigation**: Strict simplicity guidelines, code review
2. **Parameter Explosion**: Too many template parameters
   - **Mitigation**: Keep parameter count low, group related parameters
3. **Performance Overhead**: Template substitution too slow
   - **Mitigation**: Profile and optimize template engine if needed

### 🛡️ **Fallback Strategy**
- **Hybrid approach**: Use templates for fixed constructs, logic for complex ones
- **Gradual migration**: Can revert individual constructs if templates fail
- **Template debugging**: Clear error messages when template substitution fails

## Expected Outcomes

### 📈 **Immediate Benefits (1-2 weeks)**
- **Fix expression statement bug** with correct template
- **Enable multi-function compilation** with function declaration template
- **Simplify debugging** with readable WAT templates

### 🚀 **Medium-term Benefits (1 month)**
- **Complete D subset support** through comprehensive template library
- **Faster compilation** via simple substitution vs complex logic
- **Easier maintenance** with isolated, testable templates

### 🏆 **Long-term Benefits (3+ months)**
- **Robust foundation** for additional D features
- **Community contributions** via readable template format
- **Performance optimizations** by improving individual templates

## Next Steps

### 🎯 **Immediate Actions**
1. **Create template infrastructure** (TemplateEngine interface)
2. **Build core function declaration template** (fix multi-function issue)
3. **Replace expression statement logic** (fix stack management bug)
4. **Test with real D programs** (fibonacci.d compilation)

### 📋 **Success Criteria for Phase 1**
- [ ] `fibonacci.d` compiles to working WASM using templates
- [ ] Expression statements have correct stack behavior
- [ ] Template engine handles parameter substitution correctly
- [ ] All existing tests still pass with template approach

---

**This template strategy transforms the D-to-WASM compiler from "complex and buggy" to "simple and correct" by leveraging proven WAT patterns instead of complex generation logic.**