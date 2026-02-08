/**
 * Milestone 160: Parse Inheritance
 * 
 * Tests parsing of `class Dog : Animal` syntax.
 * At this milestone, inheritance is parsed but derived classes
 * don't yet inherit base class fields or methods.
 */
module test.parse_inheritance;

class Animal {
    int age;
    
    int getAge() {
        return 5;
    }
}

class Dog : Animal {
    int barkCount;
    
    int getBarkCount() {
        return 3;
    }
}

// For now, just test that Dog compiles and its own methods work
int testDogMethods() {
    Dog d;
    d.barkCount = 10;
    return d.barkCount + d.getBarkCount();  // 10 + 3 = 13
}

int main() {
    return testDogMethods();  // 13
}
