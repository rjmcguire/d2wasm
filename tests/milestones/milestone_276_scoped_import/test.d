// Milestone 276: Scoped import — import inside function body
// In D, scoped imports restrict visibility to the enclosing scope.

int main() {
    import helper : add;
    return add(35, 7);  // 42
}
