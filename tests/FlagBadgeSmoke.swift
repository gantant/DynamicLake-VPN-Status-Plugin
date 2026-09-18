import Foundation

@main
private enum FlagBadgeSmoke {
    static func main() throws {
        guard let payload = countryFlagImagePayload(countryCode: "CH"),
              payload["type"] as? String == "image",
              payload["source"] as? String == "inlineData",
              payload["mimeType"] as? String == "image/png",
              let encoded = payload["base64Data"] as? String,
              let png = Data(base64Encoded: encoded) else {
            throw SmokeError.invalidPayload
        }
        guard png.count < 256 * 1024,
              png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw SmokeError.invalidPNG
        }
        guard countryFlagImagePayload(countryCode: "invalid") == nil else {
            throw SmokeError.acceptedInvalidCode
        }
        print("flag badge smoke test passed (\(png.count) bytes)")
    }
}

private enum SmokeError: Error {
    case invalidPayload
    case invalidPNG
    case acceptedInvalidCode
}
