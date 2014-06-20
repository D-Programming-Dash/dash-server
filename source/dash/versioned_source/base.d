module dash.versioned_source.base;

import std.datetime : SysTime;

struct VersionUpdate {
    SysTime timestamp;
    string[] versionIds;
}

interface VersionedSource {
    @property string[] baseUrls();
    VersionUpdate fetchLastUpdate();
}

class AggregateSource : VersionedSource {
    import std.algorithm;
    import std.range;

    this(VersionedSource[] sources) {
        _sources = sources;
    }

    override @property string[] baseUrls() {
        return _sources.map!(a => a.baseUrls).joiner.array;
    }

    override VersionUpdate fetchLastUpdate() {
        auto updates = _sources.map!(a => a.fetchLastUpdate()).array;
        auto newestTimestamp =
            updates.map!(a => a.timestamp).minPos!((a, b) => a > b).front;
        auto ids = updates.map!(a => a.versionIds).joiner.array;
        return VersionUpdate(newestTimestamp, ids);
    }

private:
    VersionedSource[] _sources;
}
