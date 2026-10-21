//
//  StrictURLEncoder.swift
//  LocalBrainKit
//
//  Percent-encodes text for a URL query value so that nothing the user said can change the
//  shape of the URL. Only the RFC 3986 unreserved characters (letters, digits and - . _ ~) are
//  left as they are; every other character, including & = + / # ? and space, becomes %XX of its
//  UTF-8 bytes. Used by the draft and Bear links. The older BrowserCommandPlanner.encodedQuery
//  is looser (it keeps & = + / ? and others) and is left alone.
//
//  Line breaks are normalised first. A Gmail body takes %0A; a mailto body takes %0D%0A (RFC 6068).
//

import Foundation

public enum StrictURLEncoder {
    public enum LineBreak: Sendable {
        /// %0A, for Gmail's compose URL and Bear.
        case lf
        /// %0D%0A, for a mailto link.
        case crlf
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    private static let hex = Array("0123456789ABCDEF".utf8)

    public static func encode(_ text: String, lineBreak: LineBreak = .lf) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var output = ""
        for byte in normalized.utf8 {
            if unreserved.contains(byte) {
                output.unicodeScalars.append(Unicode.Scalar(byte))
            } else if byte == UInt8(ascii: "\n") {
                output += lineBreak == .lf ? "%0A" : "%0D%0A"
            } else {
                output += "%"
                output.unicodeScalars.append(Unicode.Scalar(hex[Int(byte >> 4)]))
                output.unicodeScalars.append(Unicode.Scalar(hex[Int(byte & 0x0F)]))
            }
        }
        return output
    }
}
