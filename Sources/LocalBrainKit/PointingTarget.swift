//
//  PointingTarget.swift
//  LocalBrainKit
//
//  What a pointing or click request is asking to find. The point prompt speaks
//  of one control ("click the settings gear"), so a request for a whole window
//  or app ("point out where the chat window is") gets one extra user-turn line,
//  LocalPrompts.windowTargetLine. The system prompt stays as measured; only a
//  request that names a window or an app and no control carries the line.
//

import Foundation

public enum PointingTarget {
    /// True when a pointing or click request names a window or app as the thing
    /// to find, and no control noun. "where is the save button in this app" is a
    /// control inside an app, so it is false.
    public static func namesWindow(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        guard text.range(of: windowObject, options: .regularExpression) != nil else { return false }
        return text.range(of: controlNoun, options: .regularExpression) == nil
    }

    private static let windowObject = #"\b(?:the|that|this|my|a|an|which)\s+(?:[a-z'-]+\s+){0,3}(?:window|app|application)s?\b"#
    private static let controlNoun = #"\b(?:button|menu|icon|toolbar|field|checkbox|dropdown|slider|tab|link|option|text box)s?\b"#
}
