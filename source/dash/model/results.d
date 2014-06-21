module dash.model.results;

import db = dash.model.db;
import std.algorithm : map, minPos;
import std.array : array;
import std.datetime : SysTime;
import std.exception : enforce;
import std.range;
import std.typecons : tuple;
import vibe.data.bson;

class Results {
    this(db.Database db) {
        _db = db;
    }

    string[] machineNames() {
        return _db.machines.find(Bson.emptyObject, ["name": 1]).map!(a => a["name"].get!string).array;
    }

    string[] compilerNames() {
        return _db.compilers.find(Bson.emptyObject, ["name": 1]).map!(a => a["name"].get!string).array;
    }

    string[] runConfigNames(string compilerName) {
        auto result = _db.compilers.findOne(["name": compilerName], ["runConfigs": 1]);
        enforce(!result.isNull, "Unknown compiler.");
        return result["runConfigs"].get!(Bson[]).map!(a => a["name"].get!string).array;
    }

    /**
     * Returns the n-th newest version of the given compiler for which all
     * the tests have been attempted.
     *
     * If no such version exists, BsonObjectID.init is returned.
     */
    BsonObjectID compilerVersionIdByIndex(string machineName,
        string compilerName, int index
    ) {
        import vibe.db.mongo.connection;

        auto coll = _db.compilerVersions(machineName);
        auto findSpec = [
            "name": serializeToBson(compilerName),
            "completed": serializeToBson(true)
        ];
        auto bsonPairs = coll.find(findSpec, ["_id": true], QueryFlags.None,
            index).sort(["_id": -1]).limit(1);
        if (bsonPairs.empty) return typeof(return).init;
        return bsonPairs.front["_id"].deserializeBson!BsonObjectID;
    }

    /**
     * Returns the version of the given compiler whose timestamp is closest
     * to the given target time. If olderThan is given, it must be strictly
     * older than the given timestamp.
     *
     * If no such version exists, BsonObjectID.init is returned.
     */
    BsonObjectID compilerVersionIdByTimestamp(string machineName,
        string compilerName, SysTime targetTime,
        SysTime olderThan = SysTime.init
    ) {
        auto coll = _db.compilerVersions(machineName);

        auto findSpec = [
            "name": serializeToBson(compilerName),
            "completed": serializeToBson(true)
        ];
        if (olderThan != SysTime.init) {
            findSpec["$lt"] = [
                "update.timestamp": targetTime
            ].serializeToBson;
        }
        auto bsonPairs = coll.find(findSpec,
            ["_id": true, "update.timestamp": true]);
        if (bsonPairs.empty) return typeof(return).init;
        auto pairs = bsonPairs.map!(
            a => tuple(a["_id"].deserializeBson!BsonObjectID,
            a["update"]["timestamp"].deserializeBson!SysTime));

        auto error(typeof(pairs.front) a) {
            import core.time;
            return abs(a[1] - targetTime);
        }
        // std.algorithm.minPos needs a forward range, even though we only
        // want the first one.
        auto min = pairs.front[0];
        auto minError = error(pairs.front);
        pairs.popFront();
        while (!pairs.empty) {
            auto currError = error(pairs.front);
            if (currError <= minError) {
                min = pairs.front[0];
                minError = currError;
            }
            pairs.popFront();
        }
        return min;
    }

    db.CompilerVersion compilerVersionById(string machineName, BsonObjectID id) {
        return _db.compilerVersions(machineName).
            findOne(["_id": id]).deserializeBson!(db.CompilerVersion);
    }

    db.Result[] resultsForRunConfig(string machineName,
        BsonObjectID compilerVersionId, string runConfigName
    ) {
        return _db.results(machineName).find([
            "compilerVersionId": compilerVersionId.serializeToBson,
            "runConfig": runConfigName.serializeToBson
        ]).map!(a => a.deserializeBson!(db.Result)).array;
    }

    string machineDescription(string machineName) {
        return _db.machines.findOne(["name": machineName],
            ["description": true])["description"].deserializeBson!string;
    }

private:
    db.Database _db;
}
