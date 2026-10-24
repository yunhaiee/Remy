import XCTest
@testable import RemyCore

final class VoiceCommandTests: XCTestCase {
    private func parse(_ text: String, _ phase: CookingSession.Phase = .cooking, recent: Bool = false) -> VoiceCommand {
        VoiceCommand.parse(text, phase: phase, secondsSinceChefSpoke: recent ? 3 : 60)
    }
    func testOnlySpeechForTheChefCounts() {
        XCTAssertEqual(parse("Did you see the game last night? It was crazy.").intent, .ignore)
        XCTAssertEqual(parse("Totally darling, it's crazy. Chef.", .needsDish).intent, .ignore, "the wake word must come first")
        XCTAssertEqual(parse("Not too salty, please.", recent: true), .init(intent: .agent, value: "not too salty please"))
        XCTAssertEqual(parse("Chef.", .ingredients).intent, .wake)
        XCTAssertTrue(VoiceCommand.startsWithWakeWord("Hey Chef, it's burning"))
        XCTAssertTrue(VoiceCommand.startsWithWakeWord("Okay Remy, it's burning"))
        XCTAssertEqual(parse("Remi, next step").intent, .next)
        XCTAssertFalse(VoiceCommand.startsWithWakeWord("Ready"))
    }
    func testBareCommandsSkipTheModel() {
        XCTAssertEqual(parse("Chef, next step please.").intent, .next)
        XCTAssertEqual(parse("Chef, go back").intent, .previous)
        XCTAssertEqual(parse("Chef, say that again").intent, .repeat)
        XCTAssertEqual(parse("Chef, let's start cooking", .ingredients).intent, .startCooking)
        XCTAssertEqual(parse("Okay, done. What's next?", recent: true).intent, .agent, "a sentence, not a bare command")
    }
    func testSentencesGoToTheChefWhole() {
        XCTAssertEqual(parse("Chef, I still see red wine vinegar in the ingredients list. Can you change that?", .ingredients),
                       .init(intent: .agent, value: "i still see red wine vinegar in the ingredients list can you change that"))
        XCTAssertEqual(parse("Chef, let's me call pasta salad today", .needsDish).intent, .agent)
        XCTAssertEqual(parse("Chef, where's the salt?").intent, .agent)
        XCTAssertEqual(parse("Chef, I'm done chopping, what's next?").intent, .agent)
    }
}
