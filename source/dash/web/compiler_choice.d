module dash.web.compiler_choice;

import std.algorithm : all, findSplit, splitter;
import std.array : empty;
import std.exception : enforce;

struct RevisionChoice {
    /// The type of the revision spec.
    enum Type {
        /// The current version. Additional info has no effect.
        current,

        /// A number of versions before the current. "previous" is eq. to
        /// "previous:1".
        previous,

        /// Days before the current date. "day" is eq. to "day:1".
        day,

        /// Weeks before the current date. "week" is eq. to "week:1".
        week,

        /// Months before the current date. "month" is eq. to "month:1".
        month,

        /// Years before the current date. "year" is eq. to "year:1".
        year,

        /// A specific timestamp, stored in info ("date" is eq. to "current").
        date
    }

    /// The main type part of the revision specifier.
    Type type;

    /// Choiceifies additional details, depending on the type.
    ///
    /// Guaranteed to only consist of hexadecimal number characters.
    string info;
}

struct CompilerChoice {
    string compilerName;
    string runConfigName;
    RevisionChoice revisionChoice;
}

RevisionChoice parseRevisionChoice(string specifier) {
    import std.ascii;
    import std.conv;
    typeof(return) result;

    auto parts = specifier.findSplit(":");
    result.type = parts[0].to!(RevisionChoice.Type);

    enforce(parts[2].all!(a => a.isHexDigit), "Invalid revision spec info.");
    result.info = parts[2];

    return result;
}

CompilerChoice parseCompilerChoice(string specifier) {
    import dash.util;

    typeof(return) result;

    auto nameParts = specifier.findSplit(":");
    {
        auto n = nameParts[0];
        enforce(!n.empty, "Expected compiler name followed by ':'.");
        enforce(n.isValidName, "Compiler name invalid.");
        result.compilerName = n;
    }

    auto runConfigParts = nameParts[2].findSplit("@");
    {
        auto r = runConfigParts[0];
        enforce(!r.empty, "Expected run config name followed by '@'.");
        enforce(r.isValidName, "Run config name invalid.");
        result.runConfigName = r;
    }

    result.revisionChoice = parseRevisionChoice(runConfigParts[2]);

    return result;
}

CompilerChoice[2] parseComparisonChoice(string specifier) {
    typeof(return) result;

    auto parts = splitter(specifier, "..");
    foreach (i; 0 .. 2) {
        enforce(!parts.empty, "Expected two parts delimited by '..'.");
        result[i] = parseCompilerChoice(parts.front);
        parts.popFront();
    }
    enforce(parts.empty, "Comparison spec had extra parts.");

    return result;
}

void write(R)(RevisionChoice c, R r) {
    import std.format;
    r.formattedWrite("%s", c.type);
    if (!c.info.empty) {
        r.put(":");
        r.put(c.info);
    }
}

void write(R)(CompilerChoice c, R r) {
    r.put(c.compilerName);
    r.put(":");
    r.put(c.runConfigName);
    r.put("@");
    write(c.revisionChoice, r);
}

void write(R)(in ref CompilerChoice[2] c, R r) {
    write(c[0], r);
    r.put("..");
    write(c[1], r);
}
