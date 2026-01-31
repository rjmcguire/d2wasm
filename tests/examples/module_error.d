/**
 * Module Error Example
 * 
 * This file should be rejected by the feature validator
 * because it uses the module system (import statements).
 */

module math.calculator;

import std.stdio;        // ERROR: imports not supported
import std.algorithm;    // ERROR: imports not supported
import std.range;        // ERROR: imports not supported

class Calculator {
    private int[] history;
    
    int add(int a, int b) {
        int result = a + b;
        history ~= result;
        return result;
    }
    
    void printHistory() {
        writeln("History:");           // ERROR: std.stdio not available
        foreach(val; history) {
            writeln("  ", val);        // ERROR: std.stdio not available
        }
    }
}

int main() {
    auto calc = new Calculator();    // ERROR: GC allocation
    
    int result = calc.add(10, 20);
    calc.printHistory();
    
    return result;
}