@testable import MackyCore
import XCTest

final class ChatArchiveTests: XCTestCase {
    func testParsesClaudeExport() throws {
        let json = """
        [{"uuid":"a1","name":"Plan lansare curs","created_at":"2026-05-01T10:00:00.000000Z","updated_at":"2026-05-02T10:00:00Z",
          "chat_messages":[{"sender":"human","text":"Fă-mi un plan de lansare"},
                           {"sender":"assistant","text":"","content":[{"type":"text","text":"Iată planul: webinar gratuit"}]}]},
         {"uuid":"a2","name":"Gol","chat_messages":[]}]
        """
        let chats = try ChatArchiveKit.parseConversations(Data(json.utf8))
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].id, "claude-a1")
        XCTAssertEqual(chats[0].source, .claude)
        XCTAssertEqual(chats[0].messages, [
            ChatArchiveKit.Message(isFromUser: true, text: "Fă-mi un plan de lansare"),
            ChatArchiveKit.Message(isFromUser: false, text: "Iată planul: webinar gratuit")
        ])
        XCTAssertNotNil(chats[0].date)
    }

    func testParsesChatGPTExportFollowingTheCurrentBranch() throws {
        let json = """
        [{"title":"Reclame Meta","conversation_id":"c1","create_time":1700000000.5,"current_node":"n3",
          "mapping":{
            "root":{"id":"root","message":null,"parent":null,"children":["n1"]},
            "n1":{"id":"n1","parent":"root","children":["n2","old"],"message":{"author":{"role":"user"},"content":{"content_type":"text","parts":["Scrie o reclamă"]}}},
            "old":{"id":"old","parent":"n1","children":[],"message":{"author":{"role":"assistant"},"content":{"parts":["Varianta veche"]}}},
            "n2":{"id":"n2","parent":"n1","children":["n3"],"message":{"author":{"role":"system"},"content":{"parts":["hidden"]}}},
            "n3":{"id":"n3","parent":"n2","children":[],"message":{"author":{"role":"assistant"},"content":{"parts":["Varianta nouă"]}}}
          }}]
        """
        let chats = try ChatArchiveKit.parseConversations(Data(json.utf8))
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].id, "chatgpt-c1")
        XCTAssertEqual(chats[0].title, "Reclame Meta")
        XCTAssertEqual(chats[0].messages.map(\.text), ["Scrie o reclamă", "Varianta nouă"])
        XCTAssertEqual(chats[0].messages.map(\.isFromUser), [true, false])
    }

    func testRejectsOtherJSON() {
        XCTAssertThrowsError(try ChatArchiveKit.parseConversations(Data(#"{"a":1}"#.utf8)))
        XCTAssertThrowsError(try ChatArchiveKit.parseConversations(Data(#"[{"a":1}]"#.utf8)))
    }

    func testParsesClaudeProjectsAndMakesASkill() throws {
        let json = """
        [{"uuid":"p1","name":"Fondatorii Ads","description":"Reclame pentru Fondatorii","prompt_template":"Scrie în vocea Fondatorii.",
          "docs":[{"filename":"ton.md","content":"Direct, cald."},{"filename":"gol.md","content":""}]}]
        """
        let projects = try ChatArchiveKit.parseClaudeProjects(Data(json.utf8))
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].documents.count, 1)
        let markdown = ChatArchiveKit.skillMarkdown(for: projects[0])
        let skill = SkillParser.parse(markdown: markdown, fallbackName: "x", sourcePath: "/tmp/x")
        XCTAssertEqual(skill?.name, "Fondatorii Ads")
        XCTAssertTrue(markdown.contains("Scrie în vocea Fondatorii."))
        XCTAssertTrue(markdown.contains("## ton.md"))
    }

    func testSearchNeedsEveryWordAndPrefersTitles() {
        let chats = [
            ChatArchiveKit.Chat(id: "1", source: .claude, title: "Buget marketing", date: Date(timeIntervalSince1970: 1),
                                messages: [.init(isFromUser: true, text: "Cât alocăm pentru reclame în octombrie?")]),
            ChatArchiveKit.Chat(id: "2", source: .chatGPT, title: "Idei", date: Date(timeIntervalSince1970: 2),
                                messages: [.init(isFromUser: true, text: "Un buget mic pentru reclame TikTok")]),
            ChatArchiveKit.Chat(id: "3", source: .chatGPT, title: "Rețete", date: nil,
                                messages: [.init(isFromUser: true, text: "Supă de linte")])
        ]
        let hits = ChatArchiveKit.search("buget reclame", in: chats)
        XCTAssertEqual(hits.map(\.chat.id), ["1", "2"])
        XCTAssertTrue(hits[1].snippet.contains("buget"))
        XCTAssertTrue(ChatArchiveKit.search("supa", in: chats).map(\.chat.id) == ["3"])
        XCTAssertTrue(ChatArchiveKit.search("x", in: chats).isEmpty)
    }

    func testTranscriptIsCut() {
        let chat = ChatArchiveKit.Chat(id: "1", source: .claude, title: "Lung", date: nil,
                                       messages: [.init(isFromUser: true, text: String(repeating: "a", count: 5000)),
                                                  .init(isFromUser: false, text: String(repeating: "b", count: 5000))])
        let text = ChatArchiveKit.transcript(chat, maximumCharacters: 2000)
        XCTAssertTrue(text.contains("omis"))
        XCTAssertLessThan(text.count, 2200)
        XCTAssertEqual(ChatArchiveKit.bestTitleMatch("lun", in: [chat], name: \.title)?.id, "1")
    }

    func testPastChatToolsParse() {
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "1", name: "search_past_chats", argumentsJSON: #"{"query":"buget"}"#)),
                       .searchPastChats(query: "buget"))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "1", name: "read_past_chat", argumentsJSON: #"{"title":"Idei"}"#)),
                       .readPastChat(title: "Idei"))
        XCTAssertTrue(ScreenAction.readPastChat(title: "x").isReadOnly)
    }
}
