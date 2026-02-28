import XCTest
@testable import CodeBlog

final class TimeParsingTests: XCTestCase {
    func testValidTimes() {
        XCTAssertEqual(parseTimeHMMA(timeString: "9:30 AM"), 9 * 60 + 30)
        XCTAssertEqual(parseTimeHMMA(timeString: "11:59 PM"), 23 * 60 + 59)
    }

    func testInvalidTimes() {
        XCTAssertNil(parseTimeHMMA(timeString: ""))
        XCTAssertNil(parseTimeHMMA(timeString: "invalid"))
    }

    func testChatCompletionsURLNormalization() {
        XCTAssertEqual(
            LocalEndpointUtilities.chatCompletionsURL(baseURL: "https://api.openai.com")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            LocalEndpointUtilities.chatCompletionsURL(baseURL: "https://api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            LocalEndpointUtilities.chatCompletionsURL(baseURL: "https://api.openai.com/v1/models")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            LocalEndpointUtilities.chatCompletionsURL(baseURL: "https://openrouter.ai/api/vi")?.absoluteString,
            "https://openrouter.ai/api/v1/chat/completions"
        )
    }

    func testModelsURLNormalization() {
        XCTAssertEqual(
            LocalEndpointUtilities.modelsURL(baseURL: "https://api.openai.com")?.absoluteString,
            "https://api.openai.com/v1/models"
        )
        XCTAssertEqual(
            LocalEndpointUtilities.modelsURL(baseURL: "https://api.openai.com/v1/chat/completions")?.absoluteString,
            "https://api.openai.com/v1/models"
        )
        XCTAssertEqual(
            LocalEndpointUtilities.modelsURL(baseURL: "https://openrouter.ai/api/v1/model")?.absoluteString,
            "https://openrouter.ai/api/v1/models"
        )
    }

    func testAnthropicMessagesURLNormalization() {
        XCTAssertEqual(
            LocalEndpointUtilities.anthropicMessagesURL(baseURL: "https://api.anthropic.com")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            LocalEndpointUtilities.anthropicMessagesURL(baseURL: "https://api.anthropic.com/v1")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
    }
}
