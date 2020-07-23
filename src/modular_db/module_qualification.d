module modular_db.module_qualification;

import modular_db.sql_preprocessor;

nothrow pure @safe:

struct ModuleQualification {
nothrow pure:
    private string _schema, _escapedSchema;
    package long _id = -1;

    @property const @nogc {
        string schema() { return _schema; }
        string escapedSchema() { return _escapedSchema; }
        long id() { return _id; }
    }

    this(string schema, long id) {
        import std.array: replace;

        _schema = schema;
        _escapedSchema = schema.replace(`"`, `""`);
        _id = id;
    }
}

string format(
    string fmt,
    SqlPreprocessorOptions options =
        SqlPreprocessorOptions.quoteLowercaseIdents |
        SqlPreprocessorOptions.dedent |
        SqlPreprocessorOptions.stripComments,
    Args...
)(ModuleQualification q, Args args) {
    import modular_db.utils: _format;

    enum result = preprocessSql!options(fmt, args.length + 1);
    static if (result.usesModuleId)
        return _format!(result.sql)(args, q.escapedSchema, q.id);
    else static if (result.usesSchema)
        return _format!(result.sql)(args, q.escapedSchema);
    else
        return _format!(result.sql)(args);
}
