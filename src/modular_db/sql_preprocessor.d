module modular_db.sql_preprocessor;

// This file contains simplified SQLite's lexer, patched for our needs.
// Original one can be viewed here:
// https://www.sqlite.org/src/artifact?ci=trunk&filename=src/tokenize.c
// Known bugs:
// * Tcl-style parameters can be parsed incorrectly: https://www.sqlite.org/lang_expr.html#varparam

import std.algorithm.comparison: among;
import std.array: Appender;
import std.typecons: Tuple;
import std.utf: byCodeUnit;

private pure @safe:

alias _ByteString = typeof("".byCodeUnit!(const(char)[ ]));

public enum SqlPreprocessorOptions {
    none,
    quoteLowercaseIdents = 0x1,
    quoteUppercaseIdents = 0x2,
    dedent               = 0x4,
    stripComments        = 0x8,
}

bool _isLineBreak(char c) nothrow @nogc {
    return c == '\n';
}

bool _isSpace(char c) nothrow @nogc {
    return !!c.among!(' ', '\t', '\r', '\f');
}

bool _isDigit(char c) nothrow @nogc {
    return c - '0' < 10u;
}

bool _isLower(char c) nothrow @nogc {
    return c - 'a' < 26u;
}

bool _isUpper(char c) nothrow @nogc {
    return c - 'A' < 26u;
}

bool _isIdentStartNotLower(char c) nothrow @nogc {
    return c - 'A' < 26u || c.among!('_', ':', '@', '$', '#') || c & 0x80;
}

bool _isIdentStartNotUpper(char c) nothrow @nogc {
    return c - 'a' < 26u || c.among!('_', ':', '@', '$', '#') || c & 0x80;
}

bool _isIdent(char c) nothrow @nogc {
    return (c | 0x20) - 'a' < 26u || c - '0' < 10u || c == '_' || c == '$' || c & 0x80;
}

bool _isStringStart(char c) nothrow @nogc {
    return c == '\'' || c == '"' || c == '`';
}

const(char)[ ] _parseQualifier(ref _ByteString s) {
    // - | [1-9] \d* | (?!0)
    if (s.empty)
        return null;
    switch (s.front) {
    case '-':
        s.popFront();
        return "-";

    case '1': .. case '9':
        const tmp = s.source;
        s._skipWhile!_isDigit();
        return tmp[0 .. $ - s.length];

    case '0':
        throw new Exception("Can't qualify an identifier with 0");

    default:
        return null;
    }
}

Tuple!(const(char)[ ], q{schema}, const(char)[ ], q{moduleId})
_parseQualifiers(ref _ByteString s) {
    import std.algorithm.searching: skipOver;
    import std.conv: text;
    import std.range: empty;

    /+
        (?:
            (?&qualifier) \.
        )?
        (?:
            (?&qualifier) \|
        |   (?![\d-])
        )
    +/
    const q0 = _parseQualifier(s);
    if (!s.empty)
        switch (s.front) {
        case '|':
            s.popFront();
            return typeof(return)(null, q0);

        case '.':
            s.popFront();
            const q1 = _parseQualifier(s);
            if (s.skipOver('|') || q1.empty)
                return typeof(return)(q0, q1);
            throw new Exception(text("Invalid qualifier: expected '|' after '", q0, '.', q1, '\''));

        default:
            break;
        }
    if (q0.empty)
        return typeof(return).init;
    throw new Exception(text("Invalid qualifier: expected '|' after '", q0, '\''));
}

char _skipWhile(alias pred)(ref _ByteString _s) nothrow @nogc {
    auto s = _s;
    scope(success) _s = s;
    char c;
    do
        s.popFront();
    while (!s.empty && pred((c = s.front)));
    return c;
}

alias _skipIdent = _skipWhile!_isIdent;
alias _skipAnyWhitespace = _skipWhile!(c => _isSpace(c) || _isLineBreak(c));

_ByteString _copyBracketedIdent(_ByteString s, Appender!string app) {
    import std.exception: enforce;

    auto lag = s;
    // Copy everything until ']', escaping quotation marks in the process.
    while (true) {
        enforce(!s.empty, "Unclosed square bracket");
        const c = s.front;
        s.popFront();
        if (c == ']')
            break;
        if (c == '"') {
            app ~= lag.source[0 .. $ - s.length];
            app ~= '"';
            lag = s;
        } else
            enforce(!_isLineBreak(c), "Unclosed square bracket");
    }
    app ~= lag.source[0 .. $ - s.length - 1];
    return s;
}

_ByteString _skipPlaceholder(_ByteString s) /+nothrow+/ {
    import std.format: FormatException, FormatSpec;
    import std.range: NullSink, dropOne;

    if (s[1] == '%') // "%%"
        return s[2 .. $];
    auto fmt = FormatSpec!char(s.source);
    NullSink sink;
    try {
        const specFound = fmt.writeUpToNextSpec(sink);
        assert(specFound);
    } catch (FormatException)
        return s.dropOne(); // Skip '%'.
    // catch (Exception e)
    //     assert(false, e.msg);
    return s[$ - fmt.trailing.length .. $];
}

bool _skipSingleLineComment(bool prepareToStrip)(ref _ByteString _s) nothrow @nogc {
    auto s = _s;
    scope(success) _s = s;
    static if (prepareToStrip)
        bool allowedToStrip = true;
    for (s = s[2 .. $]; !s.empty; s.popFront()) {
        const c = s.front;
        if (_isLineBreak(c)) {
            static if (prepareToStrip)
                return allowedToStrip;
            else
                return false;
        }
        static if (prepareToStrip)
            if (c == '%')
                allowedToStrip = false;
    }
    return false; // Must not strip a comment on the last line.
}

bool _skipMultiLineComment(bool prepareToStrip)(ref _ByteString _s) nothrow @nogc {
    auto s = _s;
    scope(success) _s = s;
    static if (prepareToStrip)
        bool allowedToStrip = true;
    bool prevStar;
    s = s[2 .. $];
    while (!s.empty) {
        const c = s.front;
        s.popFront();
        if (prevStar && c == '/') {
            static if (prepareToStrip)
                return allowedToStrip;
            else
                return false;
        }
        prevStar = c == '*';
        static if (prepareToStrip)
            if (c == '%')
                allowedToStrip = false;
    }
    return false; // Must not strip an unclosed comment.
}

public Tuple!(string, q{sql}, bool, q{usesSchema}, bool, q{usesModuleId})
preprocessSql(SqlPreprocessorOptions options)(const(char)[ ] sql, size_t firstAvailableArg) {
    import std.array: appender;
    import std.conv: toChars;
    import std.range: empty;

    if (sql.empty)
        return typeof(return).init;
    auto app = appender!string();
    auto s = sql.byCodeUnit();
    auto schemaDefaultIndex = toChars(firstAvailableArg);
    auto moduleIdDefaultIndex = toChars(firstAvailableArg + 1);
    bool usesSchema;
    bool usesModuleId;
    char c = s.front;

    static if (options & SqlPreprocessorOptions.quoteLowercaseIdents) {
        static assert(!(options & SqlPreprocessorOptions.quoteUppercaseIdents),
            "Cannot set both `quoteLowercaseIdents` and `quoteUppercaseIdents`",
        );
        enum shouldQuote = true;
        alias isIdentStart = _isLower;
        alias isKeywordStart = _isIdentStartNotLower;
        enum charX = 'x';
    } else static if (options & SqlPreprocessorOptions.quoteUppercaseIdents) {
        enum shouldQuote = true;
        alias isIdentStart = _isUpper;
        alias isKeywordStart = _isIdentStartNotUpper;
        enum charX = 'X';
    } else
        enum shouldQuote = false;
    enum shouldDedent = !!(options & SqlPreprocessorOptions.dedent);
    enum shouldStripComments = !!(options & SqlPreprocessorOptions.stripComments);

    static if (shouldDedent)
        if (_isSpace(c)) {
            const crlf = c == '\r' && s.length >= 2 && s[1] == '\n';
            const nonSpace = s._skipAnyWhitespace();
            // Retain one space at the beginning of the string.
            if (s.empty)
                return typeof(return)(crlf ? "\r\n" : [immutable char(c)], false, false);
            if (crlf)
                app ~= "\r\n";
            else
                app ~= c;
            c = nonSpace;
        }
    auto lag = s;
mainLoop:
    while (true) {
        assert(!s.empty, "Stepped inside the main parsing loop with an empty string");
        static if (shouldQuote) {
            // Keyword or named parameter.
            if (isKeywordStart(c)) {
                c = s._skipIdent();
                if (s.empty)
                    break mainLoop;
                continue mainLoop;
            }
            // Identifier.
            if (isIdentStart(c)) {
                if (c == charX && s.length >= 2 && (c = s[1]) == '\'') {
                    // Wait, it's a blob string.
                    s.popFront();
                    goto someString;
                }
                app ~= lag.source[0 .. $ - s.length];
                app ~= '"';
                lag = s;
                c = s._skipIdent();
                app ~= lag.source[0 .. $ - s.length];
                app ~= '"';
                lag = s;
                if (s.empty)
                    break mainLoop;
                continue mainLoop;
            }
        }
        // Line break.
        static if (shouldDedent)
            if (_isLineBreak(c)) {
            lineBreak:
                s.popFront();
                if (s.empty)
                    break mainLoop;
                c = s.front;
                if (_isSpace(c) || _isLineBreak(c)) {
                    // The following line is indented.
                    app ~= lag.source[0 .. $ - s.length];
                    c = s._skipAnyWhitespace();
                    lag = s;
                    if (s.empty)
                        break mainLoop;
                }
                continue mainLoop;
            }
        // Qualified name.
        if (c == '[') {
            app ~= lag.source[0 .. $ - s.length];
            s.popFront();

            const q = _parseQualifiers(s);
            if (q.schema != "-") {
                app ~= `"%`;
                if (q.schema.empty) {
                    app ~= schemaDefaultIndex;
                    usesSchema = true;
                } else
                    app ~= q.schema;
                app ~= `$s".`;
            }
            if (q.moduleId != "-") {
                app ~= `"%`;
                if (q.moduleId.empty) {
                    app ~= moduleIdDefaultIndex;
                    usesModuleId = true;
                } else
                    app ~= q.moduleId;
                app ~= `$s`;
            } else
                app ~= '"';

            lag = s = _copyBracketedIdent(s, app);
            app ~= '"';
            if (s.empty)
                break mainLoop;
            c = s.front;
            continue mainLoop;
        }
        // Some kind of strings.
        if (_isStringStart(c)) {
        someString:
            const delim = c;
            while (true) {
                s.popFront();
                if (s.empty)
                    break mainLoop;
                c = s.front;
                if (c == delim) {
                    s.popFront();
                    if (s.empty)
                        break mainLoop;
                    c = s.front;
                    if (c != delim) // Escaped delimiter.
                        continue mainLoop;
                }
            }
        }
        static if (shouldQuote) {
            // Number.
            if (_isDigit(c)) {
                // Must parse `1.e2` as a single token.
                c = s._skipWhile!(c => _isIdent(c) || c == '.');
                if (s.empty)
                    break mainLoop;
                continue mainLoop;
            }
            // Printf placeholder (must not quote letters in it).
            if (c == '%' && s.length >= 2) {
                s = s._skipPlaceholder();
                if (s.empty)
                    break mainLoop;
                c = s.front;
                continue mainLoop;
            }
        }
        // Single-line comment.
        if (c == '-' && s.length >= 2 && s[1] == '-') {
            static if (shouldStripComments) {
                const commentStart = s.length;
                if (s._skipSingleLineComment!true()) {
                    app ~= lag.source[0 .. $ - commentStart];
                    lag = s;
                }
            } else
                s._skipSingleLineComment!false();
            static if (shouldDedent)
                goto lineBreak; // Careful: we have a wrong value of `c` at the moment.
            else {
                c = '\n';
                continue mainLoop;
            }
        }
        // Multi-line comment.
        if (c == '/' && s.length >= 2 && s[1] == '*') {
            static if (shouldStripComments) {
                const commentStart = s.length;
                if (s._skipMultiLineComment!true()) {
                    app ~= lag.source[0 .. $ - commentStart];
                    app ~= ' '; // Comments can delimit tokens.
                    lag = s;
                }
            } else
                s._skipMultiLineComment!false();
            if (s.empty)
                break mainLoop;
            c = s.front;
            continue mainLoop;
        }
        // Some other character.
        s.popFront();
        if (s.empty)
            break mainLoop;
        c = s.front;
    }
    app ~= lag.source;
    return typeof(return)(app.data, usesSchema, usesModuleId);
}
