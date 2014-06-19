module dash.model.results;

import db = dash.model.db;
import std.algorithm : map;
import std.datetime : SysTime;
import std.exception : enforce;
import std.range;
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

private:
    db.Database _db;
}
