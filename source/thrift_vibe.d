module thrift_vibe;

import std.range;
import thrift.codegen.base : isService;
import thrift.protocol.base;
import thrift.protocol.processor;
import thrift.transport.base;
import thrift.util.cancellation;
import vibe.core.log;
import vibe.core.net;
import vibe.core.stream;

/**
 * Wraps a vibe.d Stream to offer a Thrift TTransport interface.
 *
 * If the stream is a StreamConnection, the isOpen/close commands will also be
 * forwarded to the appropriate primitives. Otherwise, Stream.finalize will be
 * called on close instead.
 */
final class VibeTransport(S) if (
    is(S : Stream)
) : TTransport {
    this(S stream) {
        _stream = stream;
    }

    override bool isOpen() @property {
        static if (is(typeof(_stream.connected) : bool)) {
            return _stream.connected;
        } else {
            return !_closed;
        }
    }

    override bool peek() {
        return _stream.empty();
    }

    override void open() {
        throw new TTransportException(TTransportException.Type.NOT_IMPLEMENTED,
            "Cannot open a VibeTransport.");
    }

    override void close() {
        static if (is(typeof(_stream.close()))) {
            _stream.close();
        } else {
            // Call finalize() in lieu of a real close(). If close() is present,
            // it will invoke finalize().
            _stream.finalize();
            _closed = true;
        }
    }

    override size_t read(ubyte[] buf) {
        import std.algorithm;

        if (buf.length == 0) return 0;

        // Read at least a single byte as per the TTransport API.
        immutable len = max(1, min(buf.length, _stream.leastSize));
        _stream.read(buf[0 .. len]);
        return len;
    }

    override void readAll(ubyte[] buf) {
        try {
            _stream.read(buf);
        } catch (Exception e) {
            throw new TTransportException(TTransportException.Type.END_OF_FILE,
                __FILE__, __LINE__, e);
        }
    }

    override size_t readEnd() {
        // No-op.
        return 0;
    }

    override void write(in ubyte[] buf) {
        _stream.write(buf);
    }

    override size_t writeEnd() {
        // No-op.
        return 0;
    }

    override void flush() {
        _stream.flush();
    }

    override const(ubyte)[] borrow(ubyte* buf, size_t len) {
        const data = _stream.peek();
        if (data.length < len) return null;
        return data;
    }

    override void consume(size_t len) {
        // Unfortunately, vibe.d provides no way to advance the buffer without
        // reading the data into a buffer. Let's hope the compiler optimizes
        // the store into a stack buffer away. Otherwise, it might be best to
        // not provide borrow() at all.
        //
        // Could try to use alloca here as well, but it might not be optimized
        // as well.
        ubyte[1024] consumeScratchSpace = void;

        if (len <= consumeScratchSpace.length) {
            _stream.read(consumeScratchSpace[0 .. len]);
        } else {
            static ubyte[] consumeBuffer;
            if (len > consumeBuffer.length) {
                consumeBuffer = new ubyte[len];
            }
            _stream.read(consumeBuffer[0 .. len]);
        }
    }

private:
    S _stream;
    static if (!is(typeof(_stream.connected) : bool)) {
        bool _closed;
    }
}

auto vibeTransport(S)(S stream) if (
    is(S : Stream)
) {
    return new VibeTransport!S(stream);
}

template ServiceInterface(T) if (isService!T) {
    alias ServiceInterface = T;
}

template ServiceInterface(T) if (is(T == class)) {
    static if (is(T Bases == super)) {
        static if (is(Bases[0] == class)) {
            alias Ifaces = Bases[1 .. $];
        } else {
            alias Ifaces = Bases;
        }
        static if (Ifaces.length == 0) {
            static assert(false, "Class does not implement any interface.");
        } else static if (Ifaces.length == 1) {
            alias S = Ifaces[0];
            static assert(isService!S,
                "Class implements interface that is not a service.");
            alias ServiceInterface = S;
        } else {
            static assert(false,
                "Class implements more than one interface, ambiguous.");
        }
    } else {
        static assert(false, "Class does not implement any interface.");
    }
}

struct ThriftListenOptions {
    private import thrift.protocol.compact;
    TTransportFactory transportFactory =
        new TBufferedTransportFactory;

    private import thrift.transport.buffered;
    TProtocolFactory protocolFactory =
        new TCompactProtocolFactory!TBufferedTransport;

    string bindAddress;

    private import vibe.stream.ssl;
    SSLContext sslContext;

    TCPListenOptions tcpOptions = TCPListenOptions.defaults;

    enum defaults = ThriftListenOptions.init;
}

void listenThrift(S)(
    ushort port,
    S handler,
    ThriftListenOptions options = ThriftListenOptions.defaults
) if (is(ServiceInterface!S)) {
    import thrift.codegen.processor;
    import thrift.protocol.compact;
    import thrift.transport.buffered;
    // Optimize for our default settings. The use can always specify an optimized
    // processor for non-default protocols/transports.
    alias Processor = TServiceProcessor!(ServiceInterface!S,
        TCompactProtocol!TBufferedTransport);
    listenThrift(port, new Processor(handler), options);
}

// TODO: Support for TProcessorFactory, TServerEventHandler, …
void listenThrift(
    ushort port,
    TProcessor processor,
    ThriftListenOptions options = ThriftListenOptions.defaults
) {
    import vibe.stream.ssl;

    auto callback = (TCPConnection conn) {
        Stream stream = conn;
        if (options.sslContext) {
            stream = createSSLStream(stream, options.sslContext);
        }

        auto client = vibeTransport(stream);
        auto transport = options.transportFactory.getTransport(client);
        auto protocol = options.protocolFactory.getProtocol(transport);
        do {
            processor.process(protocol);
        } while (conn.connected);
    };

    if (options.bindAddress.length) {
        listenTCP(port, callback, options.bindAddress, options.tcpOptions);
    } else {
        listenTCP(port, callback, options.tcpOptions);
    }
}
