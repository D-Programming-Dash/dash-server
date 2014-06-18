module dash.model.db;

import api = dash.api;

import std.datetime : SysTime;
import vibe.data.bson;

enum SourceType {
    githubBranch,
    githubBranches
}

struct VersionedSource {
    SourceType type;
    Bson config;
}

struct Compiler {
    string name;
    string description;
    VersionedSource source;
    api.CompilerType clientType;
    RunConfig[] runConfigs;
}

struct BenchmarkBundle {
    BsonObjectID _id;
    string name;
    VersionedSource source;
}

struct Machine {
    string name;
    string description;

    SysTime[string] timestamps;
}

struct RunConfig {
    string name;
    string description;

    api.Config[] config;

    /// Do not use this configuration for new builds anymore.
    bool inactive;

    /// Completely hide this configuration from the UI.
    bool hidden;
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
    string benchmarkBundleRevision;
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
