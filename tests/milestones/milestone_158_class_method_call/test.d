/**
 * Milestone 158: Class Method Calls
 * 
 * Tests calling methods on class instances.
 * Currently uses direct calls (type is statically known).
 * Virtual dispatch (call_indirect) is TODO.
 */
module test.class_method_call;

class Counter {
    int value;
    
    int get() {
        return 42;  // Simple return, no field access yet
    }
    
    int add(int x) {
        return x + 10;
    }
}

class Dog {
    int age;
    
    int bark() {
        return 100;
    }
    
    int barkTimes(int n) {
        return n * 10;
    }
}

int testSimpleMethod() {
    Counter c;
    return c.get();  // 42
}

int testMethodWithArg() {
    Counter c;
    return c.add(5);  // 15
}

int testDogMethod() {
    Dog d;
    return d.bark() + d.barkTimes(3);  // 100 + 30 = 130
}

int main() {
    return testSimpleMethod() + testMethodWithArg() + testDogMethod();
    // 42 + 15 + 130 = 187
}
