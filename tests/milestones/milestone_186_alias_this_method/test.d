// Test alias this method call forwarding

struct Engine {
    int power;

    int getPower() {
        return power;
    }
}

struct Car {
    Engine engine;
    alias engine this;
}

int main() {
    Car c = Car(Engine(42));
    return c.getPower();  // forwarded to c.engine.getPower() = 42
}
