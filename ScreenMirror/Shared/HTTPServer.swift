import Foundation
import Network

/// A parsed HTTP request line plus headers (header names are lowercased).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
}

struct HTTPResponse {
    enum Body {
        case data(Data)
        /// A file on disk, served with `Range` support (TVs seek with range requests).
        case file(URL)
        /// A long-lived response; the closure receives a writer to push data with.
        case stream((HTTPStreamWriter) -> Void)
    }

    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Body

    static func data(_ data: Data, contentType: String, headers: [String: String] = [:]) -> HTTPResponse {
        var headers = headers
        headers["Content-Type"] = contentType
        return HTTPResponse(headers: headers, body: .data(data))
    }

    static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: .data(Data(text.utf8)))
    }

    static func file(_ url: URL, contentType: String, headers: [String: String] = [:]) -> HTTPResponse {
        var headers = headers
        headers["Content-Type"] = contentType
        return HTTPResponse(headers: headers, body: .file(url))
    }

    static func stream(contentType: String, start: @escaping (HTTPStreamWriter) -> Void) -> HTTPResponse {
        HTTPResponse(headers: ["Content-Type": contentType, "Cache-Control": "no-cache"], body: .stream(start))
    }

    static let notFound = text("Not Found", status: 404)
}

/// Pushes chunks to a client that holds a streaming response open.
final class HTTPStreamWriter {
    private let connection: NWConnection
    private let lock = NSLock()
    private var pendingWrites = 0
    private var closed = false
    fileprivate var onClose: (() -> Void)?

    fileprivate init(connection: NWConnection) {
        self.connection = connection
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// True while an earlier write has not been handed to the network yet; skip frames rather than queue them.
    var isBusy: Bool { lock.withLock { pendingWrites > 0 } }

    func write(_ data: Data) {
        guard !isClosed else { return }
        lock.withLock { pendingWrites += 1 }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.pendingWrites -= 1 }
            if error != nil { self.close() }
        })
    }

    func close() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        connection.cancel()
        onClose?()
    }
}

/// A tiny HTTP/1.1 server (one request per connection) built on Network.framework.
final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    let port: UInt16
    private let handler: Handler
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let stateLock = NSLock()
    private var listening = false

    init(port: UInt16, label: String = "http-server", handler: @escaping Handler) {
        self.port = port
        self.handler = handler
        self.queue = DispatchQueue(label: label)
    }

    var isListening: Bool { stateLock.withLock { listening } }

    func start() throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateLock.withLock { self.listening = true }
            case .failed(let error):
                NSLog("HTTPServer on port \(self.port) failed: \(error)")
                self.stateLock.withLock { self.listening = false }
            case .cancelled:
                self.stateLock.withLock { self.listening = false }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateLock.withLock { listening = false }
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    // Called on `queue`.
    private func accept(_ nwConnection: NWConnection) {
        let connection = HTTPConnection(connection: nwConnection, queue: queue, handler: handler)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.onFinish = { [weak self] in
            self?.connections[id] = nil
        }
        connection.start()
    }
}

/// Serves exactly one request, then closes. All methods run on the server queue.
private final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var finished = false
    private var streamWriter: HTTPStreamWriter?
    var onFinish: (() -> Void)?

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let chunkSize = 256 * 1024

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHeaders()
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        streamWriter?.close()
        streamWriter = nil
        onFinish?()
    }

    private func receiveHeaders() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Self.headerTerminator) {
                self.handle(head: self.buffer.subdata(in: 0..<end.lowerBound))
            } else if error != nil || isComplete || self.buffer.count > 64 * 1024 {
                self.cancel()
            } else {
                self.receiveHeaders()
            }
        }
    }

    private func handle(head: Data) {
        guard let text = String(data: head, encoding: .utf8) else { return cancel() }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return cancel() }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let target = String(parts[1])
        let rawPath = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let request = HTTPRequest(
            method: String(parts[0]).uppercased(),
            path: rawPath.removingPercentEncoding ?? rawPath,
            headers: headers
        )
        respond(handler(request), to: request)
    }

    private func respond(_ response: HTTPResponse, to request: HTTPRequest) {
        var headers = response.headers
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        let isHead = request.method == "HEAD"

        switch response.body {
        case .data(let data):
            headers["Content-Length"] = "\(data.count)"
            sendHead(status: response.status, headers: headers)
            sendFinal(isHead ? nil : data)

        case .file(let url):
            serveFile(url, request: request, status: response.status, headers: headers, isHead: isHead)

        case .stream(let start):
            sendHead(status: response.status, headers: headers)
            if isHead { return sendFinal(nil) }
            let writer = HTTPStreamWriter(connection: connection)
            writer.onClose = { [weak self] in
                self?.queue.async { self?.finish() }
            }
            streamWriter = writer
            start(writer)
            watchForDisconnect()
        }
    }

    private func watchForDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.cancel()
            } else {
                self.watchForDisconnect()
            }
        }
    }

    private func serveFile(_ url: URL, request: HTTPRequest, status: Int, headers: [String: String], isHead: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return respond(.notFound, to: request)
        }

        var headers = headers
        var status = status
        var start: Int64 = 0
        var end: Int64 = size - 1
        headers["Accept-Ranges"] = "bytes"

        if let rangeHeader = request.headers["range"] {
            guard let range = Self.parseRange(rangeHeader, size: size) else {
                try? handle.close()
                headers["Content-Range"] = "bytes */\(size)"
                headers["Content-Length"] = "0"
                sendHead(status: 416, headers: headers)
                return sendFinal(nil)
            }
            (start, end) = range
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }

        let length = max(0, end - start + 1)
        headers["Content-Length"] = "\(length)"
        sendHead(status: status, headers: headers)

        guard !isHead, length > 0 else {
            try? handle.close()
            return sendFinal(nil)
        }
        do {
            try handle.seek(toOffset: UInt64(start))
        } catch {
            try? handle.close()
            return cancel()
        }
        pump(handle, remaining: length)
    }

    private func pump(_ handle: FileHandle, remaining: Int64) {
        guard !finished else { try? handle.close(); return }
        guard remaining > 0 else {
            try? handle.close()
            return sendFinal(nil)
        }
        let count = Int(min(remaining, Int64(Self.chunkSize)))
        guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else {
            try? handle.close()
            return cancel()
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                self?.cancel()
                return
            }
            self.pump(handle, remaining: remaining - Int64(chunk.count))
        })
    }

    private func sendHead(status: Int, headers: [String: String]) {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    private func sendFinal(_ data: Data?) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }

    /// Parses a single `bytes=` range into inclusive offsets.
    static func parseRange(_ value: String, size: Int64) -> (Int64, Int64)? {
        guard value.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
        let spec = value.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return nil }

        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            return (max(0, size - suffix), size - 1)
        }
        guard let start = Int64(bounds[0]), start < size else { return nil }
        let end = Int64(bounds[1]).map { min($0, size - 1) } ?? size - 1
        guard end >= start else { return nil }
        return (start, end)
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
