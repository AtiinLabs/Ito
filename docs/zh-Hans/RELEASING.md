[English](../RELEASING.md) | [简体中文](RELEASING.md)

# 未签名版本发布流程

Ito 目前分发未签名的真机 IPA。AltStore 和 SideStore 可以使用用户自己的 Apple 账号对其重新签名；通过 TrollStore 或越狱方式安装则取决于目标设备及其环境。App Store / TestFlight 签名发布仍是未来单独的工作流程。

> **关于本译本：** 英文原文中还有多节针对具体功能的发布前检查说明（运行器兼容性、备份兼容性、数据库 schema 变更、下载与阅读器相关检查等）。这些内容几乎每个版本都会更新，且只面向维护者，为避免译文过期，本译本仅保留其标题和简介，并链接到英文原文。发布前请务必以[英文原文](../RELEASING.md)为准。

## 运行器兼容性

运行器（runner）超时、章节版本枚举与插件错误处理方面的兼容性说明。详见英文原文：[Runner compatibility](../RELEASING.md#runner-compatibility)。

## 备份兼容性

备份中的书库缩略图、下载预设、自动下载规则，以及数据库 schema v27/v28 带来的向前/向后兼容性变化，发布说明中需要注明的事项。详见英文原文：[Backup compatibility](../RELEASING.md#backup-compatibility)。

## 一次性仓库配置

1. 将这套初始配置复制到 Ito 仓库中。
2. 在 **Settings → Pages** 中，选择从 `gh-pages` 分支的 `/ (root)` 发布。
3. 保护 `main` 分支，要求通过 Pull Request（PR）合并，并将 `Build and unit test` 设为必需检查。
4. 为 `v*` 添加标签规则集，禁止更新和删除标签。
5. 在 Xcode 项目中将 `ito-runner` 和 `anilist-sdk` 锁定到经过审查的提交；`Package.resolved` 会为每次构建锁定它们以及 WasmKit 的版本。
6. 确保仓库的 Actions 令牌对发布工作流拥有 `contents: write` 权限。

## 开发版渠道

CI 会对每次推送到 `main` 的提交验证一次，只有在构建/单元测试、本地化检查和签名配置检查全部通过后，才会调用开发版打包工作流。发布流程会检出那个已验证的提交，不会重复运行单元测试。PR 只运行验证。

如需手动构建开发版，请使用 **Actions → CI → Run workflow → main**，同样会经过上述验证。新的 `main` 推送会取消正在进行的 CI/开发版运行。带标签的稳定版发布仍会对被打标签的候选版本单独进行验证。

它会发布：

```text
Ito-X.Y.Z-dev.BUILD-unsigned.ipa
Ito-X.Y.Z-dev.BUILD-unsigned.ipa.sha256
Ito-X.Y.Z-dev.BUILD-unsigned.tipa
Ito-X.Y.Z-dev.BUILD-unsigned.tipa.sha256
```

例如 `Ito-1.3.0-dev.124-unsigned.ipa`。它会创建一个标签为 `dev-BUILD`、标题为 `X.Y.Z-dev.BUILD` 的 GitHub 预发布版，更新 `apps-dev.json`，并保留最新的 14 个开发版发布，删除更早的开发版发布及其标签。开发版构建可能不稳定。

## 应用版本号与构建号

`Configuration/Version.xcconfig` 是唯一设置版本号的地方：

- `MARKETING_VERSION` 是下一个稳定版的纯数字版本号 `X.Y.Z`。它会成为 `CFBundleShortVersionString`，显示在“设置”中，并用于和每个插件的 `min_app_version` 进行比较。
- 构建号（`CFBundleVersion`）是被构建提交的提交总数，即 `git rev-list --count HEAD`。开发版和正式发布工作流都会设置它，因此同一个提交在两个渠道中的构建号相同，并且构建号会沿着 `main` 递增。本地构建使用 1。

发布标签必须与该文件一致：`v1.3.0` 要求被打标签的提交中 `MARKETING_VERSION = 1.3.0`，否则发布工作流会中止。版本号后带后缀的标签会被拒绝。

`main` 声明的是其当前内容发布时应使用的版本号。打上 `v1.3.0` 标签后，请把 `main` 升到补丁版本 `1.3.1`，这样开发版构建就不会再沿用已发布的版本号。此后第一个加入新功能的 PR 还需同时升级次版本号（`1.4.0`）；不兼容的变更则升级主版本号。`main` 上的版本号只会递增。

## 精确版本的更新计数

书库 schema v23 中更新计数的计算规则。详见英文原文：[Exact-edition update counts](../RELEASING.md#exact-edition-update-counts)。

## 发布稳定版

1. 确认 `main` 的最新提交已通过 CI。
2. 确认该提交中的 `Configuration/Version.xcconfig` 声明了要发布的版本（例如 `1.3.0`）。
3. 为该提交打标签并推送标签：

```bash
git switch main
git pull --ff-only
git tag -a v1.3.0 -m "Ito 1.3.0"
git push origin v1.3.0
```

被打标签的提交必须包含在 `main` 中。工作流会对它进行测试，构建未签名的 IPA 和 `.tipa`，创建一个正式的 GitHub Release，并更新 `apps.json`。

4. 提交一个 PR，将 `main` 上的 `MARKETING_VERSION` 升到补丁版本（例如 `1.3.1`）。

## 发布后的紧急修复

由于没有用于稳定版本的分支，稳定版会包含 `main` 上已有的全部内容，紧急修复就是 `main` 的下一次发布：

1. 通过经过审查的 PR 把修复合并到 `main`。
2. 发布 `main` 当前声明的版本。如果自 `v1.3.0` 以来只合入了修复，版本号就是 `1.3.1`；如果合入了新功能，版本号就是 `1.4.0`，修复会随之一起发布。
3. 打标签并推送，例如：

```bash
git switch main
git pull --ff-only
git tag -a v1.3.1 -m "Ito 1.3.1"
git push origin v1.3.1
```

## 安装：AltStore、SideStore、Feather、TrollStore

每个渠道首次发布之后：

```text
Stable: https://atiinlabs.github.io/Ito/apps.json
Dev:    https://atiinlabs.github.io/Ito/apps-dev.json
```

AltStore、SideStore 和 Feather 会直接读取这些源。两个源描述的是同一个 Bundle ID，安装其中一个渠道会替换另一个。

每个源条目中的 `version` 是应用的纯数字版本号，`buildVersion` 是构建号，二者都与 IPA 的 Info.plist 一致；如果不一致，AltStore 和 SideStore 会拒绝安装。渠道的显示版本号（例如 `1.3.0-dev.124`）写在条目的发布说明中。每个条目还包含 IPA 的 `sha256`，两个商店在下载后都会进行校验。

每次发布还会附带一个与 IPA 字节完全相同的 `.tipa`，供 TrollStore 使用。TrollStore 在安装时会用 ldid 为未签名的应用伪签名；除 TrollStore 的默认授权外，Ito 不需要其他授权（entitlements）。

GitHub 的发布说明会过滤掉自定义 URL Scheme，因此一键安装链接放在 GitHub Pages 上：

- `https://atiinlabs.github.io/Ito/` 是项目网站，对应 `main` 上的 `site/index.html`。每当 `main` 上的 `site/` 有变更，或手动触发时，`.github/workflows/site.yml` 都会把它复制到 `gh-pages` 的根目录。它的安装选择器面向稳定版：AltStore、SideStore 和 Feather 添加 `apps.json`；TrollStore 安装最新 `apps.json` 条目所指向的 `.tipa`（在页面加载时获取）。
- `https://atiinlabs.github.io/Ito/install/` 会在每次发布源或网站时，根据现有的源重新生成（`.github/scripts/render_install_page.py`）。它为每个渠道提供 `altstore://source?url=`、`sidestore://source?url=`、`feather://source/<source URL>`、`apple-magnifier://install?url=<.tipa URL>`（TrollStore）链接以及直接下载链接。

源和网站的发布各自通过 `.github/scripts/gh_pages.sh` 推送到 `gh-pages`；如果另一个发布流程先完成了推送，脚本会重新执行更新。GitHub Pages 必须从 `gh-pages` 分支部署（**Settings → Pages → Deploy from a branch**），否则源文件虽然提交了，却永远不会被发布出去。

## 每次发布的执行步骤

1. 验证标签或开发版构建的元数据；
2. 检出 Ito；
3. 解析 Swift 包；
4. 在可用的 iPhone 模拟器上运行单元测试；
5. 在禁用签名的情况下归档通用 iOS 设备构建；
6. 移除残留的签名和描述文件；
7. 将 `Payload/Ito.app` 打包为 IPA，并复制一份 `.tipa`；
8. 生成 SHA-256 校验和；
9. 发布 GitHub 正式版或预发布版；
10. 更新 `gh-pages` 上对应渠道的源和构建版本页面（`install/`）。

## 未来的 App Store / TestFlight 发布路径

签名分发请放在单独的工作流中。等有了 Apple Developer Program 账号之后：

- 从同一个稳定版标签创建 App Store 归档；
- 从加密的 secrets 中安装分发证书和描述文件；
- 导出并上传已签名的构建；
- 从 `main` 设立 TestFlight 通道，用于预发布测试；
- 如有需要，继续保留未签名 IPA 的发布，用于其他分发途径。

请勿在未签名工作流中添加尚不可用的签名凭据。

## 回滚

对于稳定版，请将该发布标记为不可用，或发布一个更新的补丁版本；请勿移动或复用 `v*` 标签。必要时，从 `gh-pages` 上对应的源 JSON 中移除有问题的版本。

开发版发布是临时的，会被自动清理。

## 功能专项发布检查（仅英文）

以下各节是针对具体功能的发布前验证清单，请直接阅读英文原文：

- [Edition-policy checks](../RELEASING.md#edition-policy-checks)：下载分组选择策略与“Find All Uploads”相关检查
- [Manual offline replacement candidate](../RELEASING.md#manual-offline-replacement-candidate)：手动替换离线章节（另见 [Offline chapter replacement](../OFFLINE_DOWNLOADS.md)）
- [Network preference upgrade checks](../RELEASING.md#network-preference-upgrade-checks)：网络偏好设置升级检查
- [Downloaded-alternative checks](../RELEASING.md#downloaded-alternative-checks)：已下载替代版本检查
- [Image/text reader handoff checks](../RELEASING.md#imagetext-reader-handoff-checks)：图片阅读器与文字阅读器之间的切换检查
- [Automatic download screens and notifications](../RELEASING.md#automatic-download-screens-and-notifications)：自动下载界面与通知检查

> 本文为英文 [RELEASING.md](../RELEASING.md) 的部分中文译本，如有出入，以英文原文为准。
