module dash.web;

import vibe.d;
import dash.model.results;

class WebFrontend {
    this (Results results) {
        _results = results;
    }

    void registerRoutes(URLRouter r) {
        r.get("/", &showHome);
        r.get("/compare", &showCompareChooser);
        r.post("/compare", &redirectCompareResult);
        r.get("*", serveStaticFiles("./public"));
    }

    void showHome(HTTPServerRequest req, HTTPServerResponse res) {
        renderStatic!"home.dt"(req, res);
    }

    void showCompareChooser(HTTPServerRequest req, HTTPServerResponse res) {
        auto machineNames = _results.machineNames;
        auto compilerNames = _results.compilerNames;
        res.render!(
            "compare_chooser.dt",
            compilerNames,
            machineNames,
            req
        );
    }

    void redirectCompareResult(HTTPServerRequest req, HTTPServerResponse res) {
        showCompareChooser(req, res);
    }

private:
    void renderStatic(string templateFile)(HTTPServerRequest req, HTTPServerResponse res) {
        // TODO: Cache!
        auto machineNames = _results.machineNames;
        res.render!(
            templateFile,
            machineNames,
            req
        );
    }

    Results _results;
}
