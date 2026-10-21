import XCTest
@testable import LocalBrainKit

final class EmailDraftPlannerTests: XCTestCase {
    private func plan(_ words: String) -> EmailDraftRequest? { EmailDraftPlanner.request(from: words) }

    // MARK: - the owner's own words

    func testOpenAGmailDraftAndTellX() {
        XCTAssertEqual(plan("open a gmail draft and tell X i will get back to him"),
                       EmailDraftRequest(service: .gmail, kind: .new, useOpenDraft: false,
                                         recipient: .nameOnly("X"), gist: "i will get back to him"))
    }

    func testDraftAReplyToBobInMyGmail() {
        XCTAssertEqual(plan("draft a reply to Bob in my gmail"),
                       EmailDraftRequest(service: .gmail, kind: .reply, useOpenDraft: false,
                                         recipient: .nameOnly("Bob"), gist: ""))
    }

    func testUseTheCurrentDraftOnScreenNotANewOne() {
        XCTAssertEqual(plan("use the current draft on screen not create new draft"),
                       EmailDraftRequest(service: nil, kind: .new, useOpenDraft: true, recipient: .none, gist: ""))
    }

    func testASpelledAddressInADraft() {
        XCTAssertEqual(plan("draft an email to bob at example dot com saying i will get back to him"),
                       EmailDraftRequest(service: nil, kind: .new, useOpenDraft: false,
                                         recipient: .address("bob@example.com"), gist: "i will get back to him"))
    }

    func testAFastmailEmailToALetterSpelledAddress() {
        XCTAssertEqual(plan("write a fastmail email to b o b at example dot com tell him thanks"),
                       EmailDraftRequest(service: .fastmail, kind: .new, useOpenDraft: false,
                                         recipient: .address("bob@example.com"), gist: "thanks"))
    }

    func testTheOldOpenDraftPhraseIsNowADraftRequest() {
        let request = plan("go to my gmail and open up a draft")
        XCTAssertNil(request, "starts with go to, which is navigation, not a draft command")
        let opened = plan("open a new tab, go to my gmail, and open up a draft")
        XCTAssertEqual(opened?.service, .gmail)
        XCTAssertEqual(opened?.recipient, Recipient.none)
    }

    // MARK: - Service

    func testNoServiceNamedIsNilService() {
        XCTAssertNil(plan("draft an email to bob")?.service)
        XCTAssertEqual(plan("draft an email to bob")?.recipient, .nameOnly("bob"))
        XCTAssertNil(plan("open up a draft")?.service)
        XCTAssertNil(plan("write an email")?.service)
        XCTAssertNil(plan("compose an email")?.service)
    }

    func testServiceSpellings() {
        XCTAssertEqual(plan("draft an email in g mail")?.service, .gmail)
        XCTAssertEqual(plan("draft an email in gee mail")?.service, .gmail)
        XCTAssertEqual(plan("draft an email in google mail")?.service, .gmail)
        XCTAssertEqual(plan("draft an email in fast mail")?.service, .fastmail)
        XCTAssertEqual(plan("start a fastmail draft")?.service, .fastmail)
    }

    func testAServiceNamedInsideTheMessageIsNotTheService() {
        let request = plan("draft an email to bob saying check gmail")
        XCTAssertNil(request?.service)
        XCTAssertEqual(request?.gist, "check gmail")
    }

    // MARK: - Recipient and gist

    func testAGistAfterTellOrSaying() {
        XCTAssertEqual(plan("draft an email to bob saying i will get back to him")?.gist, "i will get back to him")
        XCTAssertEqual(plan("draft an email to bob and tell him i am late")?.gist, "i am late")
        XCTAssertEqual(plan("draft an email to bob that says thanks")?.gist, "thanks")
        XCTAssertEqual(plan("write an email: thanks for lunch")?.gist, "thanks for lunch")
    }

    func testTheServiceMentionIsNotPartOfTheGist() {
        let request = plan("draft an email to bob in my gmail saying hello there")
        XCTAssertEqual(request?.service, .gmail)
        XCTAssertEqual(request?.recipient, .nameOnly("bob"))
        XCTAssertEqual(request?.gist, "hello there")
    }

    func testAFormattedAddressWins() {
        let request = plan("compose an email to bob@example.com saying hi")
        XCTAssertEqual(request?.recipient, .address("bob@example.com"))
        XCTAssertEqual(request?.gist, "hi")
    }

    func testTellHimHasNoName() {
        let request = plan("start a gmail draft and tell him i am running late")
        XCTAssertEqual(request?.recipient, Recipient.none)
        XCTAssertEqual(request?.gist, "i am running late")
    }

    func testASubjectIsOnlyKeptWhenSpoken() {
        let request = plan("draft an email to bob with the subject lunch tomorrow saying are you free")
        XCTAssertEqual(request?.subject, "lunch tomorrow")
        XCTAssertEqual(request?.gist, "are you free")
        XCTAssertEqual(request?.recipient, .nameOnly("bob"))
        XCTAssertNil(plan("draft an email to bob saying are you free")?.subject)
    }

    func testReplyKindIsOnlyReadFromTheFrame() {
        XCTAssertEqual(plan("draft an email to bob saying i will reply tomorrow")?.kind, .new)
        XCTAssertEqual(plan("reply to bob in gmail")?.kind, .reply)
        XCTAssertEqual(plan("respond to bob in my fastmail")?.service, .fastmail)
    }

    func testWordsInTheGistCanBePlayOrYouTube() {
        let request = plan("draft an email to bob saying i will play the song on youtube")
        XCTAssertEqual(request?.gist, "i will play the song on youtube")
    }

    // MARK: - Open draft

    func testPhrasesForTheDraftThatIsAlreadyOpen() {
        for words in ["use the current draft", "use this draft", "use the existing draft", "use the draft on screen",
                      "fill the open draft", "use the draft i have open", "use the same draft"] {
            XCTAssertEqual(plan(words)?.useOpenDraft, true, words)
        }
        XCTAssertEqual(plan("open a gmail draft")?.useOpenDraft, false)
        XCTAssertEqual(plan("write a new draft")?.useOpenDraft, false)
    }

    // MARK: - Not a draft command

    func testFragmentsQuestionsAndNavigationAreNotDrafts() {
        for words in ["John in the email", "Open up, my Gmail in the browser", "open my email", "open gmail",
                      "go to my gmail", "where do i click to open a draft", "how do i draft an email",
                      "show me where the draft button is", "i started a draft yesterday", "what is a draft",
                      "write a poem for bob", "draft a speech", "tell bob i will get back to him",
                      "click the compose button", "what's in my email", "email", "draft", ""] {
            XCTAssertNil(plan(words), words)
        }
    }

    func testANoteInBearIsNotADraft() {
        XCTAssertNil(plan("write a note in bear: draft the email to bob"))
        XCTAssertNil(plan("make a bear note called email ideas"))
    }

    func testAddressWordsAndRequestFramesAreSkipped() {
        XCTAssertEqual(plan("hey clicky, can you please draft an email to bob saying hi")?.gist, "hi")
        XCTAssertEqual(plan("I want you to write an email to bob")?.recipient, .nameOnly("bob"))
        XCTAssertEqual(plan("could you open a gmail draft")?.service, .gmail)
    }

    // MARK: - Gist markers with the open draft

    func testEveryGistMarkerGivesTheMessageWhenAToFollowsIt() {
        let gist = "i will get back to him"
        for words in ["use the current draft in gmail saying i will get back to him",
                      "use the current draft in gmail that i will get back to him",
                      "use the current draft in gmail telling him i will get back to him",
                      "use the current draft in gmail telling her i will get back to him",
                      "use the current draft in gmail telling them i will get back to him",
                      "use the current draft in gmail tell him i will get back to him",
                      "use the current draft in gmail tell her i will get back to him",
                      "use the current draft in gmail tell them i will get back to him",
                      "use the current draft in gmail and say i will get back to him",
                      "use the current draft in gmail to say i will get back to him",
                      "use the current draft in gmail letting him know i will get back to him",
                      "use the current draft in gmail let him know i will get back to him"] {
            let request = plan(words)
            XCTAssertEqual(request?.gist, gist, words)
            XCTAssertEqual(request?.useOpenDraft, true, words)
            XCTAssertEqual(request?.service, .gmail, words)
            XCTAssertEqual(request?.recipient, Recipient.none, words)
        }
    }

    func testASayingWordBeforeAToKeepsTheRecipientOut() {
        XCTAssertEqual(plan("draft an email saying call me to confirm")?.gist, "call me to confirm")
        XCTAssertEqual(plan("draft an email saying call me to confirm")?.recipient, Recipient.none)
    }

    func testARecipientBeforeTheSayingWordStillWins() {
        let request = plan("draft an email to bob saying i will get back to him")
        XCTAssertEqual(request?.recipient, .nameOnly("bob"))
        XCTAssertEqual(request?.gist, "i will get back to him")
        XCTAssertEqual(plan("draft a reply to bob in my gmail that i will get back to him")?.gist, "i will get back to him")
    }

    func testThatIsOpenIsStillTheOpenDraftNotAMessage() {
        let request = plan("use the draft that is open in gmail and tell him thanks")
        XCTAssertEqual(request?.useOpenDraft, true)
        XCTAssertEqual(request?.gist, "thanks")
    }
}
