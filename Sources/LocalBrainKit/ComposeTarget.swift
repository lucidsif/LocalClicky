//
//  ComposeTarget.swift
//  LocalBrainKit
//
//  The link that opens a filled, unsent draft: Gmail's compose URL for Gmail (opened in Chrome,
//  in the background), a mailto link for Fastmail (opened in Fastmail.app, in the background).
//  A compose URL and a mailto link can only open a draft; neither can send. Every value goes
//  through StrictURLEncoder, so the words of a message cannot add a parameter.
//

import Foundation

public enum ComposeTarget {
    /// Gmail's account number in the compose URL (/u/N/): 0 is the first signed-in account.
    public static let defaultGmailAccountIndex = 0

    public static let chromeBundleIdentifier = "com.google.Chrome"
    public static let fastmailBundleIdentifier = WebPageReading.fastmailBundleIdentifier

    public static func gmailURL(to: String, subject: String, body: String,
                                accountIndex: Int = defaultGmailAccountIndex) -> String {
        "https://mail.google.com/mail/u/\(max(0, accountIndex))/?view=cm&fs=1&tf=1"
            + "&to=\(StrictURLEncoder.encode(to))&su=\(StrictURLEncoder.encode(subject))&body=\(StrictURLEncoder.encode(body, lineBreak: .lf))"
    }

    /// Gmail's search for mail from one person, as the page's own hash route: `#search/from%3Abob`. Opening it
    /// only searches; it does not touch a message.
    public static func gmailSearchURL(from person: String, accountIndex: Int = defaultGmailAccountIndex) -> String {
        "https://mail.google.com/mail/u/\(max(0, accountIndex))/#search/\(StrictURLEncoder.encode("from:" + person))"
    }

    /// `mailto:to?subject=&body=`. The address keeps its "@" (RFC 6068 allows it); every other
    /// reserved character in it is encoded.
    public static func mailtoURL(to: String, subject: String, body: String) -> String {
        let address = StrictURLEncoder.encode(to).replacingOccurrences(of: "%40", with: "@")
        return "mailto:\(address)?subject=\(StrictURLEncoder.encode(subject, lineBreak: .crlf))"
            + "&body=\(StrictURLEncoder.encode(body, lineBreak: .crlf))"
    }

    /// Where a draft opens and what opens it.
    public struct Opening: Equatable, Sendable {
        public let url: String
        public let bundleIdentifier: String
    }

    public static func opening(service: EmailService, to: String, subject: String, body: String,
                               gmailAccountIndex: Int = defaultGmailAccountIndex) -> Opening {
        switch service {
        case .gmail:
            return Opening(url: gmailURL(to: to, subject: subject, body: body, accountIndex: gmailAccountIndex),
                           bundleIdentifier: chromeBundleIdentifier)
        case .fastmail:
            return Opening(url: mailtoURL(to: to, subject: subject, body: body), bundleIdentifier: fastmailBundleIdentifier)
        }
    }
}
