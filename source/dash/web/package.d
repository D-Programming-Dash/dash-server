module dash.web;

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

        res.redirect("%s%s/compare/%s:%s@current..%s:%s@previous".format(
            req.rootDir, currentMachine, defaultCompiler, defaultRunConfig,
            defaultCompiler, defaultRunConfig));
    }

    void getCompare(HTTPServerRequest req, HTTPServerResponse res) {
        auto machineNames = _results.machineNames;
        auto currentMachine = validatedMachineName(req, machineNames);

        auto specifierString = req.params["specifier"];
        auto choice = parseComparisonChoice(specifierString);

        auto compilerNames = _results.compilerNames;
        foreach (cs; choice) {
            enforceHTTP(compilerNames.canFind(cs.compilerName), HTTPStatus.notFound);
        }

        auto runConfigNames =
            compilerNames.map!(a => _results.runConfigNames(a)).array;

        res.render!(
            "compare.dt",
            compilerNames,
            machineNames,
            currentMachine,
            specifierString,
            choice,
            runConfigNames,
            revisionChoiceNames,
            req
        );
    }

private:
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
