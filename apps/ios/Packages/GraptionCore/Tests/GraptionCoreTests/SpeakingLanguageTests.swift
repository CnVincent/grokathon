import XCTest
@testable import GraptionCore

final class SpeakingLanguageTests: XCTestCase {
    func testSpanishAndEnglishStayDistinct() {
        XCTAssertEqual(SpeakingLanguage.canonical(" EN "), "en")
        XCTAssertEqual(SpeakingLanguage.canonical("es-mx"), "es-MX")
        XCTAssertNil(SpeakingLanguage.canonical("auto"))
        XCTAssertNil(SpeakingLanguage.canonical("zz"))
        XCTAssertTrue(SpeakingLanguage.sameSpokenLanguage("en", "en"))
        XCTAssertTrue(SpeakingLanguage.sameSpokenLanguage("es-MX", "es-ES"))
        XCTAssertFalse(SpeakingLanguage.sameSpokenLanguage("en", "es-MX"))
        XCTAssertFalse(SpeakingLanguage.sameSpokenLanguage("en", "zz"))
        XCTAssertEqual(SpeakingLanguage.named("es-MX"), "Spanish (Mexico)")
    }

    func testVoiceIDsAcceptBuiltInsAndCustomIDs() {
        XCTAssertEqual(SpeakingVoice.canonical(" Eve "), "eve")
        XCTAssertEqual(SpeakingVoice.canonical("abc123xy"), "abc123xy")
        XCTAssertNil(SpeakingVoice.canonical(""))
        XCTAssertNil(SpeakingVoice.canonical("../eve"))
        XCTAssertNil(SpeakingVoice.canonical("my voice"))
    }
}
