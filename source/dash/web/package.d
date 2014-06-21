module dash.web;

import db = dash.model.db;

import vibe.d;
import dash.model.results;
import dash.web.compiler_choice;

class WebFrontend {
    this (Results results) {
        _results = results;
    }

    void registerRoutes(URLRouter r) {
        r.get("/", &getHome);
        r.get("/:machineName/compare", &getCompareIndex);
        r.post("/:machineName/compare", &postCompare);
        r.get("/:machineName/compare/:specifier", &getCompare);
        r.get("*", serveStaticFiles("./public"));
    }

    void getHome(HTTPServerRequest req, HTTPServerResponse res) {
        auto machineNames = _results.machineNames;
        auto defaultMachine = "<none>";
        if (!machineNames.empty) defaultMachine = machineNames[0];
        renderStatic!"home.dt"(req, res, defaultMachine);
    }

    void getCompareIndex(HTTPServerRequest req, HTTPServerResponse res) {
        auto currentMachine = validatedMachineName(req);

        // Redirect client to arbitrary default compiler choice. Might want to
        // make this configurable in the future.
        auto compilers = _results.compilerNames;
        enforceHTTP(!compilers.empty, HTTPStatus.notFound);
        auto defaultCompiler = compilers[0];

        auto runConfigs = _results.runConfigNames(defaultCompiler);
        enforceHTTP(!runConfigs.empty, HTTPStatus.notFound);
        auto defaultRunConfig = runConfigs[$ - 1];

        CompilerChoice[2] choice;
        choice[0] = CompilerChoice(defaultCompiler, defaultRunConfig,
            RevisionChoice(RevisionChoice.Type.previous));
        choice[1] = choice[0];
        choice[1].revisionChoice.type = RevisionChoice.Type.current;

        redirectToCompare(req, res, currentMachine, choice);
    }

    void getCompare(HTTPServerRequest req, HTTPServerResponse res) {
        import std.algorithm;
        import std.range : retro;

        auto machineNames = _results.machineNames;
        auto currentMachine = validatedMachineName(req, machineNames);

        auto specifierString = req.params["specifier"];
        auto choice = parseComparisonChoice(specifierString);

        auto compilerNames = _results.compilerNames;
        foreach (cs; choice) {
            enforceHTTP(compilerNames.canFind(cs.compilerName),
                HTTPStatus.notFound);
        }

        auto runConfigNames =
            compilerNames.map!(a => _results.runConfigNames(a)).array;

        auto findVersion(CompilerChoice choice, SysTime olderThan = SysTime.init) {
            auto id = findCompilerVersionId(currentMachine, choice, olderThan);
            return _results.compilerVersionById(currentMachine, id);
        }

        auto targetVersion = findVersion(choice[1]);

        SysTime baseOlderThan;
        if (choice[0].compilerName == choice[1].compilerName &&
            choice[0].runConfigName == choice[1].runConfigName
        ) {
            baseOlderThan = targetVersion.update.timestamp;
        }
        auto baseVersion = findVersion(choice[0], baseOlderThan);

        auto sortedResults(BsonObjectID id, CompilerChoice choice) {
            auto results = _results.resultsForRunConfig(
                currentMachine, id, choice.runConfigName);
            // If results from multiple runs of a given benchmark are available
            // (i.e. if the benchmark has been updated), we only want to use
            // the most recent one.
            results.sort!((a, b) => a.name < b.name, SwapStrategy.stable);
            return results.retro.uniq!((a, b) => a.name == b.name).retro.array;
        }

        auto baseResults = sortedResults(baseVersion._id, choice[0]);
        auto targetResults = sortedResults(targetVersion._id, choice[1]);

        auto commonNames = setIntersection(baseResults.map!(a => a.name),
            targetResults.map!(a => a.name)).array;

        static struct CompilerInfo {
            string banner;
            string systemInfo;
            string[] missingBenchmarks;
        }

        auto getInfo(db.Result[] results) {
            CompilerInfo info;
            info.banner = results[0].envData["compilerBanner"];
            info.systemInfo = results[0].envData["systemInfo"];
            info.missingBenchmarks = setDifference(
                results.map!(a => a.name), commonNames).array;
            return info;
        }
        auto base = getInfo(baseResults);
        auto target = getInfo(targetResults);
        auto machineDescription = _results.machineDescription(currentMachine);
        auto resultsSystemInfo = baseResults[0].envData["systemInfo"];

        res.render!(
            "compare.dt",
            compilerNames,
            machineNames,
            currentMachine,
            machineDescription,
            specifierString,
            choice,
            runConfigNames,
            revisionChoiceNames,
            base,
            target,
            req
        );
    }

    void postCompare(HTTPServerRequest req, HTTPServerResponse res) {
        auto currentMachine = validatedMachineName(req);

        CompilerChoice readChoice(string prefix) {
            typeof(return) result;

            auto compiler = (prefix ~ "compiler") in req.form;
            enforceHTTP(compiler, HTTPStatus.badRequest);
            result.compilerName = *compiler;

            auto runConfig = (prefix ~ "runconfig") in req.form;
            enforceHTTP(runConfig, HTTPStatus.badRequest);
            result.runConfigName = *runConfig;

            auto revision = (prefix ~ "revision") in req.form;
            enforceHTTP(revision, HTTPStatus.badRequest);
            auto typePair = revisionChoiceNames.find!(a => a[0] == *revision);
            enforce(!typePair.empty);
            result.revisionChoice.type = typePair.front[1];

            return result;
        }

        CompilerChoice[2] choice;
        choice[0] = readChoice("base_");
        choice[1] = readChoice("target_");
        redirectToCompare(req, res, currentMachine, choice);
    }

private:
    void redirectToCompare(HTTPServerRequest req, HTTPServerResponse res,
        string machine, in ref CompilerChoice[2] choice
    ) {
        auto url = appender!string();
        url.put(req.rootDir);
        url.put(machine);
        url.put("/compare/");
        choice.write(url);
        res.redirect(url.data);
    }

    BsonObjectID findCompilerVersionId(string machine,
        CompilerChoice choice, SysTime olderThan
    ) {
        import std.datetime;

        auto number = () => choice.revisionChoice.info.empty ?
            1 : to!int(choice.revisionChoice.info);

        SysTime timestamp;
        final switch (choice.revisionChoice.type) with (RevisionChoice.Type) {
            case current:
                return _results.compilerVersionIdByIndex(
                    machine, choice.compilerName, 0);
            case previous:
                return _results.compilerVersionIdByIndex(
                    machine, choice.compilerName, number());
            case day:
                timestamp = Clock.currTime - number().days;
                break;
            case week:
                timestamp = Clock.currTime - number().weeks;
                break;
            case month:
                timestamp = Clock.currTime.add!"months"(-number());
                break;
            case year:
                timestamp = Clock.currTime.add!"years"(-number());
                break;
        }

        return _results.compilerVersionIdByTimestamp(machine,
            choice.compilerName, timestamp, olderThan);
    }

    /// Maps from revision specification display strings to the internal
    /// representation.
    ///
    /// Currently, only a subset of types is implemented, and no means for
    /// specifying the additional info are provided.
    import std.typecons : Tuple;
    static immutable revisionChoiceNames = [
        tuple("Current", RevisionChoice.Type.current),
        tuple("Previous", RevisionChoice.Type.previous),
        tuple("1 day ago", RevisionChoice.Type.day),
        tuple("1 week ago", RevisionChoice.Type.week),
        tuple("1 month ago", RevisionChoice.Type.month),
        tuple("1 year ago", RevisionChoice.Type.year)
    ];

    void renderStatic(string templateFile)(
        HTTPServerRequest req,
        HTTPServerResponse res,
        string currentMachine
    ) {
        // TODO: Cache!
        auto machineNames = _results.machineNames;
        res.render!(
            templateFile,
            machineNames,
            currentMachine,
            req
        );
    }

    string validatedMachineName(HTTPServerRequest req, string[] machineNames = null) {
        if (!machineNames) machineNames = _results.machineNames;
        auto name = req.params["machineName"];
        enforceHTTP(machineNames.canFind(name), HTTPStatus.notFound);
        return name;
    }

    Results _results;
}
