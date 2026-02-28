# 热重载开发（InjectionIII）

保存代码即可看到效果，无需重新 build 或重启 app。

## 安装

从 [InjectionIII Releases](https://github.com/johnno1962/InjectionIII/releases/latest) 下载，解压后移动到 `/Applications/`。

## 使用

1. 打开 `/Applications/InjectionIII.app`（保持后台运行）
2. 首次使用：点菜单栏注射器图标 → **Open Project** → 选择项目根目录
3. `Cmd+R` 运行 app
4. 改代码 → `Cmd+S` → app 界面立即更新

Xcode 控制台出现 `💉 Injected ...` 表示生效。

## 什么能热更新，什么不能

| 操作 | 结果 |
|------|------|
| 修改函数/方法体内的逻辑 | ✅ 立即生效 |
| 修改 SwiftUI View 的 body | ✅ 立即生效 |
| 添加/删除 stored property | ❌ 需要重新 build |
| 添加/删除方法 | ❌ 需要重新 build |
| 修改初始化器 | ❌ 需要重新 build |

## 已配置项（无需重复操作）

以下配置已在项目中完成，新 clone 项目的开发者只需安装 app 即可：

- `AppDelegate.swift`：Debug 模式下自动加载 `macOSInjection.bundle`
- Build Settings（Debug）：`-Xlinker -interposable`、`EMIT_FRONTEND_COMMAND_LINES = YES`
- Signing & Capabilities：Hardened Runtime + Disable Library Validation
