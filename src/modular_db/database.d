module modular_db.database;

public import d2sqlite3;

@system:

// N.B.: Make it ref-counted if adding extra fields.
struct Database {
    d2sqlite3.Database raw;

    alias raw this;

    @property bool inTransaction() nothrow
    in {
        assert(raw.handle !is null);
    }
    do {
        import d2sqlite3.sqlite3;

        return !sqlite3_get_autocommit(raw.handle);
    }
}
