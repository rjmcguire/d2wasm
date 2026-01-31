import std.stdio;
import parser.tree_sitter_c;

int main() {
    try {
        writeln("Creating TreeSitterParser...");
        auto parser = new TreeSitterParser();
        
        writeln("Parsing simple D code...");
        auto root = parser.parseString("int main() { return 42; }");
        
        writeln("Root node type: ", TreeSitterParser.getNodeType(root));
        writeln("Root node valid: ", TreeSitterParser.isValid(root));
        writeln("Root node has error: ", TreeSitterParser.hasError(root));
        writeln("Root node child count: ", TreeSitterParser.getChildCount(root));
        
        return 0;
    } catch (Exception e) {
        writeln("Error: ", e.msg);
        return 1;
    }
}