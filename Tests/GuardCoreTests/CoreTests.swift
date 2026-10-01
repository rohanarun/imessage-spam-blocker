import XCTest
@testable import GuardCore
final class CoreTests: XCTestCase {
    func testAmbiguousJudgmentCannotBlock() {
        XCTAssertFalse(Judgment(choice:"review",confidence:1,probabilities:["review":1]).shouldBlock(minimum:0.95))
        XCTAssertFalse(Judgment(choice:"block",confidence:0.6,probabilities:["block":0.8]).shouldBlock(minimum:0.95))
        XCTAssertFalse(Judgment(choice:"block",confidence:.nan,probabilities:["block":1]).shouldBlock(minimum:0.95))
        XCTAssertTrue(Judgment(choice:"block",confidence:0.99,probabilities:["block":0.99]).shouldBlock(minimum:0.95))
    }
    func testUndoHistoryAndCursorSurviveRestart() throws {
        var store=Store();store.allowed.insert("test@example.invalid");store.processed.insert("same-time-guid");store.cursor=42
        store.records=[BlockRecord(sender:"test@example.invalid",messageID:"a",excerpt:"evidence",state:"pending",judgment:Judgment(choice:"block",confidence:1,probabilities:["block":1]))]
        let restored=try JSONDecoder().decode(Store.self,from:JSONEncoder().encode(store))
        XCTAssertEqual(restored.records[0].state,"pending");XCTAssertEqual(restored.allowed,store.allowed);XCTAssertEqual(restored.processed,store.processed);XCTAssertEqual(restored.cursor,42)
    }
    func testPhotonWireFormat() throws {
        let wire=Data(#"[{"guid":"a","text":"hi","isFromMe":false,"dateCreated":42,"handle":{"address":"test@example.invalid"},"chatKind":"dm"}]"#.utf8)
        let messages=try JSONDecoder().decode([Message].self,from:wire)
        XCTAssertEqual(messages[0].chatKind,"dm");XCTAssertEqual(messages[0].handle?.address,"test@example.invalid")
    }
    func testProviderMigrationKeepsOldSettings() throws {
        let old=Data(#"{"model":"jev-latest","interval":12,"minimumConfidence":0.97,"policy":"custom policy"}"#.utf8)
        let settings=try JSONDecoder().decode(Settings.self,from:old)
        XCTAssertEqual(settings.provider,.typesafe)
        XCTAssertEqual(settings.policy,"custom policy")
        XCTAssertEqual(settings.interval,12)
        XCTAssertEqual(settings.openRouterModel,"typesafe/jev-1.13")
    }
    func testOpenRouterDecisionRequestAndSeparateDirectRequest() throws {
        let message=try JSONDecoder().decode(Message.self,from:Data(#"{"guid":"a","text":"test","isFromMe":false,"handle":{"address":"test@example.invalid"}}"#.utf8))
        var settings=Settings();settings.provider = .openrouter
        let request=try Jev(settings:settings,key:"test-openrouter-key").makeRequest(message,context:[])
        XCTAssertEqual(request.url?.absoluteString,"https://openrouter.ai/api/alpha/decisions")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-openrouter-key")
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with:request.httpBody!) as? [String:Any])
        XCTAssertEqual(body["model"] as? String,"typesafe/jev-1.13")
        XCTAssertNotNil(body["questions"])
        settings.provider = .typesafe
        let direct=try Jev(settings:settings,key:"test-direct-key").makeRequest(message,context:[])
        XCTAssertEqual(direct.url?.host,"api.typesafe.ai")
        XCTAssertEqual(direct.value(forHTTPHeaderField:"Authorization"),"Bearer test-direct-key")
        let roundTrip=try JSONDecoder().decode(Settings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.provider,.typesafe)
    }
    func testKeychainCredentialPersistsAcrossIndependentReads() throws {
        let name="persistence-test-" + UUID().uuidString
        defer {try? Keychain.save("",name:name)}
        try Keychain.save("synthetic-test-key",name:name)
        XCTAssertEqual(Keychain.read(name),"synthetic-test-key")
        try Keychain.save("updated-synthetic-key",name:name)
        XCTAssertEqual(Keychain.read(name),"updated-synthetic-key")
    }
}
