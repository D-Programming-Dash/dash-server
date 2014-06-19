module dash.web;

import vibe.d;
import dash.model.results;

class WebFrontend {
    this (Results results) {
        _results = results;
    }

    void registerRoutes(URLRouter r) {
        r.get("/", &showHome);
        r.get("/:machineName/compare", &redirectToDefaultCompare);
        r.get("/:machineName/compare/:specifier", &getCompareResult);
        r.get("*", serveStaticFiles("./public"));
    }

    void showHome(HTTPServerRequest req, HTTPServerResponse res) {
        renderStatic!"home.dt"(req, res);
    }

    void getCompareResult(HTTPServerRequest req, HTTPServerResponse res) {
        auto machineNames = _results.machineNames;
        auto compilerNames = _results.compilerNames;
        auto defaultMachine = "<none>";
        if (!machineNames.empty) defaultMachine = machineNames[0];
        res.render!(
            "compare_chooser.dt",
            compilerNames,
            machineNames,
            defaultMachine,
            req
        );
    }

    void redirectToDefaultCompare(HTTPServerRequest req, HTTPServerResponse res) {
        auto machineName = validatedMachineName(req);

        auto compilers = _results.compilerNames;
        enforce(!compilers.empty, new HTTPStatusException(HTTPStatus.notFound));
        auto defaultCompiler = compilers[0];

        auto runConfigs = _results.runConfigNames(defaultCompiler);
        enforce(!runConfigs.empty, new HTTPStatusException(HTTPStatus.notFound));
        auto defaultRunConfig = runConfigs[$ - 1];

        res.redirect("%s%s/compare/%s:%s@current..%s:%s@previous".format(
            req.rootDir, machineName, defaultCompiler, defaultRunConfig,
            defaultCompiler, defaultRunConfig));
    }

private:
    void renderStatic(string templateFile)(HTTPServerRequest req, HTTPServerResponse res) {
        // TODO: Cache!
        auto machineNames = _results.machineNames;
        auto defaultMachine = "<none>";
        if (!machineNames.empty) defaultMachine = machineNames[0];
        res.render!(
            templateFile,
            machineNames,
            defaultMachine,
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
