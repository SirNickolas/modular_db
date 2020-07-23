import moddb = modular_db: ModuleQualification, format;

@system:

// Module type, which should conform to `modular_db.isModule` structural interface.
struct CountriesMod {
    // The easiest way to implement it is to mix required members in.
    mixin moddb.moduleFields;
}

struct CountriesModLoader {
    // Note: No member of this struct is required to be compile-time-accessible or static,
    // though it certainly won't harm.

    // A string to uniquely identify this module. The library does not fetch the resource it
    // points to nor even checks that it is a valid URI. It serves the same purpose as, e.g., URI
    // in an XML schema. However, it is a good idea to host some documentation at that address.
    enum url = "https://sirnickolas.github.io/modular_db/examples/basic/countries";

    // Module's version as a positive integral number.
    enum version_ = 3L;

    // The database (attached to the connection with schema `q.schema`) already has our module,
    // upgraded to the latest version, and it has ID `q.id` there. We need to construct and return
    // a _module object_.
    static CountriesMod load(moddb.Database db, ModuleQualification q) {
        return CountriesMod(db, q);
    }

    // Our module is not present in the database. We are asked to add it there. We should use
    // ID `q.id` for it.
    static CountriesMod setup(moddb.Database db, ModuleQualification q) {
        db.run(q.format!`
            -- If you enclose an identifier in square brackets, schema name and module ID will be
            -- prepended to it. E.g., [countries] might produce "main"."1countries".
            CREATE TABLE [countries](
                -- Each your table must have an INTEGER PRIMARY KEY (i.e., alias for the rowid).
                oid INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                area REAL CHECK(area > 0)
            );
            -- [-.identifier] syntax prepends only module ID but not schema name.
            CREATE INDEX [countries_area_idx] ON [-.countries](area);
        `);
        return CountriesMod(db, q);
    }

    // The database has our module (its ID is `q.id`), but it is outdated. We must do whatever
    // is needed to update it to our current `version_`.
    static CountriesMod migrate(moddb.Database db, ModuleQualification q, long fromVersion) {
        final switch (fromVersion) {
        case 1L:
            db.execute(q.format!`ALTER TABLE [countries] ADD COLUMN area REAL CHECK(area > 0)`);
            goto case;

        case 2L:
            db.execute(q.format!`CREATE INDEX [countries_area_idx] ON [-.countries](area)`);
        }
        return CountriesMod(db, q);
    }
}

struct CitiesMod {
    mixin moddb.moduleFields;
}

struct CitiesModLoader {
    enum url = "https://sirnickolas.github.io/modular_db/examples/basic/cities";
    enum version_ = 1L;

    static CitiesMod load(moddb.Database db, ModuleQualification q) {
        return CitiesMod(db, q);
    }

    static CitiesMod setup(moddb.Database db, ModuleQualification q) {
        // Get ID of the module we depend on.
        const long cntId = moddb.getModuleId(db, q, CountriesModLoader.url);
        db.run(q.format!`
            CREATE TABLE [cities](
                oid INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                -- [1|countries] prepends schema name and uses the value of the 1st argument
                -- as a module ID. [-.1|countries] does not prepend schema name.
                country_id INTEGER NOT NULL REFERENCES [-.1|countries] ON UPDATE CASCADE
            );
            CREATE INDEX [cities_country_idx] ON [-.cities](country_id);
            CREATE TABLE [capitals](
                -- Every foreign key definition must have "ON UPDATE CASCADE" clause.
                city_id INTEGER PRIMARY KEY REFERENCES [-.cities] ON UPDATE CASCADE
            );
        `(cntId)); // Pass its ID so that we can make references to its tables.
        return CitiesMod(db, q);
    }

    static CitiesMod migrate(moddb.Database, ModuleQualification, long) {
        assert(false, "There are no previous versions");
    }
}

void main() {
    import std.stdio;

    static import d2sqlite3;

    auto db = moddb.Database(d2sqlite3.Database("db.sqlite3"));
    db.execute("PRAGMA foreign_keys = ON"); // They are disabled by default in SQLite.
    // A call to `modular_db.initialize` is required to, you guessed it, initialize the module
    // system for the given database. In particular, "module system" is just a regular module -
    // `modular_db.module_module.ModuleModule` - that gets installed into your database. It always
    // has ID of 0. You can rely on this fact if you need to interact with its tables.
    //
    // If you ATTACH more DATABASEs to your connection, you have to initialize each one, passing
    // schema name as the third parameter.
    //
    // There are three loading modes available:
    // * `modular_db.Mode.load` (default) - try to load the module if it is present in the DB, throw
    //   an exception if it is not or has a wrong version.
    // * `modular_db.Mode.setup` - try to load the module; if it is not present, install it; if it
    //   has a wrong version, throw an exception.
    // * `modular_db.Mode.migrate` - try to load the module, install it, or upgrade to current
    //   version. It can still throw an exception if the stored module happens to have a higher
    //   version than we consider the latest.
    moddb.initialize(db, moddb.Mode.migrate); // `migrate` affects only the system, not our modules.
    // Because `initialize` just loads a particular module, everything said before is applicable
    // to `modular_db.loadModule` as well.
    CountriesMod cnt = moddb.loadModule!CountriesModLoader(db, moddb.Mode.setup);
    // More verbose way, which supports stateful loaders:
    CitiesModLoader bLoader;
    CitiesMod ct = moddb.loadModule(db, bLoader, moddb.Mode.setup);

    enum countryName = "Great Britain";
    d2sqlite3.ResultRange results = ct.database.execute(
        ct.qualification.format!`
            SELECT ct.name
            FROM [cities] ct
            JOIN [capitals] cap ON cap.city_id = ct.oid
            JOIN [1|countries] cnt ON cnt.oid = ct.country_id
            WHERE cnt.name = ?
        `(cnt.qualification.id),
        countryName,
    );
    if (!results.empty)
        writef!"%s is the capital of %s.\n"(results.oneValue!string(), countryName);
}
