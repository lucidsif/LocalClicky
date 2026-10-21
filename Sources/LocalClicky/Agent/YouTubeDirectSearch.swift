//
//  YouTubeDirectSearch.swift
//  LocalClicky
//
//  Fetches youtube's own search page for the spoken query so a run can name the video it would
//  play before anything is opened. It is the same GET Chrome would make for that address, from an
//  ephemeral session: no cookies, no cache, no account, a 5 s limit. Only the spoken query (inside
//  the address) leaves the Mac; no screen, voice or page data is sent. The page is read by
//  YouTubeSearchResults (LocalBrainKit); any failure is an empty result and the run falls back to
//  opening the page in Chrome.
//

import Foundation
import LocalBrainKit

enum YouTubeDirectSearch {

    struct Outcome {
        let results: [DirectResult]
        let millis: Int
        /// Why there are no results, nil when there are some. Never page text.
        let error: String?
    }

    static let timeoutSeconds: Double = 5
    private static let maxResponseBytes = 8_000_000
    private static let allowedHost = "www.youtube.com"
    // A desktop Chrome user agent: without one youtube serves a different, script-light page.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"

    static func fetch(searchURL: String) async -> Outcome {
        let started = ContinuousClock.now
        func outcome(_ results: [DirectResult], _ error: String?) -> Outcome {
            let elapsed = ContinuousClock.now - started
            let millis = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return Outcome(results: results, millis: millis, error: error)
        }
        guard let url = URL(string: searchURL), url.scheme == "https", url.host == allowedHost else {
            return outcome([], "not a youtube search address")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return outcome([], "http \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard data.count <= maxResponseBytes, let html = String(data: data, encoding: .utf8) else {
                return outcome([], "response not readable")
            }
            let results = YouTubeSearchResults.parse(html: html)
            return outcome(results, results.isEmpty ? "no results in the page" : nil)
        } catch {
            return outcome([], (error as? URLError).map { "url error \($0.code.rawValue)" } ?? "request failed")
        }
    }
}
