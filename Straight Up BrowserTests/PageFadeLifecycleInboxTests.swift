import Testing
@testable import Browser

struct PageFadeLifecycleInboxTests {
    @Test func batchesKeepIngressOrderAndAreConsumedOnce() {
        let inbox = PageFadeLifecycleInbox()
        inbox.append(.suspend("system"))
        inbox.append(.suspend("display"))
        inbox.append(.resume("system"))
        #expect(inbox.takePending() == [.suspend("system"), .suspend("display"), .resume("system")])
        #expect(inbox.takePending().isEmpty)
        inbox.append(.resume("display"))
        #expect(inbox.takePending() == [.resume("display")])
    }

    @Test func appendsDuringProcessingStayBehindTheCurrentBatch() {
        let inbox = PageFadeLifecycleInbox()
        inbox.append(.suspend("system"))
        inbox.append(.resume("system"))
        let processing = inbox.takePending()
        inbox.append(.visibility)
        #expect(processing == [.suspend("system"), .resume("system")])
        #expect(inbox.takePending() == [.visibility])
    }

    @Test func concurrentProducersDoNotLoseOrDuplicateEvents() async {
        let inbox = PageFadeLifecycleInbox()
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for value in 0..<100 { inbox.append(.suspend("\(producer):\(value)")) }
                }
            }
        }
        let events = inbox.takePending()
        let reasons = events.compactMap { event -> String? in
            if case .suspend(let reason) = event { return reason }
            return nil
        }
        #expect(events.count == 400)
        #expect(Set(reasons).count == 400)
        #expect(inbox.takePending().isEmpty)
    }
}
