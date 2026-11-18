import Foundation
import Network

/// A minimal HTTPS GET made directly with Network.framework.
///
/// Used only as a last resort for government servers that iOS 27's stricter App Transport Security
/// refuses inside apps (TLS 1.2 without the "extended master secret" extension, Apple support article
/// 126655), while Safari still opens them. The connection is still TLS 1.2 or later with the system's
/// normal certificate checks; it's just not made through URLSession / WebKit.
enum DirectHTTPS {
    static func get(_ url: URL, timeout: TimeInterval = 30) async -> (data: Data?, problem: String?) {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return (nil, "not an https address")
        }
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?" + query }
        let request = "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: CodeShelf/1\r\nAccept: */*\r\nConnection: close\r\n\r\n"

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let exchange = Exchange(connection: NWConnection(host: NWEndpoint.Host(host), port: 443, using: parameters))
        return await exchange.run(request: Data(request.utf8), timeout: timeout)
    }

    /// One request/response. Every callback runs on `queue`, so the state below is only touched there.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "codeshelf.direct-https")
        private var received = Data()
        private var finished = false
        private var continuation: CheckedContinuation<(data: Data?, problem: String?), Never>?

        init(connection: NWConnection) {
            self.connection = connection
        }

        func run(request: Data, timeout: TimeInterval) async -> (data: Data?, problem: String?) {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.send(content: request, completion: .contentProcessed { error in
                                if let error {
                                    self.finish(nil, "send failed: \(error.localizedDescription)")
                                } else {
                                    self.receive()
                                }
                            })
                        case .failed(let error):
                            self.finish(nil, "connection failed: \(error.localizedDescription)")
                        case .waiting(let error):
                            self.finish(nil, "can't connect: \(error.localizedDescription)")
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(nil, "timed out")
                    }
                }
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.received.append(data) }
                if isComplete || error != nil {
                    let parsed = DirectHTTPS.parseResponse(self.received)
                    self.finish(parsed.body, parsed.problem)
                } else {
                    self.receive()
                }
            }
        }

        private func finish(_ data: Data?, _ problem: String?) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation?.resume(returning: (data, problem))
            continuation = nil
        }
    }

    /// Splits an HTTP/1.1 response into status and body (handling chunked transfer encoding).
    static func parseResponse(_ raw: Data) -> (body: Data?, problem: String?) {
        let separator = Data("\r\n\r\n".utf8)
        guard let split = raw.range(of: separator) else {
            return (nil, raw.isEmpty ? "the server closed the connection" : "incomplete response")
        }
        let header = String(decoding: raw[raw.startIndex..<split.lowerBound], as: UTF8.self)
        var body = Data(raw[split.upperBound...])
        let lines = header.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return (nil, "unreadable response") }
        guard (200..<300).contains(status) else { return (nil, "HTTP \(status)") }
        let fields = lines.dropFirst().map { $0.lowercased() }
        if fields.contains(where: { $0.hasPrefix("transfer-encoding:") && $0.contains("chunked") }) {
            guard let decoded = dechunk(body) else { return (nil, "unreadable chunked response") }
            body = decoded
        } else if let lengthLine = fields.first(where: { $0.hasPrefix("content-length:") }),
                  let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                  body.count > length {
            body = body.prefix(length)
        }
        return (body, nil)
    }

    private static func dechunk(_ data: Data) -> Data? {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else { return nil }
            if size == 0 { return output }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            output.append(data[start..<end])
            index = min(data.endIndex, data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex)
        }
        return output
    }
}
