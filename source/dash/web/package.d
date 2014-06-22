module dash.web;

import db = dash.model.db;

import vibe.d;
import dash.model.results;
import dash.web.compiler_choice;

///
struct SampleConfig {
    /// The identifier of the sample in the database (e.g. "run.totalSeconds").
    string dbName;

    /// The pretty name used to display the sample in the web UI.
    string displayName;

    /// The units the results are in, for display in the UI (e.g. "s").
    string units;
}

///
struct Config {
    ///
    SampleConfig[] samples;
}

///
class WebFrontend {
    ///
    this (Config config, Results results) {
        _config = config;
        _results = results;
    }

    /**
     * Registers the web UI pages with the passed router instance, based in the
     * root directory.
     */
    void registerRoutes(URLRouter r) {
        r.get("/", &getHome);
        r.get("/:machineName/compare", &getCompareIndex);
        r.post("/:machineName/compare", &postCompare);
        r.get("/:machineName/compare/:specifier", &getCompare);
        r.get("*", serveStaticFiles("./public"));
    }

    /**
     * Displays the main landing page.
     */
    void getHome(HTTPServerRequest req, HTTPServerResponse res) {
        auto machineNames = _results.machineNames;
        auto defaultMachine = "<none>";
        if (!machineNames.empty) defaultMachine = machineNames[0];
        renderStatic!"home.dt"(req, res, defaultMachine);
    }

    /**
     * Redirects the user to the default one-to-one comparison page for the
     * chosen machine.
     *
     * Currently, the chocie is based on the order of the (otherwise
     * insignificant) order of the database entires, although it might be a
     * good idea to make this configurable in the future.
     */
    void getCompareIndex(HTTPServerRequest req, HTTPServerResponse res) {
        auto currentMachine = validatedMachineName(req);

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

    /**
     * Renders the one-to-one comparison results chosen by the request URL.
     */
    void getCompare(HTTPServerRequest req, HTTPServerResponse res) {
        import std.algorithm;
        import std.ascii : isAlphaNum;
        import std.math;
        import std.range : assumeSorted, retro, sequence, zip;
        import std.typecons : Nullable;

        // First, validate the passed comparison specifier and fetch the
        // information needed to display the comparison chooser.

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

        // Now, try to map the user's compiler choices to a compiler version id
        // we can use to look up the results. Display a nice error page if no
        // suitable version exists.

        Nullable!(db.CompilerVersion) findVersion(CompilerChoice choice,
            SysTime olderThan = SysTime.init
        ) {
            typeof(return) result;
            auto id = findCompilerVersionId(currentMachine, choice, olderThan);
            if (id != BsonObjectID.init) {
                result = _results.compilerVersionById(currentMachine, id);
            }
            return result;
        }

        void renderNotFound(string notFoundName) {
            res.render!(
                "compare_notfound.dt",
                req,
                compilerNames,
                machineNames,
                currentMachine,
                specifierString,
                revisionChoiceNames,
                runConfigNames,
                choice,
                notFoundName
            );
        }

        auto targetVersion = findVersion(choice[1]);
        if (targetVersion.isNull) {
            renderNotFound("target");
            return;
        }

        SysTime baseOlderThan;
        if (choice[0].compilerName == choice[1].compilerName &&
            choice[0].runConfigName == choice[1].runConfigName
        ) {
            baseOlderThan = targetVersion.update.timestamp;
        }
        auto baseVersion = findVersion(choice[0], baseOlderThan);
        if (baseVersion.isNull) {
            renderNotFound("base");
            return;
        }

        // We have our two compiler versions. Fetch the results from the
        // database and derive the representation exported to the JS UI.

        auto sortedResults(BsonObjectID id, CompilerChoice choice) {
            auto results = _results.resultsForRunConfig(
                currentMachine, id, choice.runConfigName);
            // If results from multiple runs of a given benchmark are available
            // (i.e. if the benchmark has been updated), we only want to use
            // the most recent one.
            results.sort!((a, b) => a.name < b.name, SwapStrategy.stable);
            auto uniqed = results.retro.uniq!((a, b) => a.name == b.name).retro;
            return uniqed.array.assumeSorted!((a, b) => a.name < b.name);
        }

        auto baseResults = sortedResults(baseVersion._id, choice[0]);
        auto targetResults = sortedResults(targetVersion._id, choice[1]);

        // Common benchmark names, exported to JS.
        auto benchmarkNames = setIntersection(baseResults.map!(a => a.name),
            targetResults.map!(a => a.name)).array.assumeSorted;

        // Sample information, exported to JS.
        static struct Sample {
            string name;
            string jsName;
            string units;
            // The JSON serializer doesn't like static arrays.
            double[] baseMeans;
            double[] targetMeans;
            double[] baseStdDevs;
            double[] targetStdDevs;
        }
        Sample[] samples;
        if (!baseResults.empty && !targetResults.empty) {
            foreach (c; _config.samples) {
                // We assume here that every benchmark from one run has the
                // same sample categories. Might want to revisit for tailored
                // reporting later.
                if (c.dbName !in baseResults[0].samples) continue;
                if (c.dbName !in targetResults[0].samples) continue;

                Sample s;
                s.name = c.displayName;
                s.jsName = c.dbName.filter!(a => a.isAlphaNum).to!string;

                void calcStats(typeof(baseResults) results,
                    out double[] means, out double[] stdDevs
                ) {
                    auto displayedValues = results.
                        filter!(a => benchmarkNames.contains(a.name)).
                        map!(a => a.samples[c.dbName]);

                    static calcMean(T)(T t) { return reduce!"a + b"(0.0, t) / t.length; }
                    means = displayedValues.map!calcMean.array;

                    stdDevs = new double[means.length];
                    foreach (i, values, mean; zip(sequence!"n", displayedValues, means)) {
                        immutable n = values.length;
                        if (n <= 1) {
                            stdDevs = null;
                            return;
                        }
                        immutable var = reduce!((a, b) => a + (b - mean)^^2)(0.0, values);
                        // Mean of standard deviation. This should at least be
                        // scaled with the Student t factor, but even that is a
                        // somewhat pointless exercise given the non-Gaussian
                        // distribution of benchmark timings. Need to think
                        // about the best way of reporting the statistical
                        // properties.
                        stdDevs[i] = sqrt(var / (n - 1) / n);
                    }
                }
                calcStats(baseResults, s.baseMeans, s.baseStdDevs);
                calcStats(targetResults, s.targetMeans, s.targetStdDevs);

                samples ~= s;
            }
        }

        // Prepare the compiler version details for the bottom of the results
        // page.

        static struct CompilerInfo {
            string banner;
            string systemInfo;
            string[] missingBenchmarks;
        }
        alias R = typeof(baseResults);
        auto getInfo(R results, R otherResults) {
            CompilerInfo info;
            if (results.empty) {
                info.banner = "<no benchmark results>";
                info.systemInfo = "<no benchmark results>";
            } else {
                info.banner = results[0].envData["compilerBanner"];
                info.systemInfo = results[0].envData["systemInfo"];
            }
            info.missingBenchmarks = setDifference(
                otherResults.map!(a => a.name), benchmarkNames).array;
            return info;
        }
        auto base = getInfo(baseResults, targetResults);
        auto target = getInfo(targetResults, baseResults);

        auto machineDescription = _results.machineDescription(currentMachine);

        res.render!(
            "compare_results.dt",
            req,
            compilerNames,
            machineNames,
            currentMachine,
            specifierString,
            revisionChoiceNames,
            runConfigNames,
            choice,
            machineDescription,
            benchmarkNames,
            samples,
            base,
            target
        );
    }

    /**
     * Redirects the user to the GET URL corresponding to the one-to-one
     * comparison results chosen by the submitted form data.
     *
     * In the future, this might be moved into JS client side logic to save one
     * HTTP roundtrip.
     */
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

    /// Maps from revision specification display strings to the internal
    /// representation.
    ///
    /// Currently, only a subset of types is implemented, and no means for
    /// specifying the additional info are provided.
    static immutable revisionChoiceNames = [
        tuple("Current", RevisionChoice.Type.current),
        tuple("Previous", RevisionChoice.Type.previous),
        tuple("1 day ago", RevisionChoice.Type.day),
        tuple("1 week ago", RevisionChoice.Type.week),
        tuple("1 month ago", RevisionChoice.Type.month),
        tuple("1 year ago", RevisionChoice.Type.year)
    ];

    Config _config;
    Results _results;
}
