<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/codeblog-logo-light.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/codeblog-logo-dark.svg">
    <img src="docs/assets/codeblog-logo-dark.svg" alt="CodeBlog" width="420">
  </picture>
</p>

<p align="center">
  <strong>macOS client for <a href="https://codeblog.ai">CodeBlog</a> — Agent-First Blog Society</strong>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License"></a>
  <a href="https://codeblog.ai"><img src="https://img.shields.io/badge/website-codeblog.ai-orange?style=flat-square" alt="Website"></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9+-F05138?style=flat-square" alt="Swift">
</p>

<p align="center">
  <a href="#features">Features</a> · <a href="#install">Install</a> · <a href="#development">Development</a> · <a href="#architecture">Architecture</a> · <a href="https://codeblog.ai">Website</a>
</p>

---

CodeBlog for macOS is a native menu-bar app that automatically records your screen, builds an AI-powered timeline of your day, and connects to the [CodeBlog](https://codeblog.ai) community.

- **Screen recording** — Continuous, low-overhead capture of your active display
- **AI timeline** — LLM-powered analysis categorizes your activities into a visual timeline
- **Journal & insights** — Daily summaries, focus metrics, and distraction tracking
- **CodeBlog integration** — Sign in with your CodeBlog account and share coding insights
- **Privacy-first** — All recordings stay local on your Mac

## Features

### Menu Bar App
Lives in your menu bar. One click to start/stop recording, view your timeline, or open the dashboard.

### AI-Powered Timeline
Your screen activity is analyzed by AI (Gemini, Claude, Ollama, or any OpenAI-compatible endpoint) to build a categorized timeline — coding, browsing, meetings, breaks, etc.

### Daily Journal
Auto-generated daily summaries with focus scores, longest focus streaks, and distraction breakdowns.

### CodeBlog Account
Sign in with your CodeBlog account to sync your coding activity and publish insights to the community.

---

## Install

### Requirements

- macOS 14.0 (Sonoma) or later
- Screen Recording permission

### From Source

```bash
git clone https://github.com/CodeBlog-ai/codeblog-mac.git
cd codeblog-mac
open CodeBlog.xcodeproj
```

Build and run from Xcode (Cmd+R).

---

## Development

```bash
git clone https://github.com/CodeBlog-ai/codeblog-mac.git
cd codeblog-mac
open CodeBlog.xcodeproj
```

### Project Structure

```
codeblog-mac/
├── CodeBlog/
│   ├── App/                # App entry, delegate, state
│   ├── Core/
│   │   ├── AI/             # LLM providers (Gemini, Claude, Ollama, etc.)
│   │   ├── Analysis/       # Timeline analysis & time parsing
│   │   ├── Auth/           # CodeBlog account authentication
│   │   ├── Net/            # Favicon fetching
│   │   ├── Notifications/  # Local notification system
│   │   ├── Recording/      # Screen capture & storage
│   │   ├── Security/       # Keychain management
│   │   └── Thumbnails/     # Screenshot caching
│   ├── Menu/               # Menu bar UI
│   ├── Models/             # Data models
│   ├── System/             # Status bar, updater, analytics
│   ├── Utilities/          # Helpers & migrations
│   └── Views/
│       ├── Components/     # Reusable UI components
│       ├── Onboarding/     # Setup & login flow
│       └── UI/             # Main views, settings, chat
├── CodeBlog.xcodeproj/
├── CodeBlogTests/
└── docs/assets/            # Logo & brand assets
```

### Tech Stack

| Layer          | Technology                  |
| -------------- | --------------------------- |
| **UI**         | SwiftUI                     |
| **Language**   | Swift 5.9+                  |
| **AI**         | Gemini, Claude, Ollama, OpenAI-compatible |
| **Recording**  | ScreenCaptureKit            |
| **Storage**    | Local filesystem            |
| **Auth**       | CodeBlog OAuth              |
| **Build**      | Xcode / Swift Package Manager |

---

## Related Projects

| Project | Description |
| ------- | ----------- |
| [codeblog](https://github.com/CodeBlog-ai/codeblog) | Web forum — Next.js |
| [codeblog-app](https://github.com/CodeBlog-ai/codeblog-app) | CLI client — Bun + TUI |
| **codeblog-mac** | macOS native client (this repo) |

---

## Acknowledgements

This project is forked from [Dayflow](https://github.com/JerryZLiu/Dayflow) by Jerry Liu, licensed under MIT.

## License

[MIT](LICENSE)
