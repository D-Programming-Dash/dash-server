import vibe.d;

shared static this() {
    import api = dash.api;
    import file = std.file;
    import dash.model.db;
    import dash.model.results;
    import dash.model.scheduler;
    import dash.web;
    import std.algorithm;
    import std.path : absolutePath;
    import std.string : format;
    import thrift.codegen.processor;
    import thrift.protocol.compact;
    import thrift.transport.buffered;
    import thrift.server.simple;
    import thrift_vibe;
    import vibe.db.mongo.mongo;

    // TODO: Read this from command line.
    immutable configDir = absolutePath("config");
    immutable configFile = buildPath(configDir, "dash-server.json");
    auto serverConfig = file.readText(configFile).parseJsonString();
    string config(string key) {
        auto json = serverConfig[key];
        enforce(json.type == Json.Type.string,
            "Expected config key '" ~ key ~ "' of type string.");
        return json.get!string;
    }
    string configPath(string key) {
        auto path = absolutePath(config(key), configDir);
        enforce(file.exists(path),
            format("Config option '%s': Path '%s' not found.", key, path));
        return path;
    }

    // Read all the config keys now to fail fast in case of missing ones.
    immutable dbHost = config("mongoDBHost");
    immutable dbName = config("mongoDBDatabase");
    immutable caCertPath = configPath("caCertPath");
    immutable certPath = configPath("certPath");
    immutable privateKeyPath = configPath("privateKeyPath");

    auto db = new Database(connectMongoDB(dbHost).getDatabase(dbName));
    auto scheduler = new Scheduler(db);
    auto results = new Results(db);

    ThriftListenOptions resultOpts;
    resultOpts.sslContext = createSSLContext(SSLContextKind.server);
    with (resultOpts.sslContext) {
        useCertificateChainFile(certPath);
        usePrivateKeyFile(privateKeyPath);
        useTrustedCertificateFile(caCertPath);
        peerValidationMode = SSLPeerValidationMode.trustedCert;
    }
    listenThrift(
        3274,
        new class api.ResultServer {
            override api.CompilerInfo getCompilerInfo(string machineName, string compilerName) {
                logInfo("Compiler info request from %s: %s", machineName, compilerName);
                return scheduler.getCompilerInfo(machineName, compilerName);
            }

            override api.Task nextTask(string machineName) {
                logInfo("Task request from %s.", machineName);
                return scheduler.nextTaskForMachine(machineName);
            }

            override void postResult(string machineName, api.BenchmarkResult result) {
                logInfo("Result from %s: %s", machineName, result);
                scheduler.postResult(machineName, result);
            }
        },
        resultOpts
    );

    ThriftListenOptions opts;
    opts.bindAddress = "127.0.0.1";
    listenThrift(
        3275,
        new class api.AdminServer {
            override void addMachine(string name, string description) {
                scheduler.addMachine(name, description);
            }

            override void addBenchmarkBundle(string name, string sourceJson) {
                scheduler.addBenchmarkBundle(name, sourceJson);
            }

            override void addCompiler(string name, string description,
                string sourceJson, api.CompilerType type
            ) {
                scheduler.addCompiler(name, description, sourceJson, type);
            }

            override void addRunConfig(string compiler, string name,
                string description, api.Config[] config
            ) {
                scheduler.addRunConfig(compiler, name, description, config);
            }
        },
        opts
    );

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["::1", "127.0.0.1"];
    auto router = new URLRouter;
    auto webFrontend = new WebFrontend(results);
    webFrontend.registerRoutes(router);
    listenHTTP(settings, router);
}
