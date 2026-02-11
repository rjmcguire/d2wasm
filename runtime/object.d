// runtime/object.d — auto-imported before user code

bool stringEqual(string _rt_a, string _rt_b) {
    if (_rt_a.length != _rt_b.length) return false;
    int _rt_i = 0;
    while (_rt_i < _rt_a.length) {
        if (_rt_a[_rt_i] != _rt_b[_rt_i]) return false;
        _rt_i = _rt_i + 1;
    }
    return true;
}

int indexOf(string _rt_s, char _rt_c) {
    int _rt_i = 0;
    while (_rt_i < _rt_s.length) {
        if (_rt_s[_rt_i] == cast(int)_rt_c) return _rt_i;
        _rt_i = _rt_i + 1;
    }
    return -1;
}

int stringIndexOf(string _rt_haystack, string _rt_needle) {
    if (_rt_needle.length == 0) return 0;
    if (_rt_haystack.length < _rt_needle.length) return -1;
    int _rt_limit = _rt_haystack.length - _rt_needle.length + 1;
    int _rt_i = 0;
    while (_rt_i < _rt_limit) {
        bool _rt_match = true;
        int _rt_j = 0;
        while (_rt_j < _rt_needle.length) {
            if (_rt_haystack[_rt_i + _rt_j] != _rt_needle[_rt_j]) {
                _rt_match = false;
                _rt_j = _rt_needle.length;
            }
            _rt_j = _rt_j + 1;
        }
        if (_rt_match) return _rt_i;
        _rt_i = _rt_i + 1;
    }
    return -1;
}

bool isDigit(char _rt_c) {
    return cast(int)_rt_c >= 48 && cast(int)_rt_c <= 57;
}

bool isWhitespace(char _rt_c) {
    return cast(int)_rt_c == 32 || cast(int)_rt_c == 9 || cast(int)_rt_c == 10 || cast(int)_rt_c == 13;
}
