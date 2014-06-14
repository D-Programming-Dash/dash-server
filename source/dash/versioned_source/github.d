module dash.versioned_source.github;

import dash.versioned_source.base;

class GithubBranchSource : VersionedSource {
    import vibe.inet.url;

    this(string owner, string project, string branch) {
        import std.string;
        _baseUrl = format("https://github.com/%s/%s.git", owner, project);

        _eventURL = URL.parse(format("https://api.github.com/repos/%s/%s/events",
            owner, project));
        _targetRef = format("refs/heads/%s", branch);

        _branchURL = URL.parse(format("https://api.github.com/repos/%s/%s/branches/%s",
            owner, project, branch));
    }

    override @property string[] baseUrls() {
        return [_baseUrl];
    }

    override VersionUpdate fetchLastUpdate() {
        import std.algorithm;
        import std.datetime;
        import vibe.core.log;
        import vibe.data.json;
        import vibe.http.client;

        auto json = requestHTTP(_eventURL).readJson();
        scope (failure) {
            logWarn("[GithubBranchSource] Error parsing JSON reply: %s",
                json.toString());
        }

        auto events = json.get!(Json[]);
        enforce(events.length > 0, "No events in GitHub event stream.");

        // We assume that the events are ordered in the GitHub response.
        foreach (e; events) {
            if (e["type"].get!string != "PushEvent") continue;
            if (e["payload"]["ref"].get!string != _targetRef) continue;
            auto timestamp = e["created_at"].deserializeJson!SysTime;
            auto hash = e["payload"]["head"].get!string;
            return VersionUpdate(timestamp, [hash]);
        }

        // There is no guarantee that we will find a PushEvent in the stream.
        // This will e.g. happen for new repositories.
        logWarn("[GithubBranchSource] No matching PushEvent found in stream " ~
            "'%s', manually fetching branch.", _eventURL);

        auto branch = requestHTTP(_branchURL).readJson();

        // The timestamp stored in the Git commit info is only an approximation
        // of when the commit actually went live. As long as everybody uses the
        // merge button, it should be fine as a fallback, though.
        auto timestamp = branch["commit"]["commit"]["committer"]["date"].deserializeJson!SysTime;

        // Make sure we don't screw up our task scheduling by pulling in a far
        // future timestamp from a bogous commit.
        timestamp = min(timestamp, Clock.currTime);

        auto hash = branch["commit"]["sha"].get!string;
        return VersionUpdate(timestamp, [hash]);
    }

private:
    string _baseUrl;
    URL _eventURL;
    URL _branchURL;
    string _targetRef;
}
