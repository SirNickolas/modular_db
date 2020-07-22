module modular_db.module_;

import modular_db.database;
import modular_db.module_qualification;
import modular_db.utils: _hasReadOnlyProperty;

enum isModule(M) =
    _hasReadOnlyProperty!(M, Database, q{database}) &&
    _hasReadOnlyProperty!(M, ModuleQualification, q{qualification});

template moduleFields() {
nothrow @safe:
    import modular_db.database: Database;
    import modular_db.module_qualification: ModuleQualification;

    private {
        Database _db;
        ModuleQualification _q;
    }

    static if (__traits(compiles, (ref Database db) pure @system @nogc => db)) // 2.081+
        @property inout(Database) database() inout pure @system @nogc { return _db; }
    else
        @property inout(Database) database() inout @system { return _db; }

    @property ModuleQualification qualification() const pure @nogc { return _q; }
}

alias ModuleLoaderModuleType(L) = typeof({
    Database db;
    L loader;
    const L constLoader;

    const char[ ] url = constLoader.url;
    long version_ = constLoader.version_;
    static assert(!is(typeof(constLoader.version_): int), "`version_` must have type `long`");

    alias M = typeof(loader.load(db, ModuleQualification.init));
    static assert(is(M == typeof(loader.setup(db, ModuleQualification.init))));
    static assert(is(M == typeof(loader.migrate(db, ModuleQualification.init, 1L))));
    static assert(isModule!M);
    return M.init;
}());

enum isModuleLoader(L) = is(ModuleLoaderModuleType!L);
