module dash.model.db;

import api = dash.api;

import std.datetime : SysTime;
import vibe.data.bson;

enum SourceType {
    githubBranch,
    githubBranches
}

/**
 * Configuration data for a dash.versioned_source.
 */
struct VersionedSource {
    SourceType type;
    Bson config;
}

/**
 * The global registration record for a compiler.
 *
 * No per-machine data.
 */
struct Compiler {
    /// Unique name, used to identify the compiler in the API and the
    /// user interface.
    string name;

    /// User-visible free-form description of the compiler.
    string description;

    /// Compiler source code location.
    VersionedSource source;

    /// The compiler type, as used by the client to determine how to handle
    /// building and invoking it.
    api.CompilerType clientType;

    RunConfig[] runConfigs;
}

/// ditto
struct RunConfig {
    string name;
    string description;

    api.Config[] config;

    /// Do not use this configuration for new builds anymore.
    bool inactive;

    /// Completely hide this configuration from the UI.
    bool hidden;
}

/**
 * The global registration record for a benchmark bundle.
 *
 * No per-machine data.
 */
struct BenchmarkBundle {
    BsonObjectID _id;

    /// Unique name, used to identify the bundle in the API and the user
    /// interface.
    string name;

    /// Source code location.
    VersionedSource source;
}

/**
 * The record for a machine, encapsulating both basic metadata (free-form
 * description, etc.) and its current state.
 *
 * The unique name field is used to idenfity the machine in the API.
 */
struct Machine {
    string name;

    /// User-visible free-form description of the machine (e.g. platform,
    /// hardware specs, etc.).
    string description;

    /// The timestamps of the latest VersionUpdates that have already been
    /// processed, i.e. had the benchmark tasks resulting from the respective
    /// update events enqueued.
    SysTime[string] lastEnqueued;

    /// The versioned_source version ids of the compilers currently installed
    /// on the machine.
    ///
    /// This model, of course, builds on the assumption that the client machine
    /// admin never intentionally messes up the state of the Dash working
    /// directory. Removing the compiler altogehter is fine, though, as the
    /// client will simply request the CompilerInfo from us and rebuild the
    /// compiler if it detects that it does not in fact exist. This is also how
    /// initial installation of a new compiler is handled.
    string[][string] currentVersionIds;
}


struct CompilerVersion {
    BsonObjectID _id;
    string name;

    import dash.versioned_source.base : VersionUpdate;
    VersionUpdate update;

    /// All benchmarks were run (resp. attempted to be run) for this compiler
    /// version, making it a sensible choice for date-based comparisons, etc.
    bool completed;
}

struct PendingBenchmark {
    BsonObjectID _id;
    BsonObjectID benchmarkBundleId;
    string benchmarkScmRevision;
    BsonObjectID compilerVersionId;
    string runConfigName;
    bool attempted;
}

struct Result {
    BsonObjectID _id;
    string name;
    BsonObjectID compilerVersionId;
    string runConfig;
    string benchmarkScmRevision;
    double[][string] samples;
    string[string] envData;
}

final class Database {
    import dash.util;
    import vibe.db.mongo.mongo;

    this(MongoDatabase db) {
        _db = db;
        _benchmarkBundles = _db["benchmarkBundles"];
        _benchmarkBundles.ensureIndex(["name": 1], IndexFlags.Unique);
        _compilers = _db["compilers"];
        _compilers.ensureIndex(["name": 1], IndexFlags.Unique);
        _machines = _db["machines"];
        _machines.ensureIndex(["name": 1], IndexFlags.Unique);
    }

    MongoCollection benchmarkBundles() {
        return _benchmarkBundles;
    }

    MongoCollection compilers() {
        return _compilers;
    }

    MongoCollection machines() {
        return _machines;
    }

    MongoCollection compilerVersions(string machineName) {
        if (auto existing = machineName in _compilerVersionsMap) {
            return *existing;
        }

        assert(isValidName(machineName));
        auto result = _db["compilerVersions." ~ machineName];
        result.ensureIndex(["name": 1]);
        return _compilerVersionsMap[machineName] = result;
    }

    MongoCollection pendingBenchmarks(string machineName) {
        if (auto existing = machineName in _pendingBenchmarksMap) {
            return *existing;
        }

        assert(isValidName(machineName));
        auto result = _db["pendingBenchmarks." ~ machineName];
        result.ensureIndex(["attempted": 1]);
        return _pendingBenchmarksMap[machineName] = result;
    }

    MongoCollection results(string machineName) {
        if (auto existing = machineName in _resultsMap) {
            return *existing;
        }

        assert(isValidName(machineName));
        auto result = _db["results." ~ machineName];
        result.ensureIndex(["name": 1]);
        return _resultsMap[machineName] = result;
    }

    auto runCommand(T...)(auto ref T args) {
        return _db.runCommand(args);
    }

private:
    MongoDatabase _db;
    MongoCollection _benchmarkBundles;
    MongoCollection _compilers;
    MongoCollection _machines;
    MongoCollection[string] _compilerVersionsMap;
    MongoCollection[string] _pendingBenchmarksMap;
    MongoCollection[string] _resultsMap;
}
