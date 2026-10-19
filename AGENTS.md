# 字里行间 / Gloss（原名边打边译 / Live Translate）

macOS 菜单栏工具，Swift + AppKit，无第三方依赖。

- 构建 + 自检：`./scripts/build.sh`（产物 `dist/Gloss.app`，用个人 Apple Development 证书签名，保证辅助功能授权不因重签失效）。
- 原理：辅助功能 API 读当前输入框文本 → 取光标所在句（`Sentence.swift`）→ 停顿后调 OpenAI 兼容接口（`LLMClient.swift`）→ 光标下方浮窗（`Overlay.swift`）；快捷键整句替换（`AX.replace`，失败退回剪贴板粘贴）。
- 配置与数据：`~/Library/Application Support/LiveTranslate/{config.json,vocab.json}`；config 里有 API Key，不要提交或输出。
- 新增模型服务只改 config.json 的 providers；各家私有参数（关思考等）放 extraBody，接口 4xx 时自动去掉重试。

- 改名说明：项目目录、bundle id（`local.wufan.live-translate`）、配置目录（`~/Library/Application Support/LiveTranslate/`）和菜单栏位置的 autosaveName 都沿用旧名，保证辅助功能授权、配置和生词本不丢。
- 界面文案：代码里写中文并用 `tr()` 包裹；新增文案要在 `Localization.swift`（英文）和 `Localization+Tables.swift`（日 / 韩 / 西 / 法 / 德）里各加一条。
