//
//  ChatConversation.swift
//  CodeBlog
//
//  Represents a persisted chat conversation with metadata.
//

import Foundation

struct ChatConversation: Identifiable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
}
