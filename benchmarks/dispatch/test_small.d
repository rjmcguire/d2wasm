// Auto-generated class hierarchy for dispatch benchmarking
// Branching factor: 3
// Max depth: 2

class Base {
    int getValue() { return -1; }
}

class D1_0 : Base {
    override int getValue() { return 10000; }
}
class D1_1 : Base {
    override int getValue() { return 10001; }
}
class D1_2 : Base {
    override int getValue() { return 10002; }
}

class D2_00 : D1_0 {
    override int getValue() { return 20000; }
}
class D2_01 : D1_0 {
    override int getValue() { return 20001; }
}
class D2_02 : D1_0 {
    override int getValue() { return 20002; }
}
class D2_10 : D1_1 {
    override int getValue() { return 20003; }
}
class D2_11 : D1_1 {
    override int getValue() { return 20004; }
}
class D2_12 : D1_1 {
    override int getValue() { return 20005; }
}
class D2_20 : D1_2 {
    override int getValue() { return 20006; }
}
class D2_21 : D1_2 {
    override int getValue() { return 20007; }
}
class D2_22 : D1_2 {
    override int getValue() { return 20008; }
}

// Factory to create instance by type ID
Base createByTypeId(int typeId) {
    switch (typeId) {
        case 0: return new D1_0();
        case 1: return new D1_1();
        case 2: return new D1_2();
        case 3: return new D2_00();
        case 4: return new D2_01();
        case 5: return new D2_02();
        case 6: return new D2_10();
        case 7: return new D2_11();
        case 8: return new D2_12();
        case 9: return new D2_20();
        case 10: return new D2_21();
        case 11: return new D2_22();
        default: return new Base();
    }
}

enum TOTAL_TYPES = 12;

/*
 * Hierarchy summary:
 *   Depth 0: 1 classes
 *   Depth 1: 3 classes
 *   Depth 2: 9 classes
 *   Total: 12 classes (excluding Base)
 */
