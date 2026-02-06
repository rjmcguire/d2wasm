// Demo 3: Mixin DSL
// Generate getter/setter boilerplate at compile time using string mixins

// This function generates property getter/setter code as a string
string generateProperty(string name) {
    return 
        "int _" ~ name ~ ";" ~
        "int get_" ~ name ~ "() { return _" ~ name ~ "; }" ~
        "void set_" ~ name ~ "(int v) { _" ~ name ~ " = v; }";
}

// Generate x and y properties at compile time
mixin(generateProperty("x"));
mixin(generateProperty("y"));

// The above expands to:
//   int _x;
//   int get_x() { return _x; }
//   void set_x(int v) { _x = v; }
//   int _y;
//   int get_y() { return _y; }
//   void set_y(int v) { _y = v; }

int main() {
    set_x(10);
    set_y(20);
    return get_x() + get_y();  // Should return 30
}
