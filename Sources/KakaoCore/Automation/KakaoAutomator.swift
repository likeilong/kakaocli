import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat by navigating the UI.
    public func sendMessage(to chatName: String, message: String, selfChat: Bool = false) throws {
        // 1. Ensure KakaoTalk is running and logged in
        let stateBefore = AppLifecycle.detectState()
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        if stateBefore != .loggedIn {
            Thread.sleep(forTimeInterval: 2.0)
        }

        // 2. Activate KakaoTalk and get windows
        try AXHelpers.activateApp(bundleId: Self.bundleId)
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)

        let windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }

        // 3. Close any existing chat windows to avoid sending to the wrong one
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 4. Ensure we're on the Chats tab
        if let chatroomsTab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
            _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 5. Find the chat row in the list
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound(chatName)
        }

        let row: AXUIElement
        if selfChat {
            guard let selfRow = AXHelpers.findSelfChatRow(table) else {
                throw AutomationError.chatNotFound("self-chat (나와의 채팅)")
            }
            row = selfRow
        } else {
            // **정확 일치로 찾는다.** 부분 일치(기본값)는 조용한 오발송을 만든다 —
            // 실측(2026-10-31): "이진영" 으로 보내면 같은 목록의
            // "이진영, 정지원 (정, 지원)- AMP 100, 주태영 (joo, taeyoung)-" 단톡방이
            // 먼저 걸릴 수 있다. 못 찾아 실패하는 쪽이 엉뚱한 사람에게 가는 것보다 낫다.
            guard let chatRow = AXHelpers.findChatRow(table, chatName: chatName, exact: true) else {
                throw AutomationError.chatNotFound(chatName)
            }
            row = chatRow
        }

        // 6. Open the chat via AX row selection + Enter (works even when off-screen).
        //    Falls back to scroll-into-view + double-click if selection fails.
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            Thread.sleep(forTimeInterval: 0.5)
            let checkWindows = AXHelpers.windows(app)
            opened = checkWindows.contains { AXHelpers.identifier($0) != "Main Window" }
        }
        if !opened {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.3)
            }
            AXHelpers.doubleClickElement(row)
        }

        // 7. Wait for the chat window to appear
        //
        // ⚠️ **창 제목이 보내려는 방과 같은지 반드시 확인한다.**
        //   예전에는 "메인 창이 아닌 첫 번째 창"을 집었는데, 이전 발송으로 **다른 방의
        //   채팅창이 열린 채 남아 있으면** 그게 먼저 잡혀 거기에 입력했다.
        //   2026-10-31 실측: 'Ai 인사이더 클럽' 으로 보낸 메시지가 열려 있던 '이진영'
        //   채팅창으로 들어갔고, kakaocli 는 성공(exit 0)이라고 보고했다. 방 찾기를
        //   정확 일치로 해도 이 단계에서 뒤집히면 소용이 없다.
        //   제목이 끝내 안 맞으면 **보내지 않고 실패한다** — 잘못 가는 것보다 낫다.
        var chatWindow: AXUIElement?
        let windowDeadline = Date().addingTimeInterval(5.0)
        while Date() < windowDeadline {
            Thread.sleep(forTimeInterval: 0.5)
            let updatedWindows = AXHelpers.windows(app)
            chatWindow = updatedWindows.first(where: {
                guard AXHelpers.identifier($0) != "Main Window" else { return false }
                guard !selfChat else { return true }  // 나와의 채팅은 제목을 예측할 수 없다
                return AXHelpers.title($0) == chatName
            })
            if chatWindow != nil { break }
        }
        guard let chatWindow else {
            throw AutomationError.chatWindowNotOpened(chatName)
        }

        // 8. Find the message input field.
        //    창이 뜬 직후에는 메시지 목록만 AX 트리에 올라와 있고 입력 영역은 조금 늦게
        //    붙는다. 한 번만 찾으면 그 틈에 걸려 "Could not find the message input field"
        //    로 끝난다(2026-10-31 실측: 덤프를 떠 보면 구조는 멀쩡했다 —
        //    AXScrollArea(_NS:47) > AXTextArea(desc="메시지 입력")). 그래서 잠깐 기다려 본다.
        var found: AXUIElement?
        let inputDeadline = Date().addingTimeInterval(5.0)
        repeat {
            found = findInputField(in: chatWindow)
            if found != nil { break }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < inputDeadline
        guard let inputField = found else {
            throw AutomationError.inputFieldNotFound
        }

        // 9. Focus and type the message
        _ = AXHelpers.performAction(chatWindow, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)

        // ⓐ 입력 직전 — 클릭할 창이 맞는지.
        try assertChatWindow(chatWindow, app: app, expect: chatName, selfChat: selfChat)

        AXHelpers.clickElement(inputField)
        Thread.sleep(forTimeInterval: 0.3)

        // ⓑ 타이핑 직전 — 클릭으로 포커스가 다른 데로 갔을 수 있다.
        try assertChatWindow(chatWindow, app: app, expect: chatName, selfChat: selfChat)

        if !AXHelpers.setValue(inputField, message) {
            _ = AXHelpers.focus(inputField)
            Thread.sleep(forTimeInterval: 0.1)
            AXHelpers.typeText(message)
        }
        Thread.sleep(forTimeInterval: 0.2)

        // ⓒ **Return 직전 — 마지막 관문.** 창·포커스를 다시 보고, 입력창에 실제로 내 본문이
        //    들어 있는지까지 확인한다. 여기서 틀리면 **누르지 않고 멈춘다.**
        //    Return 은 포커스된 곳으로 가므로 이 확인이 오발송을 막는 최후의 지점이다.
        try assertChatWindow(chatWindow, app: app, expect: chatName, selfChat: selfChat)
        let typed = AXHelpers.value(inputField) ?? ""
        if !typed.contains(message) {
            throw AutomationError.wrongWindow(
                expected: "input containing the message",
                actual: typed.isEmpty ? "(empty input)" : String(typed.prefix(40))
            )
        }

        AXHelpers.pressKey(keyCode: 36) // Return key

        // 10. Close the chat window
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(chatWindow)
    }

    /// Find the message input AXTextArea in a chat window.
    /// The input is in a top-level AXScrollArea that does NOT contain an AXTable (messages).

    /// "지금 이 창이 정말 그 방인가"를 다시 확인한다.
    ///
    /// 한 번만 확인하고 끝내면 그 사이 창이 바뀌어도 모른다. 사용자가 직접 카톡을 쓰고 있거나
    /// 다른 창이 끼어들면 실제로 그런 일이 생긴다(2026-10-31: 열려 있던 '이진영' 창으로
    /// 메시지가 들어갔다). 그래서 **입력 직전·전송 직전** 매 단계마다 본다.
    ///
    /// 제목뿐 아니라 **포커스 창**도 본다 — Return 키는 포커스된 곳으로 가므로, 제목이 맞아도
    /// 포커스가 옮겨가 있으면 엉뚱한 창으로 전송된다.
    private func assertChatWindow(
        _ window: AXUIElement, app: AXUIElement, expect chatName: String, selfChat: Bool
    ) throws {
        let title = AXHelpers.title(window) ?? ""
        if !selfChat && title != chatName {
            throw AutomationError.wrongWindow(expected: chatName, actual: title)
        }
        if let focused = AXHelpers.focusedWindow(app) {
            let ftitle = AXHelpers.title(focused) ?? ""
            if ftitle != title {
                throw AutomationError.wrongWindow(expected: title, actual: "focus=\(ftitle)")
            }
        }
    }

    private func findInputField(in window: AXUIElement) -> AXUIElement? {
        for child in AXHelpers.children(window) {
            guard AXHelpers.role(child) == "AXScrollArea" else { continue }
            // The message list scroll area contains an AXTable; the input one doesn't
            let hasTable = AXHelpers.children(child).contains { AXHelpers.role($0) == "AXTable" }
            if !hasTable {
                // This scroll area should contain the input AXTextArea
                for subchild in AXHelpers.children(child) {
                    if AXHelpers.role(subchild) == "AXTextArea" {
                        return subchild
                    }
                }
            }
        }
        return nil
    }

}

public enum AutomationError: Error, CustomStringConvertible {
    case noWindows
    case chatNotFound(String)
    /// 방은 찾아 열었는데 채팅창이 제때 뜨지 않음. 입력창 구조 문제와 구별해야
    /// 진단이 된다 — 둘을 같은 에러로 던지는 바람에 한참 헤맸다(2026-10-31).
    case chatWindowNotOpened(String)
    /// 입력 직전·전송 직전 재확인에서 대상 창이 아님이 드러난 경우.
    /// 한 번 확인하고 끝내면 그 뒤 창이 바뀌어도 모른다 — 그래서 단계마다 본다.
    case wrongWindow(expected: String, actual: String)
    case inputFieldNotFound
    case sendFailed(String)

    public var description: String {
        switch self {
        case .noWindows:
            return "KakaoTalk has no open windows"
        case .chatNotFound(let name):
            return "Chat '\(name)' not found in the chat list"
        case .chatWindowNotOpened(let name):
            return "Opened '\(name)' but its chat window did not appear in time"
        case .wrongWindow(let expected, let actual):
            return "Aborted before sending: expected chat window '\(expected)' but found '\(actual)'"
        case .inputFieldNotFound:
            return "Could not find the message input field"
        case .sendFailed(let msg):
            return "Failed to send message: \(msg)"
        }
    }
}
