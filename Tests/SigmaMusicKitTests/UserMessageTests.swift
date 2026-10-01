import Foundation
import Testing
@testable import SigmaMusicKit

struct UserMessageTests {
    @Test func httpStatuses() {
        #expect(userMessage(for: MusicServiceError.http(status: 404, path: "/x")) == "找不到这个资源（404）")
        #expect(userMessage(for: MusicServiceError.http(status: 403, path: "/x")).contains("403"))
        #expect(userMessage(for: MusicServiceError.http(status: 503, path: "/x")).contains("服务器出错"))
        #expect(userMessage(for: MusicServiceError.http(status: 418, path: "/x")) == "服务器返回了 418")
    }

    @Test func neteaseCodes() {
        #expect(userMessage(for: MusicServiceError.rejected(code: 301)).contains("登录"))
        #expect(userMessage(for: MusicServiceError.rejected(code: -460)).contains("风控"))
        #expect(userMessage(for: MusicServiceError.rejected(code: 123)).contains("123"))
    }

    @Test func otherServiceErrors() {
        #expect(userMessage(for: MusicServiceError.malformedResponse("x")).contains("无法识别"))
        #expect(userMessage(for: MusicServiceError.invalidTrack("qq:1")).contains("网易云"))
        #expect(userMessage(for: MusicServiceError.offline).contains("没有联网"))
    }

    @Test func networkProblems() {
        #expect(userMessage(for: URLError(.notConnectedToInternet)).contains("没有网络"))
        #expect(userMessage(for: URLError(.networkConnectionLost)).contains("没有网络"))
        #expect(userMessage(for: URLError(.timedOut)).contains("超时"))
        #expect(userMessage(for: URLError(.cannotFindHost)).contains("连不上"))
        #expect(userMessage(for: URLError(.secureConnectionFailed)).contains("安全连接"))
    }

    @Test func anythingElseKeepsItsOwnWords() {
        struct Oops: LocalizedError { var errorDescription: String? { "boom" } }
        #expect(userMessage(for: Oops()) == "boom")
    }
}
