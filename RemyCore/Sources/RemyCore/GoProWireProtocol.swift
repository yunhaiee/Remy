import Foundation

public enum GoProAddress {
    /// Matches Open GoPro WiredGoPro._BASE_IP: 172.2a.1bc.51 for serial suffix abc.
    public static func wired(serialSuffix: String) -> String? {
        let bytes = Array(serialSuffix.utf8)
        guard bytes.count == 3, bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return "172.\(20 + Int(bytes[0] - 48)).\(100 + Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)).51"
    }

    public static func isLocalIPv4(_ host: String) -> Bool {
        let fields = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = fields.compactMap { UInt8($0) }
        guard fields.count == 4, bytes.count == 4,
              fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }
}

/// Bounded HTTP/1 response framing for the USB-only Network.framework transport.
public enum GoProHTTP {
    public static let limit = 1_048_576
    public static func body(in data: Data, connectionClosed: Bool = false) throws -> Data? {
        guard data.count <= limit else { throw GoProWireError.invalidResponse }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if connectionClosed { throw GoProWireError.invalidResponse }; return nil
        }
        guard let header = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw GoProWireError.invalidResponse }
        let lines = header.components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " "), status.count >= 2,
              status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else { throw GoProWireError.invalidResponse }
        guard code == 200 else { throw GoProWireError.httpStatus(code) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { throw GoProWireError.invalidResponse }
            headers[String(fields[0]).lowercased()] = fields[1].trimmingCharacters(in: .whitespaces)
        }
        let payload = Data(data[end.upperBound...])
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            var cursor = 0, result = Data()
            while cursor < payload.count {
                guard let lineEnd = payload.range(of: Data("\r\n".utf8), in: cursor..<payload.count),
                      let lengthText = String(data: payload[cursor..<lineEnd.lowerBound], encoding: .utf8),
                      let rawLength = lengthText.split(separator: ";").first,
                      let size = Int(rawLength, radix: 16), size >= 0, size <= limit else {
                    if connectionClosed { throw GoProWireError.invalidResponse }; return nil
                }
                cursor = lineEnd.upperBound
                guard cursor + size + 2 <= payload.count else {
                    if connectionClosed { throw GoProWireError.invalidResponse }; return nil
                }
                guard payload[cursor + size] == 13, payload[cursor + size + 1] == 10 else { throw GoProWireError.invalidResponse }
                if size == 0 { return result }
                result.append(payload[cursor..<cursor + size]); cursor += size + 2
            }
            if connectionClosed { throw GoProWireError.invalidResponse }; return nil
        }
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), (0...limit).contains(length) else { throw GoProWireError.invalidResponse }
            guard payload.count >= length else {
                if connectionClosed { throw GoProWireError.invalidResponse }; return nil
            }
            return Data(payload.prefix(length))
        }
        return connectionClosed ? payload : nil
    }
}

public enum GoProWireError: LocalizedError {
    case invalidResponse, httpStatus(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The camera sent an invalid or incomplete HTTP reply."
        case .httpStatus(let code): return "The camera returned HTTP \(code). Check that it is idle and connected."
        }
    }
}
