import Foundation

public enum GoProBLEProtocol {
    public static let enableWiFi = Data([0x03, 0x17, 0x01, 0x01])

    /// Acknowledges this request only; it does not establish AP readiness or a Wi-Fi/video connection.
    public static func wifiEnableAcknowledgement(_ packet: Data) throws -> Bool? {
        let bytes = Array(packet)
        guard bytes.count >= 2, bytes[1] == 0x17 else { return nil }
        guard bytes.count == 3, bytes[0] == 2 else { throw GoProBLEError.invalidAcknowledgement }
        return bytes[2] == 0
    }

    public static func credentialText(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 128,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard !clean.isEmpty, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return clean
    }
}

public enum GoProBLEError: LocalizedError {
    case invalidAcknowledgement
    public var errorDescription: String? { "The camera sent an invalid Bluetooth acknowledgement." }
}
