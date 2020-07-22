module modular_db.actions;

import std.exception: enforce;

import modular_db.database;
import modular_db.exceptions;
import modular_db.module_;
import modular_db.module_qualification;

private @system:

public enum Mode: ubyte {
    load,
    setup,
    migrate,
}

ResultRange _queryModuleInfo(Database db, string sql, string moduleUrl) {
    try
        return db.execute(sql, moduleUrl);
    catch (SqliteException)
        throw new UninitializedDbException;
}

auto _loadModule(L)(Database db, ref L loader, Mode mode, ModuleQualification q) {
    const moduleUrl = loader.url;
    const moduleVersion = loader.version_;

    const nested = db.inTransaction;
    db.execute(nested ? "SAVEPOINT _modular_db_save" : "BEGIN");
    scope(failure) db.execute(nested ? "ROLLBACK TO _modular_db_save" : "ROLLBACK");
    scope(success) db.execute(nested ? "RELEASE _modular_db_save" : "COMMIT");
    auto moduleInfo = _queryModuleInfo(db, q.format!`
        SELECT oid, version
        FROM [-|0modules]
        WHERE url = ?
    `, moduleUrl);
    if (moduleInfo.empty) {
        // No such module yet.
        enforce(mode != Mode.load, new ModuleNotFoundException(moduleUrl));
        db.execute(q.format!`
            INSERT INTO [-|0modules](url, version)
            VALUES (?, ?)
        `, moduleUrl, moduleVersion);
        q._id = db.lastInsertRowid;
        return loader.setup(db, q);
    }
    // Module exists.
    const moduleId = moduleInfo.front.peek!long(0);
    const storedVersion = moduleInfo.front.peek!long(1);
    moduleInfo = typeof(moduleInfo).init;
    if (storedVersion == moduleVersion) {
        q._id = moduleId;
        return loader.load(db, q);
    }
    // Needs migration.
    enforce(mode == Mode.migrate && storedVersion < moduleVersion,
        new InvalidModuleVersionException(moduleUrl, moduleVersion, storedVersion),
    );
    db.execute(q.format!`
        UPDATE [-|0modules]
        SET version = ?
        WHERE oid = ?
    `, moduleVersion, moduleId);
    q._id = moduleId;
    return loader.migrate(db, q, storedVersion);
}

// We do not constrain these functions with `isModuleLoader!L`, so that we get better error
// messages.
public ModuleLoaderModuleType!L loadModule(L)(
    Database db, ref L loader, Mode mode = Mode.load, string schema = "main",
) {
    return _loadModule(db, loader, mode, ModuleQualification(schema, 0L));
}

public ModuleLoaderModuleType!L loadModule(L)(
    Database db, Mode mode = Mode.load, string schema = "main",
) {
    L loader;
    return loadModule(db, loader, mode, schema);
}

public void initialize(Database db, Mode mode = Mode.load, string schema = "main") {
    import modular_db.module_module;

    const q = ModuleQualification(schema, 0L);
    ModuleModuleLoader loader;
    if (mode == Mode.load)
        _loadModule(db, loader, mode, q);
    else
        try
            _loadModule(db, loader, mode, q);
        catch (UninitializedDbException) {
            const nested = db.inTransaction;
            db.execute(nested ? "SAVEPOINT _modular_db_save" : "BEGIN");
            scope(failure) db.execute(nested ? "ROLLBACK TO _modular_db_save" : "ROLLBACK");
            scope(success) db.execute(nested ? "RELEASE _modular_db_save" : "COMMIT");
            loader.setup(db, q);
        }
}

long _queryModuleId(Database db, ModuleQualification q, string moduleUrl) {
    auto moduleInfo = _queryModuleInfo(db, q.format!`
        SELECT oid
        FROM [-|0modules]
        WHERE url = ?
    `, moduleUrl);
    enforce(!moduleInfo.empty, new ModuleNotFoundException(moduleUrl));
    return moduleInfo.oneValue!long;
}

public void dropModule(Database db, string moduleUrl, string schema = "main") {
    import std.algorithm.iteration: map;
    import std.array: appender, array;
    import std.conv: toChars;
    import std.format: sformat;
    import std.typecons: tuple;

    import d2sqlite3.results: PeekMode;

    const q = ModuleQualification(schema, 0L);
    const moduleId = _queryModuleId(db, q, moduleUrl);

    const nested = db.inTransaction;
    const withForeignKeys = db.execute("PRAGMA foreign_keys").oneValue!bool;
    if (withForeignKeys) {
        enforce!DbException(!nested,
            "Cannot drop a module in a transaction with enabled `foreign_keys`",
        );
        db.execute("PRAGMA foreign_keys = OFF");
    }
    scope(exit)
        if (withForeignKeys)
            db.execute("PRAGMA foreign_keys = ON");
    db.execute(nested ? "SAVEPOINT _modular_db_save" : "BEGIN");
    scope(failure) db.execute(nested ? "ROLLBACK TO _modular_db_save" : "ROLLBACK");
    scope(success) db.execute(nested ? "RELEASE _modular_db_save" : "COMMIT");

    db.execute(q.format!`
        DELETE FROM [-|0modules]
        WHERE oid = ?
    `, moduleId);

    char[long.min.toChars().length + 7] buffer = void;
    auto name = appender!(char[ ]);
    name.reserve(32);
    foreach (entity;
        db.execute(
            q.format!`
                SELECT type, name
                FROM [-|sqlite_master]
                WHERE name GLOB ?
            `,
            buffer[ ].sformat!"%s[^0-9]*"(moduleId),
        ).map!((row) {
            name.clear();
            foreach (c; row.peek!(string, PeekMode.slice)(1))
                if (c != '"')
                    name ~= c;
                else
                    name ~= `""`;
            return tuple!(q{type}, q{name})(row.peek!string(0), name.data.idup);
        }).array()
    )
        db.execute(q.format!`DROP %1$s [-|%2$s]`(entity.type, entity.name));
}
