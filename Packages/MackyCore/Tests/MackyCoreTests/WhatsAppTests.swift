import XCTest
@testable import MackyCore

final class WhatsAppTests: XCTestCase {
    func testPhoneNumbers() {
        XCTAssertEqual(WhatsAppKit.phoneNumber(fromJID: "40722111222@s.whatsapp.net"), "40722111222")
        XCTAssertNil(WhatsAppKit.phoneNumber(fromJID: "120363000000@g.us"))
        XCTAssertEqual(WhatsAppKit.normalizedPhoneNumber("0722 111 222"), "40722111222")
        XCTAssertEqual(WhatsAppKit.normalizedPhoneNumber("+44 7700 900123"), "447700900123")
        XCTAssertEqual(WhatsAppKit.normalizedPhoneNumber("0040722111222"), "40722111222")
        XCTAssertNil(WhatsAppKit.normalizedPhoneNumber("Andrei"))
        XCTAssertNil(WhatsAppKit.normalizedPhoneNumber("123"))
        let url = WhatsAppKit.sendURL(phoneNumber: "40722111222", text: "Salut, ajung la 5 & jumătate")!
        XCTAssertEqual(url.scheme, "whatsapp")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value, "Salut, ajung la 5 & jumătate")
    }

    func testChatMatchingAndText() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let chats = [
            WhatsAppKit.Chat(name: "Andrei Popescu", jid: "40711@s.whatsapp.net", unreadCount: 2, lastMessageDate: now.addingTimeInterval(-60), lastMessageText: "Ne vedem?"),
            WhatsAppKit.Chat(name: "Andreea", jid: "40722@s.whatsapp.net", unreadCount: 0, lastMessageDate: now.addingTimeInterval(-3600), lastMessageText: nil),
            WhatsAppKit.Chat(name: "Echipa Fondatorii", jid: "1203@g.us", unreadCount: 5, lastMessageDate: now, lastMessageText: "ok")
        ]
        XCTAssertEqual(WhatsAppKit.bestChat(named: "andrei", in: chats)?.name, "Andrei Popescu")
        XCTAssertEqual(WhatsAppKit.bestChat(named: "Andreea", in: chats)?.name, "Andreea")
        XCTAssertEqual(WhatsAppKit.bestChat(named: "fondatorii", in: chats)?.name, "Echipa Fondatorii")
        XCTAssertNil(WhatsAppKit.bestChat(named: "Ioana", in: chats))
        XCTAssertTrue(chats[2].isGroup)
        let list = WhatsAppKit.chatListText(chats, now: now)
        XCTAssertTrue(list.contains("Andrei Popescu · 2 necitite"))
        XCTAssertTrue(list.contains("Echipa Fondatorii (grup)"))
        let transcript = WhatsAppKit.transcript([
            WhatsAppKit.Message(date: now, isFromMe: true, sender: nil, text: "Da"),
            WhatsAppKit.Message(date: now.addingTimeInterval(-30), isFromMe: false, sender: "Ana", text: "Vii?")
        ], now: now)
        XCTAssertTrue(transcript.hasSuffix("] Eu: Da"))
        XCTAssertTrue(transcript.contains("] Ana: Vii?"))
        XCTAssertEqual(WhatsAppKit.placeholder(forMessageType: 3), "[mesaj vocal]")
        XCTAssertEqual(WhatsAppKit.date(fromDatabaseTimestamp: 0), Date(timeIntervalSinceReferenceDate: 0))
    }

    func testToolCalls() {
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "1", name: "whatsapp_send", argumentsJSON: #"{"to":"Andrei","text":"Ajung la 5"}"#)),
                       .whatsAppSend(to: "Andrei", text: "Ajung la 5"))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "2", name: "whatsapp_chats", argumentsJSON: #"{"unread_only":true}"#)),
                       .whatsAppChats(unreadOnly: true, limit: 15))
        XCTAssertEqual(ScreenAction.whatsAppSend(to: "a", text: "b").isReadOnly, false)
        XCTAssertEqual(ScreenAction.whatsAppRead(chat: "a", limit: 5).isReadOnly, true)
    }
}
