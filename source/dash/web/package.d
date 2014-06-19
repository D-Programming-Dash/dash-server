module dash.web;

import vibe.d;
import dash.model.results;

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

        auto compilers = _results.compilerNames;
        enforce(!compilers.empty, new HTTPStatusException(HTTPStatus.notFound));
        auto defaultCompiler = compilers[0];

        auto runConfigs = _results.runConfigNames(defaultCompiler);
        enforce(!runConfigs.empty, new HTTPStatusException(HTTPStatus.notFound));
        auto defaultRunConfig = runConfigs[$ - 1];

        res.redirect("%s%s/compare/%s:%s@current..%s:%s@previous".format(
            req.rootDir, currentMachine, defaultCompiler, defaultRunConfig,
            defaultCompiler, defaultRunConfig));
    }

    void getCompare(HTTPServerRequest req, HTTPServerResponse res) {
        auto currentMachine = validatedMachineName(req);

        auto specifier = req.params["specifier"];

        auto machineNames = _results.machineNames;
        auto compilerNames = _results.compilerNames;

        res.render!(
            "compare.dt",
            compilerNames,
            machineNames,
            currentMachine,
            specifier,
            req
        );
    }

private:
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

    string validatedMachineName(HTTPServerRequest req) {
        auto name = req.params["machineName"];
        // Horribly inefficient, cache.
        enforce(_results.machineNames.canFind(name),
            new HTTPStatusException(HTTPStatus.notFound));
        return name;
    }

    Results _results;
}
