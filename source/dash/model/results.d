module dash.model.results;

import db = dash.model.db;
import std.algorithm : map;
import std.datetime : SysTime;
import std.range;
import vibe.data.bson;

class Results {
    this(db.Database db) {
        _db = db;
    }

    string[] machineNames() {
        return _db.machines.find(null, ["name": 1]).map!(a => a["name"].get!string).array;
    }

    string[] compilerNames() {
        return _db.compilers.find(null, ["name": 1]).map!(a => a["name"].get!string).array;
    }

private:
    db.Database _db;
}
