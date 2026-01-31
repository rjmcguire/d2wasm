/**
 * Structs and Classes Example
 * 
 * Demonstrates object-oriented features supported by the compiler:
 * - Struct definitions with methods
 * - Class definitions with inheritance
 * - Interface implementations
 * - Manual memory management
 */

struct Point {
    int x;
    int y;
    
    int distanceSquared() {
        return x * x + y * y;
    }
    
    void move(int dx, int dy) {
        x += dx;
        y += dy;
    }
}

interface Drawable {
    void draw();
}

class Rectangle : Drawable {
    Point topLeft;
    Point bottomRight;
    
    this(int x1, int y1, int x2, int y2) {
        topLeft.x = x1;
        topLeft.y = y1;
        bottomRight.x = x2;
        bottomRight.y = y2;
    }
    
    int area() {
        int width = bottomRight.x - topLeft.x;
        int height = bottomRight.y - topLeft.y;
        return width * height;
    }
    
    override void draw() {
        // Draw implementation would go here
    }
}

int main() {
    Point p;
    p.x = 3;
    p.y = 4;
    
    int distance = p.distanceSquared();
    
    Rectangle rect = Rectangle(0, 0, 10, 5);  // Stack allocation
    int rectArea = rect.area();
    
    return distance + rectArea;
}