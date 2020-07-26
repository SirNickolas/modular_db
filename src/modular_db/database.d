module modular_db.database;

public import d2sqlite3;

@system:

struct Transaction {
    private {
        d2sqlite3.Database _db;
        bool _nested;
    }

    package this(d2sqlite3.Database db, bool nested) {
        db.execute(nested ? "SAVEPOINT _modular_db_save" : "BEGIN");
        _db = db;
        _nested = nested;
    }

    @disable this(this);

    ~this() {
        if (_db !is d2sqlite3.Database.init)
            _db.execute(_nested ? "ROLLBACK TO _modular_db_save" : "ROLLBACK");
    }

    @property bool nested() const nothrow pure @safe @nogc {
        return _nested;
    }

    void commit()
    in {
        assert(_db !is d2sqlite3.Database.init, "Attempting to commit a closed transaction");
    }
    do {
        _db.execute(_nested ? "RELEASE _modular_db_save" : "COMMIT");
        _db = d2sqlite3.Database.init;
    }
}

// N.B.: Make it ref-counted if adding extra fields.
struct Database {
    d2sqlite3.Database raw;

    alias raw this;

    @property bool inTransaction() nothrow
    in {
        assert(raw.handle !is null, "Attempting to query transaction status in a closed database");
    }
    do {
        import d2sqlite3.sqlite3;

        return !sqlite3_get_autocommit(raw.handle);
    }

    Transaction startTransaction()
    in {
        assert(raw.handle !is null, "Attempting to start a transaction in a closed database");
    }
    do {
        return Transaction(raw, inTransaction);
    }
}
