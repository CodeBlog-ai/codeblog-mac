//
//  ChatStorageManager.swift
//  CodeBlog
//
//  Persists chat conversations and messages using GRDB.
//

import Foundation
import GRDB

final class ChatStorageManager: @unchecked Sendable {
    static let shared = ChatStorageManager()

    private var db: DatabasePool!

    private init() {
        let fileMgr = FileManager.default
        let appSupport = fileMgr.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseDir = appSupport.appendingPathComponent("CodeBlog", isDirectory: true)
        try? fileMgr.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let dbURL = baseDir.appendingPathComponent("chat.sqlite")

        var config = Configuration()
        config.prepareDatabase { db in
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
        }

        do {
            db = try DatabasePool(path: dbURL.path, configuration: config)
            migrate()
        } catch {
            print("[ChatStorage] Failed to open database: \(error)")
        }
    }

    // MARK: - Migration

    private func migrate() {
        do {
            try db.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS conversations (
                        id TEXT PRIMARY KEY,
                        title TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                """)

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS chat_messages (
                        id TEXT PRIMARY KEY,
                        conversation_id TEXT NOT NULL,
                        role TEXT NOT NULL,
                        content TEXT NOT NULL,
                        timestamp REAL NOT NULL,
                        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
                    )
                """)

                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation
                    ON chat_messages(conversation_id, timestamp)
                """)
            }
        } catch {
            print("[ChatStorage] Migration failed: \(error)")
        }
    }

    // MARK: - Conversations

    func createConversation(id: UUID, title: String) {
        let now = Date()
        do {
            try db.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
                    arguments: [id.uuidString, title, now.timeIntervalSince1970, now.timeIntervalSince1970]
                )
            }
        } catch {
            print("[ChatStorage] Failed to create conversation: \(error)")
        }
    }

    func updateConversationTimestamp(id: UUID) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                    arguments: [Date().timeIntervalSince1970, id.uuidString]
                )
            }
        } catch {
            print("[ChatStorage] Failed to update timestamp: \(error)")
        }
    }

    func updateTitle(id: UUID, title: String) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?",
                    arguments: [title, Date().timeIntervalSince1970, id.uuidString]
                )
            }
        } catch {
            print("[ChatStorage] Failed to update title: \(error)")
        }
    }

    func fetchConversations() -> [ChatConversation] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, title, created_at, updated_at
                    FROM conversations
                    ORDER BY updated_at DESC
                """)
                return rows.compactMap { row -> ChatConversation? in
                    guard let idStr = row["id"] as? String,
                          let id = UUID(uuidString: idStr),
                          let title = row["title"] as? String,
                          let createdTs = row["created_at"] as? Double,
                          let updatedTs = row["updated_at"] as? Double else { return nil }
                    return ChatConversation(
                        id: id,
                        title: title,
                        createdAt: Date(timeIntervalSince1970: createdTs),
                        updatedAt: Date(timeIntervalSince1970: updatedTs)
                    )
                }
            }
        } catch {
            print("[ChatStorage] Failed to fetch conversations: \(error)")
            return []
        }
    }

    func deleteConversation(id: UUID) {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM chat_messages WHERE conversation_id = ?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            print("[ChatStorage] Failed to delete conversation: \(error)")
        }
    }

    // MARK: - Messages

    func saveMessage(conversationId: UUID, message: ChatMessage) {
        let roleStr: String
        switch message.role {
        case .user: roleStr = "user"
        case .assistant: roleStr = "assistant"
        case .toolCall: return // Don't persist tool call messages
        }

        do {
            try db.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO chat_messages (id, conversation_id, role, content, timestamp) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        message.id.uuidString,
                        conversationId.uuidString,
                        roleStr,
                        message.content,
                        message.timestamp.timeIntervalSince1970
                    ]
                )
            }
        } catch {
            print("[ChatStorage] Failed to save message: \(error)")
        }
    }

    func fetchMessages(conversationId: UUID) -> [ChatMessage] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, role, content, timestamp
                    FROM chat_messages
                    WHERE conversation_id = ?
                    ORDER BY timestamp ASC
                """, arguments: [conversationId.uuidString])

                return rows.compactMap { row -> ChatMessage? in
                    guard let idStr = row["id"] as? String,
                          let id = UUID(uuidString: idStr),
                          let roleStr = row["role"] as? String,
                          let content = row["content"] as? String,
                          let ts = row["timestamp"] as? Double else { return nil }

                    let role: ChatMessage.Role
                    switch roleStr {
                    case "user": role = .user
                    case "assistant": role = .assistant
                    default: return nil
                    }

                    return ChatMessage(
                        id: id,
                        role: role,
                        content: content,
                        timestamp: Date(timeIntervalSince1970: ts)
                    )
                }
            }
        } catch {
            print("[ChatStorage] Failed to fetch messages: \(error)")
            return []
        }
    }

    func deleteMessagesFrom(conversationId: UUID, messageId: UUID) {
        // Get the timestamp of the target message, then delete it and everything after
        do {
            try db.write { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT timestamp FROM chat_messages WHERE id = ?
                """, arguments: [messageId.uuidString])

                if let ts = row?["timestamp"] as? Double {
                    try db.execute(sql: """
                        DELETE FROM chat_messages
                        WHERE conversation_id = ? AND timestamp >= ?
                    """, arguments: [conversationId.uuidString, ts])
                }
            }
        } catch {
            print("[ChatStorage] Failed to delete messages: \(error)")
        }
    }
}
