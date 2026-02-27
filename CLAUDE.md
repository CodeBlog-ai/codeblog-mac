# CLAUDE.md — CodeBlog macOS

## Project Overview

CodeBlog macOS 客户端 — 原生 SwiftUI 桌面应用，提供 AI 聊天（MCP 工具调用）、屏幕录制时间线、开发者日志等功能。

**Tech stack**: Swift 5.9+, SwiftUI, ScreenCaptureKit, GRDB, Sparkle 2, PostHog, Sentry

**Requires**: Xcode 15+, macOS 14.0 (Sonoma) SDK

## Project Structure

```
CodeBlog/
├── App/                  # 入口 (CodeBlogApp, AppDelegate, AppState)
├── Core/
│   ├── AI/               # LLM 服务、ChatService、ChatStorageManager
│   ├── Analysis/          # 时间线分析引擎
│   ├── Auth/              # CodeBlog OAuth 认证
│   ├── MCP/               # MCP 配置与通信
│   ├── Net/               # API 服务
│   ├── Recording/         # ScreenCaptureKit 录屏
│   └── Security/          # Keychain
├── Models/                # 数据模型 (ChatMessage, ChatConversation, etc.)
├── Views/
│   ├── Components/        # 可复用组件 (ToolCallBubble, etc.)
│   ├── Onboarding/        # 新手引导流程
│   └── UI/                # 主界面 (ChatView, TimelineView, etc.)
├── System/                # Analytics, Updates, Notifications
├── Utilities/             # Helpers, Formatters, Migrations
├── Fonts/                 # Nunito, Instrument Serif, Figtree
└── Assets.xcassets/       # 图片、图标、颜色
```

**Key files**:
- `CodeBlog/Views/UI/ChatView.swift` — AI 聊天主界面（最大文件，~2800 行）
- `CodeBlog/Core/AI/ChatService.swift` — 聊天服务、对话管理、消息持久化
- `CodeBlog/Core/AI/ChatStorageManager.swift` — GRDB 聊天历史存储
- `CodeBlog/Core/AI/LLMService.swift` — LLM 提供商抽象层
- `CodeBlog/App/AppDelegate.swift` — 生命周期、Sentry/PostHog 初始化
- `CodeBlog/Info.plist` — 版本号、Sparkle 配置、URL Scheme

## Code Conventions

### Concurrency
- 使用 `@MainActor` 标注所有 UI 相关的类和方法
- async/await 为主要异步模式，Combine 用于状态绑定（`@Published`）

### Architecture
- 服务层使用单例：`static let shared = ClassName()`
- GRDB 持久化：`DatabasePool`, WAL mode, `~/Library/Application Support/CodeBlog/` 目录
- 分析数据存储在 `~/Library/Application Support/CodeBlog/` 本地文件系统

### Design System (Dayflow)
- **字体**: Nunito（主要）, Instrument Serif（装饰）, Figtree（辅助）
- **颜色**: 暖橙色系 — `#F96E00`（主色）, `#FFF4E9`（浅橙背景）, `#BBBBBB`（辅助灰）
- **图标**: 优先使用 Asset Catalog 中的自定义 SVG（如 IconCopy, IconEdit），其次 SF Symbols

### Bundle & Signing
- Bundle ID: `ai.codeblog.mac`
- Team ID: `W3XG97B483`
- Sandbox: 关闭（需要完整系统访问）
- URL Scheme: `codeblog://`

## Release

```bash
# 查看当前版本
./scripts/release.sh

# Dry run（只显示步骤，不执行）
./scripts/release.sh 2.0.2 --dry-run

# 正式发版（构建 DMG + GitHub Release + appcast 更新）
./scripts/release.sh 2.0.2
```

脚本自动完成：版本号更新 → 构建签名 DMG → Sparkle 签名 → git commit/tag/push → GitHub Release（附带 DMG）→ appcast.xml 更新

Tag 格式统一使用 `v` 前缀：`v2.0.1`, `v2.0.2`

## Dependencies (SPM)

| Package | Purpose |
|---------|---------|
| GRDB | SQLite 数据库（聊天历史、分析数据） |
| Sparkle | macOS 自动更新框架 |
| PostHog | 产品分析（opt-in） |
| Sentry | 崩溃报告（opt-in） |

## Important Notes

- **不要修改** `CodeBlog.entitlements` 除非明确要求
- **不要添加** 新的 SPM 依赖除非明确要求
- **不要删除** `CodeBlog/Fonts/` 中的字体文件
- **不要提交** `scripts/release.env`（含签名密钥和 token）
- **不要修改** Info.plist 中的 Sparkle 公钥（`SUPublicEDKey`）
- ChatView.swift 是最大的单文件，修改时注意上下文理解
- 所有录屏数据存储在本地，不上传到服务器
