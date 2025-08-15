//  PayloadUtils.swift
//  OneHundredEightyDays

import Foundation

/// True if the string looks like hex (even length, 0-9A-Fa-f only)
func isHexString(_ s: String) -> Bool {
    guard s.count % 2 == 0 else { return false }
    return s.range(of: "^[0-9A-Fa-f]+$", options: .regularExpression) != nil
}

/// Convert a barcode payload (hex / ASCII BCBP / base64 / other UTF-8) into a hex string.
func normalizeToHex(_ payload: String) -> String {
    if isHexString(payload) {
        return payload.uppercased()
    }
    if let base64 = Data(base64Encoded: payload) {
        // base64 → hex
        return base64.hexStringUppercased()
    }
    // ASCII BCBP typically starts with "M" or "N"; otherwise treat as UTF-8 bytes.
    return Data(payload.utf8).hexStringUppercased()
}

/// Quick human-friendly description for logging & debugging.
func debugDescribePayload(_ s: String) -> String {
    let prefix = String(s.prefix(160))
    if isHexString(s) {
        return "HEX(\(s.count) chars) prefix=\(prefix)"
    } else if s.hasPrefix("M1") || s.hasPrefix("N1") {
        return "ASCII BCBP (\(s.count) chars) prefix=\(prefix)"
    } else if Data(base64Encoded: s) != nil {
        return "BASE64(\(s.count) chars) prefix=\(prefix)"
    } else {
        let hexPreview = Data(prefix.utf8).hexStringUppercased()
        return "UTF8(\(s.count) chars) asciiPrefix=\(prefix) hexPrefix=\(hexPreview.prefix(80))"
    }
}

extension Data {
    func hexStringUppercased() -> String {
        map { String(format: "%02X", $0) }.joined()
    }
}
