import Foundation
import Testing
@testable import Newswire

struct BlockedHostsTests {
    @Test func knownPublisherIsBlockedIncludingSubdomains() {
        #expect(BlockedHosts.contains(URL(string: "https://seekingalpha.com/news/4500000-example")!))
        #expect(BlockedHosts.contains(URL(string: "https://www.seekingalpha.com/news/4500000-example")!))
        #expect(!BlockedHosts.contains(URL(string: "https://notseekingalpha.com/news/1")!))
    }

    @Test(arguments: ["Press & Hold to confirm you are a human (and not a bot).", "Access to this page has been denied", "Checking your browser before accessing"])
    func recognizesBotChecks(text: String) {
        #expect(BlockedHosts.isWall(text))
    }

    @Test func ordinaryArticleIsNotAWall() {
        #expect(!BlockedHosts.isWall("Shares rose 4% after the company raised its full-year guidance, citing strong demand for data center chips."))
    }
}
