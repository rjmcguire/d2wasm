// EXPECTED: 5
int main() {
    int x = 1;
    { int x = 2;
      { int x = 3;
        { int x = 4;
          { int x = 5;
            __writeln(x);
          }
        }
      }
    }
    return 0;
}
