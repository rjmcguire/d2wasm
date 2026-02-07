module tests.test_mangle;

import codegen.mangle;

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
