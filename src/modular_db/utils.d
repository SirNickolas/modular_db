module modular_db.utils;

package:

string _format(alias fmt, Args...)(Args args) nothrow {
    import std.format: format;

    try
        return format!fmt(args);
    catch (Exception e)
        assert(false, e.msg);
}

enum _hasReadOnlyProperty(T, P, string name) = __traits(compiles, (ref T t, ref const T constT) {
    const P member = __traits(getMember, constT, name);
    static assert(!__traits(compiles, __traits(getMember, t, name) = P.init));
});
