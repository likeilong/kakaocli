import ArgumentParser
import Foundation
import KakaoCore

/// Download message attachments (photos, videos, files) from KakaoTalk's CDN.
///
/// KakaoTalk stores only attachment *metadata* locally (signed CDN URLs), not the
/// files themselves. Those URLs carry an `expire` timestamp, so only reasonably
/// recent attachments are downloadable; expired ones are skipped (see `--force`).
/// To refresh expired URLs, open the chat in KakaoTalk (or run `kakaocli harvest
/// --scroll`, which needs Accessibility permission + the app running), then retry.
struct DownloadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download message attachments (photos, videos, files) from KakaoTalk CDN"
    )

    @Option(name: .long, help: "Filter by chat name (substring match)")
    var chat: String?

    @Option(name: .long, help: "Filter by chat ID")
    var chatId: Int64?

    @Option(name: .long, help: "Only attachments newer than (e.g. 24h, 7d)")
    var since: String?

    @Option(name: .long, help: "Max messages with attachments to scan")
    var limit: Int = 100

    @Option(name: .long, help: "Output directory")
    var out: String = "./kakao-downloads"

    @Flag(name: .long, help: "List attachments only; do not download")
    var list = false

    @Flag(name: .long, help: "Try downloading even if the signed URL appears expired")
    var force = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    // MARK: - Model

    struct Item {
        let logId: Int64
        let chatId: Int64
        let kind: String       // photo | video | file
        let url: String
        let fileName: String   // final, filesystem-safe name (with extension)
        let size: Int64
        let checksum: String?
        let expired: Bool
        let date: Date
    }

    // MARK: - Run

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        // Resolve chat filter + build a chatId -> readable folder-name map.
        let chats = try reader.chats(limit: 400)
        var names: [Int64: String] = [:]
        for c in chats where c.displayName != "(unknown)" { names[c.id] = c.displayName }

        var resolvedChatId = chatId
        if let chatName = chat, resolvedChatId == nil {
            guard let found = chats.first(where: {
                $0.displayName.localizedCaseInsensitiveContains(chatName)
            }) else {
                throw ValidationError("Chat '\(chatName)' not found.")
            }
            resolvedChatId = found.id
        }

        var conds = ["attachment LIKE '%\"url\"%'"]
        if let cid = resolvedChatId { conds.append("chatId = \(cid)") }
        if let s = since, let d = parseDuration(s) {
            conds.append("sentAt >= \(Int64(d.timeIntervalSince1970))")
        }
        let sql = """
            SELECT logId, chatId, type, attachment, sentAt
            FROM NTChatMessage
            WHERE \(conds.joined(separator: " AND "))
            ORDER BY sentAt DESC LIMIT \(limit)
            """
        let rows = try reader.rawQuery(sql)

        let now = Date().timeIntervalSince1970
        var items: [Item] = []
        for row in rows where row.count >= 5 {
            let logId = row[0] as? Int64 ?? 0
            let cid = row[1] as? Int64 ?? 0
            let type = Int(row[2] as? Int64 ?? 0)
            let attStr = row[3] as? String ?? ""
            let sentAt = row[4] as? Int64 ?? 0
            if let it = Self.parse(logId: logId, chatId: cid, type: type,
                                   attachment: attStr, now: now,
                                   date: Date(timeIntervalSince1970: Double(sentAt))) {
                items.append(it)
            }
        }

        func folder(_ chatId: Int64) -> String {
            if let n = names[chatId] { return "\(Self.sanitize(n)) (\(chatId))" }
            return String(chatId)
        }

        if list {
            report(items, statuses: items.map { _ in "listed" }, folder: folder)
            return
        }
        if items.isEmpty {
            report([], statuses: [], folder: folder)
            return
        }

        // Download.
        let fm = FileManager.default
        var statuses: [String] = []
        var seenChecksums = Set<String>()
        for it in items {
            if it.expired && !force { statuses.append("expired-skip"); continue }
            if let cs = it.checksum, seenChecksums.contains(cs) { statuses.append("dup-skip"); continue }

            let dir = (out as NSString).appendingPathComponent(folder(it.chatId))
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let dest = (dir as NSString).appendingPathComponent(it.fileName)

            if fm.fileExists(atPath: dest) {
                statuses.append("exists")
                if let cs = it.checksum { seenChecksums.insert(cs) }
                continue
            }
            guard let url = URL(string: it.url) else { statuses.append("bad-url"); continue }
            do {
                let data = try Data(contentsOf: url)
                try data.write(to: URL(fileURLWithPath: dest))
                statuses.append("ok(\(data.count))")
                if let cs = it.checksum { seenChecksums.insert(cs) }
            } catch {
                statuses.append("fail") // expired/revoked URLs typically 403 here
            }
        }

        writeManifest(items: items, statuses: statuses, folder: folder)
        report(items, statuses: statuses, folder: folder)
    }

    // MARK: - Parsing

    /// Returns a downloadable Item for supported media types, or nil to skip.
    static func parse(logId: Int64, chatId: Int64, type: Int, attachment: String,
                      now: TimeInterval, date: Date) -> Item? {
        guard let data = attachment.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["url"] as? String, !url.isEmpty else { return nil }

        let kind: String
        switch type {
        case 2: kind = "photo"
        case 3: kind = "video"
        case 18: kind = "file"
        default: return nil // contacts(4)/stickers(6)/votes(24)/etc. are not downloadable files
        }

        let size = num(obj["s"]) ?? num(obj["size"]) ?? 0
        // KakaoTalk sometimes stores "cs":"" (empty). Treat that as absent, otherwise the
        // filename becomes ".jpg" (a hidden file) and every empty-cs item collides as dup-skip.
        let checksum = (obj["cs"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let mt = obj["mt"] as? String
        let originalName = obj["name"] as? String

        // Expiry: photos use seconds (10 digits), video/file use milliseconds (13 digits).
        var expired = false
        if let exp = num(obj["expire"]).map(Double.init) {
            let expSec = exp > 1_000_000_000_000 ? exp / 1000 : exp
            expired = expSec < now
        }

        let ext = fileExtension(kind: kind, mt: mt, name: originalName)
        let fileName: String
        if kind == "file", let n = originalName, !n.isEmpty {
            fileName = "\(logId)_\(sanitize(n))" // keep original name, prefix logId for uniqueness
        } else {
            fileName = "\(checksum ?? String(logId)).\(ext)"
        }

        return Item(logId: logId, chatId: chatId, kind: kind, url: url,
                    fileName: fileName, size: size, checksum: checksum,
                    expired: expired, date: date)
    }

    static func num(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let i = v as? Int64 { return i }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    static func fileExtension(kind: String, mt: String?, name: String?) -> String {
        if kind == "file", let name, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[name.index(after: dot)...])
        }
        if let mt = mt?.lowercased() {
            if mt.contains("png") { return "png" }
            if mt.contains("jpeg") || mt.contains("jpg") { return "jpg" }
            if mt.contains("gif") { return "gif" }
            if mt.contains("webp") { return "webp" }
            if mt.contains("mp4") { return "mp4" }
        }
        switch kind {
        case "video": return "mp4"
        case "photo": return "jpg"
        default: return "bin"
        }
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: bad).joined(separator: "_")
    }

    // MARK: - Output

    func writeManifest(items: [Item], statuses: [String], folder: (Int64) -> String) {
        var entries: [[String: Any]] = []
        for (it, st) in zip(items, statuses) {
            entries.append([
                "logId": it.logId, "chatId": it.chatId, "kind": it.kind,
                "file": "\(folder(it.chatId))/\(it.fileName)", "size": it.size,
                "checksum": it.checksum ?? "", "expired": it.expired,
                "date": ISO8601DateFormatter().string(from: it.date), "status": st,
            ])
        }
        let path = (out as NSString).appendingPathComponent("manifest.json")
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func report(_ items: [Item], statuses: [String], folder: (Int64) -> String) {
        if json {
            let arr = zip(items, statuses).map { it, st -> [String: Any] in
                [
                    "logId": it.logId, "chatId": it.chatId, "kind": it.kind,
                    "folder": folder(it.chatId), "fileName": it.fileName,
                    "size": it.size, "expired": it.expired,
                    "date": ISO8601DateFormatter().string(from: it.date), "status": st,
                ]
            }
            JSONOutput.printArray(arr)
            return
        }
        if items.isEmpty { print("No downloadable attachments found."); return }

        for (it, st) in zip(items, statuses) {
            let flag = it.expired ? "⏳expired " : ""
            let mb = String(format: "%.1fMB", Double(it.size) / 1_048_576)
            print("[\(it.kind)] \(it.fileName)  \(mb)  \(flag)\(st)")
        }

        // Summary.
        var byKind: [String: Int] = [:]
        var okBytes: Int64 = 0
        var okCount = 0
        var expiredCount = 0
        for (it, st) in zip(items, statuses) {
            byKind[it.kind, default: 0] += 1
            if it.expired { expiredCount += 1 }
            if st.hasPrefix("ok") { okCount += 1; okBytes += it.size }
        }
        let kindStr = byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        print("---")
        print("첨부 \(items.count)개 (\(kindStr))")
        if !list {
            print("다운로드 \(okCount)개 · \(String(format: "%.1f", Double(okBytes) / 1_048_576))MB → \(out)/  (manifest.json)")
        }
        if expiredCount > 0 && !force {
            print("⏳ 만료 \(expiredCount)개 스킵 — 카톡에서 해당 방을 열어 동기화(또는 `kakaocli harvest --scroll`, Accessibility 필요) 후 재시도하면 받을 수 있어요.")
        }
    }
}
