int test() {
    int total = 0;
    int _rt_idx = 0;
    while (_rt_idx < 10) {
        if (_rt_idx == 3) {
            _rt_idx = _rt_idx + 1;
            continue;
        }
        if (_rt_idx == 7) {
            break;
        }
        total = total + _rt_idx;
        _rt_idx = _rt_idx + 1;
    }
    return total;
}

enum RESULT = test();

int main() {
    return RESULT;
}
