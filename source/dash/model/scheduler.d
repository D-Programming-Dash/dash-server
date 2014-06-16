module dash.model.scheduler;

import api = dash.api;
import db = dash.model.db;

import dash.versioned_source;
import dash.util;
import std.algorithm : canFind, filter, map, sort;
import std.array;
import std.datetime : Clock, minutes;
import std.range : sequence, zip;
import std.string : format;
import std.typecons : tuple, Tuple;
import vibe.db.mongo.mongo;
import vibe.core.log;

class Scheduler {
    this(db.Database database) {
        _db = database;

        foreach (b; _db.benchmarkBundles.find().map!(a => a.deserializeBson!(db.BenchmarkBundle))) {
            registerVersionedArtifact(b.name, ArtifactType.benchmarkBundle,
                b.source.type, b.source.config);
        }

        foreach (c; _db.compilers.find().map!(a => a.deserializeBson!(db.Compiler))) {
            registerVersionedArtifact(c.name, ArtifactType.compiler,
                c.source.type, c.source.config);
        }

        runUpdateVersionedArtifactsTask();
    }

    void addMachine(string name, string description) {
        enforceValidName(name);
        enforce(_db.machines.findOne(["name": name], ["_id": true]).isNull(),
            "A machine with the same name is already registered.");

        auto machine = db.Machine(name, description);
        logInfo("Adding new machine: %s", machine);
        _db.machines.insert(machine);
    }

    void addBenchmarkBundle(string name, string sourceJson) {
        enforceValidName(name);
        enforce(_db.benchmarkBundles.findOne(["name": name], ["_id": true]).isNull(),
            "A benchmark bundle with the same name is already registered.");
        auto source = parseJson(sourceJson).deserializeJson!(db.VersionedSource);

        auto b = db.BenchmarkBundle(BsonObjectID.generate(), name, source);
        logInfo("Adding new benchmark bundle: %s", b);
        registerVersionedArtifact(name, ArtifactType.benchmarkBundle,
            b.source.type, b.source.config);
        _db.benchmarkBundles.insert(b);
    }

    void addCompiler(string name, string description, string sourceJson,
        api.CompilerType type
    ) {
        enforceValidName(name);
        enforce(_db.compilers.findOne(["name": name], ["_id": true]).isNull(),
            "A compiler with the same name is already registered.");
        auto source = parseJson(sourceJson).deserializeJson!(db.VersionedSource);
        auto compiler = db.Compiler(name, description, source, type);
        logInfo("Adding new compiler: %s", compiler);

        registerVersionedArtifact(name, ArtifactType.compiler,
            compiler.source.type, compiler.source.config);
        _db.compilers.insert(compiler);
    }

    void addRunConfig(string compilerName, string name, string description,
        api.Config[] config
    ) {
        enforceValidName(compilerName);
        enforceValidName(name);
        auto compiler = _db.compilers.findOne(["name" : compilerName],
            ["_id": true, "runConfigs": true]);
        enforce(!compiler.isNull, format(
            "Compiler '%s' not registered in configuration database.",
            compilerName
        ));

        enforce(!compiler.runConfigs.get!(Bson[]).map!(a => a["name"].get!string).canFind(name),
            format("A run config for '%s' with name '%s' already exists.", compilerName, name));

        db.RunConfig rc;
        rc.name = name;
        rc.description = description;
        rc.config = config;

        _db.compilers.update(["_id": compiler._id], ["$push": ["runConfigs" : rc]]);
    }

    api.CompilerInfo getCompilerInfo(string machineName, string compilerName) {
        enforceValidName(machineName);
        enforceValidName(compilerName);

        auto artifact = *enforce(compilerName in _versionedArtifacts,
            format("Compiler '%s' not registered in configuration database."));

        string[] versionIds = currentVersionIdsForMachine(machineName, compilerName);
        auto compiler = compilerByName(compilerName);

        if (!versionIds) {
            // Compiler not used on the machine, just install the latest one.
            versionIds = artifact.latestVersion.versionIds;
            return updateCompilerAtMachine(machineName, artifact, compiler, versionIds);
        }
        return makeCompilerInfo(artifact, compiler, versionIds);
    }

    api.Task nextTaskForMachine(string machineName) {
        enforceValidName(machineName);

        // Check whether there is still something in the queue for the machine.
        auto pendingBenchmarks = _db.pendingBenchmarks(machineName);
        auto compilerVersions = _db.compilerVersions(machineName);
        auto unattempted = pendingBenchmarks.findOne(["attempted": false]);
        if (!unattempted.isNull) {
            auto toExecute = unattempted.deserializeBson!(db.PendingBenchmark);
            auto compilerVersion = compilerVersions.
                findOne(["_id": toExecute.compilerVersionId]).
                deserializeBson!(db.CompilerVersion);

            // Check if we need to update the compiler on the target machine
            // before running the benchmark.
            auto currentVersionIds = currentVersionIdsForMachine(
                machineName, compilerVersion.name);
            auto targetVersionIds = compilerVersion.update.versionIds;
            if (currentVersionIds != targetVersionIds) {
                auto cut = updateCompilerAtMachine(
                    machineName,
                    _versionedArtifacts[compilerVersion.name],
                    compilerByName(compilerVersion.name),
                    targetVersionIds
                );
                api.Task t;
                t.set!"compilerUpdateTask"(cut);
                return t;
            }

            auto runConfigBson = _db.compilers.findOne(
                [
                    "name": serializeToBson(compilerVersion.name),
                    "runConfigs.name": serializeToBson(toExecute.runConfigName)
                ],
                ["runConfigs.$" : true]
            );
            auto runConfig = runConfigBson["runConfigs"][0].deserializeBson!(db.RunConfig);

            auto bundle = _db.benchmarkBundles.
                findOne(["_id" : toExecute.benchmarkBundleId]).
                deserializeBson!(db.BenchmarkBundle);
            auto artifact = _versionedArtifacts[bundle.name];

            api.BenchmarkTask bt;
            bt.id = toExecute._id.toString();
            enforce(artifact.source.baseUrls.length == 1,
                    "Benchmarks should be single-sourced.");
            bt.scmUrl = artifact.source.baseUrls[0];
            assert(!artifact.latestVersion.versionIds.empty,
                "Should have fetched current version on startup resp. when adding the artifact.");
            bt.scmRevision = artifact.latestVersion.versionIds[0];
            bt.config = runConfig.config;
            bt.config ~= api.Config(10, [
                "compiler": compilerVersion.name,
                "runConfig": runConfig.name // Informational.
            ]);

            auto updateSpec = ["$set": ([
                "attempted": true.serializeToBson,
                "benchmarkScmRevision": bt.scmRevision.serializeToBson
            ])];
            pendingBenchmarks.update(["_id": toExecute._id], updateSpec);

            api.Task t;
            t.set!"benchmarkTask"(bt);
            return t;
        }

        // Okay, nothing in the queue yet. See if we can push something new. We
        // only want to push are pure benchmark suite update if we can't also
        // combine it with a compiler version update.

        VersionedArtifact[] outOfDate;

        auto cur = _db.machines.findOne(["name": machineName], ["lastEnqueued": true]);
        enforce(!cur.isNull, format("Machine '%s' not registed in database.", machineName));
        SysTime[string] clientTimestamps;
        auto lastEnqueued = cur["lastEnqueued"];
        if (!lastEnqueued.isNull) deserializeBson(clientTimestamps, lastEnqueued);

        foreach (name, artifact; _versionedArtifacts) {
            auto ts = name in clientTimestamps;
            if (!ts || *ts < artifact.latestVersion.timestamp) {
                outOfDate ~= artifact;
            }
        }

        logDiagnostic("Out of date artifacts for '%s': %s", machineName, outOfDate);

        auto byTimestamp(ArtifactType type) {
            auto list = outOfDate.filter!(a => a.type == type).array;
            list.sort!((a, b) => a.latestVersion.timestamp < b.latestVersion.timestamp);
            return list;
        }

        void updateLastEnqueued(VersionedArtifact artifact) {
            auto updateSpec = ["$set": (["lastEnqueued." ~ artifact.name:
                artifact.latestVersion.timestamp])];
            _db.machines.update(["name": machineName], updateSpec);
        }

        foreach (artifact; byTimestamp(ArtifactType.compiler)) {
            auto compiler = compilerByName(artifact.name);

            auto compilerVersionId = BsonObjectID.generate;
            db.CompilerVersion compilerVersion;
            compilerVersion._id = compilerVersionId;
            compilerVersion.name = artifact.name;
            compilerVersion.update = artifact.latestVersion;
            compilerVersions.insert(compilerVersion);

            auto bundleIdsToRun = _versionedArtifacts.byValue.filter!(
                a => a.type == ArtifactType.benchmarkBundle
            ).map!(a => benchmarkBundleByName(a.name)._id).array;

            bool insertedOne = false;
            foreach (runConfig; compiler.runConfigs) {
                if (runConfig.inactive) continue;

                foreach (bundleId; bundleIdsToRun) {
                    db.PendingBenchmark pending;
                    pending._id = BsonObjectID.generate;
                    pending.compilerVersionId = compilerVersionId;
                    pending.runConfigName = runConfig.name;
                    pending.benchmarkBundleId = bundleId;
                    pendingBenchmarks.insert(pending);
                    insertedOne = true;
                }
            }

            updateLastEnqueued(artifact);

            // TODO: Replace this by loop to top.
            if (insertedOne) {
                return nextTaskForMachine(machineName);
            }

            // If there haven't acutally been any run configs, immediately set
            // the "done" flag, as we won't get around to doing this in a client
            // callback. Not that it would matter much – for optimization
            // purposes, it might even be better to leave it off entirely as
            // there will be no associated results to load anyway.
            markCompilerVersionDone(machineName, compilerVersionId);
        }

        foreach (artifact; byTimestamp(ArtifactType.benchmarkBundle)) {
            auto benchmark = benchmarkBundleByName(artifact.name);

            bool insertedOne = false;
            foreach (compiler; allCompilers) {
                auto latestVersion = _versionedArtifacts[compiler.name].latestVersion;
                auto compilerVersion = compilerVersions.findOne([
                    "name": serializeToBson(compiler.name),
                    "update": serializeToBson(latestVersion)
                ], ["_id": true]);
                enforce(!compilerVersion.isNull, format(
                    "Internal error: Could not find version '%s' for compiler " ~
                    "'%s', should have been previously inserted.",
                    latestVersion, compiler.name));

                auto compilerVersionId = compilerVersion["_id"].get!BsonObjectID;

                foreach (runConfig; compiler.runConfigs) {
                    if (runConfig.inactive) continue;

                    db.PendingBenchmark pending;
                    pending._id = BsonObjectID.generate;
                    pending.compilerVersionId = compilerVersionId;
                    pending.runConfigName = runConfig.name;
                    pending.benchmarkBundleId = benchmark._id;
                    pendingBenchmarks.insert(pending);

                    insertedOne = true;
                }
            }

            // TODO: Replace this by loop to top.
            if (insertedOne) return nextTaskForMachine(machineName);
        }

        // Nothing to do for the client.
        return api.Task.init;
    }

    void postResult(string machineName, api.BenchmarkResult apiResult) {
        import std.algorithm;
        import std.range;

        auto success = apiResult.tests.
            map!(a => a.phases).
            joiner.
            map!(a => a.exitCode).
            any!(a => a != 0);
        if (!success) return;
        // TODO: Actually log errors here.

        auto pendingId = BsonObjectID.fromString(apiResult.taskId);
        auto pending = pendingBenchmarkById(machineName, pendingId);

        foreach (test; apiResult.tests) {
            db.Result result;
            result._id = BsonObjectID.generate;
            result.name = apiResult.name ~ '.' ~ test.name;
            result.compilerVersionId = pending.compilerVersionId;
            result.benchmarkScmRevision = pending.benchmarkBundleRevision;
            foreach (phase; test.phases) {
                foreach (name, values; phase.resultSamples)
                result.samples[phase.name ~ '.' ~ name] = values;
            }
            result.envData = apiResult.testEnvData;
            _db.results(machineName).insert(result);
        }
        markPendingBenchmarkFinished(machineName, apiResult.taskId);
    }

private:
    auto allCompilers() {
        return _db.compilers.find().map!(a => a.deserializeBson!(db.Compiler));
    }

    db.Compiler compilerByName(string name) {
        auto res = _db.compilers.findOne(["name" : name]);
        enforce(!res.isNull, format(
            "Compiler '%s' not registered in configuration database.", name));
        return res.deserializeBson!(db.Compiler);
    }

    auto allBenchmarkBundles() {
        return _db.benchmarkBundles.find().map!(a => a.deserializeBson!(db.BenchmarkBundle));
    }

    db.BenchmarkBundle benchmarkBundleByName(string name) {
        auto res = _db.benchmarkBundles.findOne(["name" : name]);
        enforce(!res.isNull, format(
            "Benchmark '%s' not registered in configuration database.", name));
        return res.deserializeBson!(db.BenchmarkBundle);
    }

    db.PendingBenchmark pendingBenchmarkById(string machineName, BsonObjectID pendingId) {
        return _db.pendingBenchmarks(machineName).findOne(
            ["_id": pendingId]).deserializeBson!(db.PendingBenchmark);
    }

    void registerVersionedArtifact(string name, ArtifactType type,
        db.SourceType sourceType, Bson sourceConfig
    ) {
        auto artifact = new VersionedArtifact;
        artifact.name = name;
        artifact.type = type;

        artifact.source = createVersionedSource(sourceType, sourceConfig);
        artifact.updateLatestVersion();

        assert(name !in _versionedArtifacts);
        _versionedArtifacts[name] = artifact;
    }

    string[] currentVersionIdsForMachine(string machineName, string compilerName) {
        auto machineInfo = _db.machines.findOne(
            ["name": machineName],
            ["currentVersionIds." ~ compilerName: true]
        );
        auto currentIds = machineInfo["currentVersionIds"];
        if (currentIds.isNull()) return null;
        auto versionInfo = currentIds[compilerName];
        if (versionInfo.isNull()) return null;
        return versionInfo.deserializeBson!(string[]);
    }

    api.CompilerInfo updateCompilerAtMachine(string machineName,
        VersionedArtifact artifact, db.Compiler compiler, string[] versionIds
    ) {
        immutable versionKey = "currentVersionIds." ~ compiler.name;
        auto updateSpec = ["$set": ([versionKey: versionIds])];
        _db.machines.update(["name": machineName], updateSpec);

        return makeCompilerInfo(artifact, compiler, versionIds);
    }

    void markPendingBenchmarkFinished(string machineName, string taskId) {
        auto id = BsonObjectID.fromString(taskId);
        auto pending = _db.pendingBenchmarks(machineName);

        auto cmd = Bson.emptyObject;
        cmd["findAndModify"] = Bson(pending.name);
        cmd["query"] = serializeToBson(["_id": id]);
        cmd["remove"] = serializeToBson(true);
        cmd["fields"] = serializeToBson(["compilerVersionId": 1]);

        auto ret = _db.runCommand(cmd);
        if (!ret.ok.get!double) throw new Exception("findAndModify failed.");
        auto compilerVersionId = ret.value["compilerVersionId"].get!BsonObjectID;
        auto done = pending.find([
            "attempted": serializeToBson(false),
            "compilerVersionId": serializeToBson(compilerVersionId)
        ]).empty;
        if (done) markCompilerVersionDone(machineName, compilerVersionId);
    }

    void markCompilerVersionDone(string machineName, BsonObjectID compilerVersionId) {
        auto updateSpec = ["$set": (["done": true])];
        _db.compilerVersions(machineName).
            update(["_id": compilerVersionId], updateSpec);
    }

    void runUpdateVersionedArtifactsTask() {
        import vibe.core.core;
        runTask({
            while (true) {
                sleep(15.minutes);
                logInfo("Updating version information.");
                foreach (artifact; _versionedArtifacts) {
                    artifact.updateLatestVersion();
                }
            }
        });
    }

    db.Database _db;
    VersionedArtifact[string] _versionedArtifacts;
}

private:

api.CompilerInfo makeCompilerInfo(VersionedArtifact artifact,
    db.Compiler compiler, string[] versionIds
) {
    typeof(return) cut;
    cut.name = artifact.name;
    cut.type = compiler.clientType;
    api.Config config;
    config.priority = 10;
    foreach (i, url, ver; zip(sequence!"n", artifact.source.baseUrls, versionIds)) {
        config.strings["url" ~ i.to!string] = url;
        config.strings["version" ~ i.to!string] = ver;
    }
    cut.config ~= config;
    return cut;
}

enum ArtifactType {
    benchmarkBundle,
    compiler
}

VersionedSource createVersionedSource(db.SourceType type, Bson config) {
    final switch (type) {
        case db.SourceType.githubBranch:
            auto owner = config["owner"].get!string;
            auto project = config["project"].get!string;
            auto branch = config["branch"].get!string;
            return new GithubBranchSource(owner, project, branch);

        case db.SourceType.githubBranches:
            return new AggregateSource(
                config.get!(const(Bson)[]).map!(
                    a => createVersionedSource(db.SourceType.githubBranch, a)
                ).array
            );
    }
}

class VersionedArtifact {
    string name;
    ArtifactType type;
    VersionedSource source;

    VersionUpdate latestVersion;

    void updateLatestVersion() {
        latestVersion = source.fetchLastUpdate();
    }

    override string toString() {
        import std.string;
        return format("VersionedArtifact('%s', %s, %s)", name, type, latestVersion);
    }
}
