module dash.util;

import std.traits;

bool isValidName(string name) {
    import std.algorithm, std.ascii;
    return !name.canFind!(a => !(a.isAlphaNum || a == '_'));
}

string enforceValidName(string name) {
    if (!isValidName(name)) {
        throw new Exception("'" ~ name ~  "' is not a valid name.");
    }
    return name;
}
