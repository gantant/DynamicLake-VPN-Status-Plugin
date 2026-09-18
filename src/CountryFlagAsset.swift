import Foundation

private var flagDataCache: [String: String] = [:]

/// Inline images use the same proven DynamicLake path as the provider logos.
/// Some host builds accept `packageFile` but fail to display it in compact slots.
func countryFlagImagePayload(countryCode: String) -> [String: Any]? {
    let code = countryCode.lowercased()
    guard code.count == 2,
          code.unicodeScalars.allSatisfy({ (97...122).contains(Int($0.value)) }) else {
        return nil
    }

    if let encoded = flagDataCache[code] ?? loadFlagData(countryCode: code)?.base64EncodedString() {
        flagDataCache[code] = encoded
        return [
            "type": "image",
            "id": "vpn-country-flag",
            "source": "inlineData",
            "mimeType": "image/png",
            "base64Data": encoded
        ]
    }

    let emoji = regionalIndicatorFlag(countryCode: code.uppercased())
    guard !emoji.isEmpty else { return nil }
    return ["type": "text", "id": "vpn-country-flag-fallback", "text": emoji]
}

private func loadFlagData(countryCode: String) -> Data? {
    var roots: [URL] = []
    if let packagePath = ProcessInfo.processInfo.environment["DYNAMICLAKE_PLUGIN_PACKAGE_PATH"] {
        roots.append(URL(fileURLWithPath: packagePath, isDirectory: true))
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    roots.append(executable.deletingLastPathComponent())

    for root in roots {
        let url = root.appendingPathComponent("flags/\(countryCode).png")
        if let data = try? Data(contentsOf: url),
           data.count < 256 * 1024,
           data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return data
        }
    }
    return nil
}

private func regionalIndicatorFlag(countryCode: String) -> String {
    let base: UInt32 = 0x1F1E6
    var scalars = String.UnicodeScalarView()
    for scalar in countryCode.unicodeScalars {
        guard (65...90).contains(Int(scalar.value)),
              let flagScalar = UnicodeScalar(base + scalar.value - 65) else { return "" }
        scalars.append(flagScalar)
    }
    return String(scalars)
}
