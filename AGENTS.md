# 字里行间 / Gloss（原名边打边译 / Live Translate）

macOS 菜单栏工具，Swift + AppKit，无第三方依赖。

- 构建 + 自检：`./scripts/build.sh`（产物 `dist/Gloss.app`）。签名证书读环境变量 `SIGNING_IDENTITY` 或 `scripts/signing-identity`（不进仓库），都没有就 ad-hoc；用固定证书签名，辅助功能授权才不会因重签失效。
- README 素材：`./scripts/make-readme-media.sh` 用 `--demo` 场景（`Sources/Demo.swift`）重新录 `docs/images/` 里的截图和 GIF，会占用主屏左上角几分钟。
- 原理：辅助功能 API 读当前输入框文本 → 取光标所在句（`Sentence.swift`）→ 停顿后调 OpenAI 兼容接口（`LLMClient.swift`）→ 光标下方浮窗（`Overlay.swift`）；快捷键整句替换（`AX.replace`，失败退回剪贴板粘贴）。
- 配置与数据：`~/Library/Application Support/LiveTranslate/{config.json,vocab.json}`；config 里有 API Key，不要提交或输出。
- 新增模型服务只改 config.json 的 providers；各家私有参数（关思考等）放 extraBody，接口 4xx 时自动去掉重试。

- 改名说明：项目目录、bundle id（`local.wufan.live-translate`）、配置目录（`~/Library/Application Support/LiveTranslate/`）和菜单栏位置的 autosaveName 都沿用旧名，保证辅助功能授权、配置和生词本不丢。
- 界面文案：代码里写中文并用 `tr()` 包裹；新增文案要在 `Localization.swift`（英文）和 `Localization+Tables.swift`（日 / 韩 / 西 / 法 / 德）里各加一条。
