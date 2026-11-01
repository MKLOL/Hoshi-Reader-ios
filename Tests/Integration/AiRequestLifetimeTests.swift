import XCTest
@testable import Hoshi_Reader

nonisolated final class AiRequestLifetimeTests: XCTestCase {
    @MainActor func testDismissalLeavesRequestRunningAndReplyDoesNotReopenPopup() {
        let registry = AiChatRequests()
        let item = registry.request(key: "book:bubble", bookKey: "book", bubbleText: "猫") { _ in }
        let popup = MangaAiController()
        popup.follow(item)
        XCTAssertTrue(popup.isPresented)
        popup.dismiss()
        XCTAssertTrue(item.isRunning)
        registry.update(item, state: .result(reply()), backend: "Test")
        XCTAssertFalse(popup.isPresented)
        XCTAssertFalse(item.seen)
    }

    @MainActor func testConcurrentPopupsOwnTheirObservers() {
        let registry = AiChatRequests()
        let item = registry.request(key: "book:bubble", bookKey: "book", bubbleText: "猫") { _ in }
        let first = MangaAiController(), second = MangaAiController()
        first.follow(item); second.follow(item)
        first.dismiss()
        registry.update(item, state: .result(reply()), backend: "Test")
        XCTAssertFalse(first.isPresented)
        XCTAssertEqual(second.state, .result(reply()))
        XCTAssertTrue(item.seen)
    }

    @MainActor func testIdenticalRunningOrUnseenRequestIsJoinedWithoutAnotherStart() {
        let registry = AiChatRequests()
        var starts = 0
        let start: @MainActor (AiChatRequest) -> Void = { _ in starts += 1 }
        let first = registry.request(key: "a", bookKey: "book", bubbleText: "猫", start: start)
        let second = registry.request(key: "a", bookKey: "book", bubbleText: "猫", force: true, start: start)
        XCTAssertTrue(first === second)
        registry.update(first, state: .result(reply()), backend: "Test")
        let unseen = registry.request(key: "a", bookKey: "book", bubbleText: "猫", start: start)
        XCTAssertTrue(first === unseen)
        XCTAssertEqual(starts, 1)
        let explicit = registry.request(key: "a", bookKey: "book", bubbleText: "猫", force: true, start: start)
        XCTAssertFalse(first === explicit)
        XCTAssertEqual(starts, 2)
        registry.update(explicit, state: .result(reply()), backend: "Test")
    }

    @MainActor func testDistinctRequestsContinueAndFailedRequestCanRetry() {
        let registry = AiChatRequests()
        var starts = 0
        let first = registry.request(key: "a", bookKey: "book", bubbleText: "猫") { _ in starts += 1 }
        let second = registry.request(key: "b", bookKey: "book", bubbleText: "犬") { _ in starts += 1 }
        XCTAssertTrue(first.isRunning); XCTAssertTrue(second.isRunning)
        registry.update(first, state: .error("Offline"), backend: "Test")
        first.retry?()
        XCTAssertTrue(first.isRunning); XCTAssertEqual(starts, 3)
        registry.update(first, state: .error("Offline"), backend: "Test")
        registry.dismissFailure(first)
        XCTAssertEqual(registry.requests.count, 1)
        registry.update(second, state: .result(reply()), backend: "Test")
    }

    private func reply() -> AiChatEntry {
        .init(bubbleText: "猫", prompt: "Translate", model: "test", response: "Cat", timestampSeconds: 1)
    }
}
