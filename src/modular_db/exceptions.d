module modular_db.exceptions;

import std.exception: basicExceptionCtors;

import modular_db.utils: _format;

@safe:

class DbException: Exception {
    mixin basicExceptionCtors;
}

class UninitializedDbException: DbException {
    this() nothrow pure @nogc {
        super("It is not a valid Modular DB");
    }
}

class ModuleNotFoundException: DbException {
    string url;

    this(string url, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    nothrow pure {
        const string[1] u = [url];
        super(_format!"Cannot find module %(%s%)"(u), file, line, next);
        this.url = url;
    }
}

class InvalidModuleVersionException: DbException {
    string url;
    long expected, found;

    this(
        string url, long expected, long found,
        string file = __FILE__, size_t line = __LINE__, Throwable next = null,
    ) nothrow pure {
        const string[1] u = [url];
        super(_format!"Wrong version of %(%s%): expected %s, found %s"(
            u, expected, found,
        ), file, line, next);
        this.url = url;
        this.expected = expected;
        this.found = found;
    }
}
