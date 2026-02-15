int parseNumber(string s, int start, int end) {
    int result = 0;
    int i = start;
    while (i < end) {
        int c = s[i];
        result = result * 10 + (c - cast(int)'0');
        i = i + 1;
    }
    return result;
}

int csvSum(string input) {
    int sum = 0;
    int fieldStart = 0;
    int i = 0;
    while (i < input.length) {
        int c = input[i];
        if (c == cast(int)',' || c == cast(int)'\n') {
            sum = sum + parseNumber(input, fieldStart, i);
            fieldStart = i + 1;
        }
        i = i + 1;
    }
    // last field (no trailing delimiter)
    if (fieldStart < input.length)
        sum = sum + parseNumber(input, fieldStart, cast(int)input.length);
    return sum;
}

int test() {
    return csvSum("15,20,25,30,10,50");
    // 15+20+25+30+10+50 = 150
}

enum RESULT = test();
int main() { return RESULT; }
