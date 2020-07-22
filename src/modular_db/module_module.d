module modular_db.module_module;

import modular_db.database;
import modular_db.module_;
import modular_db.module_qualification;

@safe:

struct ModuleModule {
    mixin moduleFields;
}

struct ModuleModuleLoader {
    enum url = "https://github.com/SirNickolas/modular_db";
    enum version_ = 1L;

    static ModuleModule load(Database db, ModuleQualification q) nothrow @system
    in {
        assert(!q.id, "ID for the module module must be 0");
    }
    do {
        return ModuleModule(db, q);
    }

    static ModuleModule setup(Database db, ModuleQualification q) @system
    in {
        assert(!q.id, "ID for the module module must be 0");
    }
    do {
        // As a special case, `setup` for this module is called when there is no corresponding
        // entry in "0modules" table (in fact, the table itself has not been created yet).
        db.execute(q.format!`
            CREATE TABLE [-|0modules](
                oid INTEGER PRIMARY KEY,
                url TEXT NOT NULL UNIQUE,
                version INTEGER NOT NULL CHECK(version >= 1)
            )
        `);
        db.execute(q.format!`
            INSERT INTO [-|0modules]
            VALUES (0, ?, ?)
        `, url, version_);
        return ModuleModule(db, q);
    }

    static ModuleModule migrate(Database, ModuleQualification q, long) @system
    in {
        assert(!q.id, "ID for the module module must be 0");
    }
    do {
        assert(false, "There are no previous versions");
    }
}
