/**
 * D Name Mangling
 * 
 * Implements D's official name mangling scheme for typesafe linking.
 * Reference: https://dlang.org/spec/abi.html#name_mangling
 * 
 * Basic structure:
 *   _D <QualifiedName> <Type>
 * 
 * Where QualifiedName is a sequence of LNames (length-prefixed identifiers).
 */
module codegen.mangle;

import std.conv : to;
import std.format : format;
import std.array : join, array;
import std.algorithm : map, splitter;
import ast.nodes;
import ast.expressions : LiteralExpression;

/**
 * Mangle a symbol name with its module path.
 * 
 * Example:
 *   mangleSymbol(["foo", "bar"], "baz") => "_D3foo3bar3baz"
 *   mangleSymbol(["animals", "dog"], "speak") => "_D7animals3dog5speak"
 */
string mangleSymbol(string[] modulePath, string symbolName) {
    string result = "_D";
    
    // Append module path components
    foreach (component; modulePath) {
        result ~= lname(component);
    }
    
    // Append symbol name
    result ~= lname(symbolName);
    
    return result;
}

/**
 * Mangle a function with its type signature.
 * 
 * Example:
 *   mangleFunction(["test"], "foo", "int", []) => "_D4test3fooFZi"
 *   mangleFunction(["test"], "bar", "int", ["int"]) => "_D4test3barFiZi"
 */
string mangleFunction(string[] modulePath, string funcName, string returnType, string[] paramTypes) {
    string result = mangleSymbol(modulePath, funcName);
    
    // Function type: F <params> Z <return>
    result ~= "F";  // D calling convention
    
    // Parameter types
    foreach (param; paramTypes) {
        result ~= mangleType(param);
    }
    
    result ~= "Z";  // End of parameters
    result ~= mangleType(returnType);
    
    return result;
}

/**
 * Mangle a method (has implicit 'this' parameter).
 * 
 * Example:
 *   mangleMethod(["test"], "Dog", "speak", "int", []) => "_D4test3Dog5speakMFZi"
 */
string mangleMethod(string[] modulePath, string className, string methodName, 
                    string returnType, string[] paramTypes) {
    string result = "_D";
    
    // Module path
    foreach (component; modulePath) {
        result ~= lname(component);
    }
    
    // Class name
    result ~= lname(className);
    
    // Method name
    result ~= lname(methodName);
    
    // M indicates method (requires 'this')
    result ~= "M";
    
    // Function type
    result ~= "F";
    foreach (param; paramTypes) {
        result ~= mangleType(param);
    }
    result ~= "Z";
    result ~= mangleType(returnType);
    
    return result;
}

/**
 * Create a length-prefixed name (LName).
 * 
 * Example:
 *   lname("foo") => "3foo"
 *   lname("animals") => "7animals"
 */
string lname(string name) {
    return to!string(name.length) ~ name;
}

/**
 * Mangle a type name.
 * 
 * Basic types:
 *   void => v, bool => b, byte => g, ubyte => h
 *   short => s, ushort => t, int => i, uint => k
 *   long => l, ulong => m, float => f, double => d
 *   char => a, wchar => u, dchar => w
 * 
 * Derived types:
 *   pointer => P<type>
 *   array => A<type>
 *   static array => G<length><type>
 */
string mangleType(string typeName) {
    switch (typeName) {
        // Void
        case "void": return "v";
        
        // Boolean
        case "bool": return "b";
        
        // Signed integers
        case "byte": return "g";
        case "short": return "s";
        case "int": return "i";
        case "long": return "l";
        
        // Unsigned integers
        case "ubyte": return "h";
        case "ushort": return "t";
        case "uint": return "k";
        case "ulong": return "m";
        
        // Floating point
        case "float": return "f";
        case "double": return "d";
        case "real": return "e";
        
        // Characters
        case "char": return "a";
        case "wchar": return "u";
        case "dchar": return "w";
        
        default:
            // User-defined type: use LName
            // For now, just length-prefix it
            // TODO: Handle pointers, arrays, qualifiers
            if (typeName.length > 0 && typeName[$ - 1] == '*') {
                // Pointer type
                return "P" ~ mangleType(typeName[0 .. $ - 1]);
            }
            if (typeName.length > 2 && typeName[$ - 2 .. $] == "[]") {
                // Dynamic array
                return "A" ~ mangleType(typeName[0 .. $ - 2]);
            }
            return lname(typeName);
    }
}

/**
 * Mangle a Type AST node.
 */
string mangleTypeNode(Type type) {
    if (type is null) return "v";  // void
    
    if (auto basic = cast(BasicType)type) {
        return mangleBasicType(basic.kind);
    }
    
    if (auto ptr = cast(PointerType)type) {
        return "P" ~ mangleTypeNode(ptr.pointeeType);
    }
    
    if (auto arr = cast(ArrayType)type) {
        // Static array has non-null arraySize
        if (arr.arraySize !is null) {
            // Try to get static length from literal
            if (auto lit = cast(LiteralExpression)arr.arraySize) {
                try {
                    long len = lit.value.get!long;
                    return "G" ~ to!string(len) ~ mangleTypeNode(arr.elementType);
                } catch (Exception e) {
                    // Fall through to dynamic array mangling
                }
            }
            // Fall back to dynamic array mangling for complex expressions
        }
        return "A" ~ mangleTypeNode(arr.elementType);
    }
    
    if (auto user = cast(UserType)type) {
        return lname(user.name);
    }
    
    // Fallback
    return lname(type.toString());
}

/**
 * Mangle a BasicType.Kind to type character.
 */
string mangleBasicType(BasicType.Kind kind) {
    final switch (kind) {
        case BasicType.Kind.Void: return "v";
        case BasicType.Kind.Bool: return "b";
        case BasicType.Kind.Int8: return "g";
        case BasicType.Kind.Int16: return "s";
        case BasicType.Kind.Int32: return "i";
        case BasicType.Kind.Int64: return "l";
        case BasicType.Kind.UInt8: return "h";
        case BasicType.Kind.UInt16: return "t";
        case BasicType.Kind.UInt32: return "k";
        case BasicType.Kind.UInt64: return "m";
        case BasicType.Kind.Float32: return "f";
        case BasicType.Kind.Float64: return "d";
        case BasicType.Kind.Char: return "a";
    }
}

/**
 * Compute the D ABI mangled name for a FunctionDecl.
 * Handles free functions, methods, destructors, and constructors.
 * Uses the module path and parent struct/class info from the decl itself.
 */
string computeMangledName(const(string[]) modulePath, FunctionDecl decl) {
    string result = "_D";

    // Module path components
    foreach (component; modulePath)
        result ~= lname(component);

    // Parent aggregate (struct/class) for methods
    if (decl.isMethod && decl.parent !is null) {
        if (auto sd = cast(StructDecl)decl.parent)
            result ~= lname(sd.name);
        else if (auto cd = cast(ClassDecl)decl.parent)
            result ~= lname(cd.name);
    }

    // Symbol name — destructors use __dtor, constructors use __ctor
    string symName = decl.isDestructor ? "__dtor"
                   : decl.isConstructor ? "__ctor"
                   : decl.name;
    result ~= lname(symName);

    // Method marker
    if (decl.isMethod)
        result ~= "M";

    // Function type: F <params> Z <return>
    result ~= "F";
    foreach (p; decl.parameters)
        result ~= mangleTypeNode(p.type);
    result ~= "Z";
    result ~= mangleTypeNode(decl.returnType);

    return result;
}

/**
 * Demangle a D mangled name back to human-readable form.
 * Used for error messages.
 * 
 * Example:
 *   demangle("_D7animals3dog5speakFZi") => "animals.dog.speak() -> int"
 */
string demangle(string mangled) {
    if (mangled.length < 2 || mangled[0 .. 2] != "_D") {
        return mangled;  // Not a D mangled name
    }
    
    try {
        size_t pos = 2;
        string[] parts;
        
        // Parse qualified name (sequence of LNames)
        while (pos < mangled.length) {
            char c = mangled[pos];
            
            // Check for type/function markers
            if (c == 'F' || c == 'M' || c == 'Z' || c == 'i' || c == 'v' || 
                c == 'b' || c == 's' || c == 'l' || c == 'P' || c == 'A') {
                break;
            }
            
            // Parse LName: number followed by that many chars
            if (c >= '0' && c <= '9') {
                size_t len = 0;
                while (pos < mangled.length && mangled[pos] >= '0' && mangled[pos] <= '9') {
                    len = len * 10 + (mangled[pos] - '0');
                    pos++;
                }
                if (pos + len <= mangled.length) {
                    parts ~= mangled[pos .. pos + len];
                    pos += len;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        
        string result = parts.join(".");
        
        // Check for function signature
        if (pos < mangled.length) {
            bool isMethod = mangled[pos] == 'M';
            if (isMethod) pos++;
            
            if (pos < mangled.length && mangled[pos] == 'F') {
                pos++;
                
                // Parse parameters
                string[] params;
                while (pos < mangled.length && mangled[pos] != 'Z') {
                    params ~= demangleTypeChar(mangled[pos]);
                    pos++;
                }
                
                if (pos < mangled.length && mangled[pos] == 'Z') {
                    pos++;
                }
                
                // Parse return type
                string retType = "?";
                if (pos < mangled.length) {
                    retType = demangleTypeChar(mangled[pos]);
                }
                
                result ~= "(" ~ params.join(", ") ~ ")";
                if (retType != "void") {
                    result ~= " -> " ~ retType;
                }
            }
        }
        
        return result;
    } catch (Exception e) {
        return mangled;  // Return original if demangling fails
    }
}

/**
 * Demangle a single type character.
 */
private string demangleTypeChar(char c) {
    switch (c) {
        case 'v': return "void";
        case 'b': return "bool";
        case 'g': return "byte";
        case 'h': return "ubyte";
        case 's': return "short";
        case 't': return "ushort";
        case 'i': return "int";
        case 'k': return "uint";
        case 'l': return "long";
        case 'm': return "ulong";
        case 'f': return "float";
        case 'd': return "double";
        case 'e': return "real";
        case 'a': return "char";
        case 'u': return "wchar";
        case 'w': return "dchar";
        default: return [c].idup;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Test lname
    assert(lname("foo") == "3foo");
    assert(lname("animals") == "7animals");
    
    // Test basic type mangling
    assert(mangleType("int") == "i");
    assert(mangleType("void") == "v");
    assert(mangleType("bool") == "b");
    
    // Test symbol mangling
    assert(mangleSymbol(["test"], "foo") == "_D4test3foo");
    assert(mangleSymbol(["animals", "dog"], "speak") == "_D7animals3dog5speak");
    
    // Test function mangling
    assert(mangleFunction(["test"], "foo", "int", []) == "_D4test3fooFZi");
    assert(mangleFunction(["test"], "bar", "int", ["int"]) == "_D4test3barFiZi");
    assert(mangleFunction(["test"], "baz", "void", ["int", "int"]) == "_D4test3bazFiiZv");
    
    // Test method mangling  
    assert(mangleMethod(["test"], "Dog", "speak", "int", []) == "_D4test3Dog5speakMFZi");
    
    // Test demangling
    assert(demangle("_D4test3fooFZi") == "test.foo() -> int");
    assert(demangle("_D7animals3dog5speakFZi") == "animals.dog.speak() -> int");
}
