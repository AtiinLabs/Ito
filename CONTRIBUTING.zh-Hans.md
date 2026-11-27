[English](CONTRIBUTING.md) | [简体中文](CONTRIBUTING.zh-Hans.md)

# 为 Ito 做贡献

Ito 采用主干开发流程（trunk flow）：所有改动都通过经过审查的 Pull Request（PR）合并到受保护的 `main` 分支；每次推送到 `main` 都会发布一个开发版（Dev）构建；在 `main` 上打上带注解的标签（annotated tag）`vX.Y.Z`，即可发布一个稳定版（Stable）构建。

## 本地环境配置

克隆 Ito 并打开项目。Xcode 会按照 `Package.resolved` 中锁定的版本，从 GitHub 拉取 `ito-runner`、`WasmKit` 和 `anilist-sdk`：

```bash
git clone https://github.com/AtiinLabs/Ito.git
open Ito/Ito.xcodeproj
```

如果要在开发 Ito 的同时修改 `ito-runner` 或 `anilist-sdk`，可以把它克隆到任意位置，然后将其文件夹拖进 Xcode 的项目导航器（Project Navigator）。在你移除之前，本地包会覆盖同名的远程包。要发布这项改动，请先在对应仓库中合并，然后在 **Package Dependencies** 中更新版本（或修改项目中的包依赖要求），并提交新的 `Package.resolved`。

在模拟器上开发或进行 CI 未签名构建时，不需要付费的 Apple Developer Program 会员资格。

### 代码检查（Lint）

SwiftLint 会在 Xcode 构建过程、pre-commit 钩子以及每个 PR 的 `SwiftLint / lint` 检查中运行。CI 会把警告视为错误。每个克隆只需安装一次钩子：

```bash
brew install lefthook swiftlint
lefthook install
```

该钩子只检查已暂存的 Swift 文件。要检查全部文件，请运行 `swiftlint lint --strict`；`swiftlint --fix` 可以自动修复部分问题。

编译器诊断与 SwiftLint 是两回事。请同时检查 `Ito` scheme 的构建结果和 Analyze 结果，并从根源上修复警告，而不是将其屏蔽。

## 分支

从最新的 `main` 创建短期分支：

- `feat/<brief-name>`：面向用户的功能
- `fix/<brief-name>`：一般的 bug 修复
- `refactor/<brief-name>`：内部重构
- `chore/<brief-name>`：日常维护
- `docs/<brief-name>`：文档

项目没有 release 分支或 hotfix 分支，也没有长期存在的 `develop` 分支。`main` 在 `Configuration/Version.xcconfig` 中声明下一个稳定版本号；稳定版发布就是在 `main` 上打一个带注解的标签 `vX.Y.Z`。

## Pull Request

1. 每个 PR 应聚焦于单一目的，便于审查。
2. 涉及明显界面变化时，请附上截图或录屏。
3. 合并前须确保 GitHub Actions 全部通过。
4. 使用 Squash 合并（squash merge）。

PR 标题请采用 Conventional Commits 风格，例如：

- `feat: add account switching`
- `fix: prevent duplicate timeline requests`
- `chore: bump version to 1.3.1`

## 无签名测试

CI 在禁用代码签名的情况下构建和测试。在本地，选择一个 iOS 模拟器并运行 `Ito` scheme 即可。请勿提交签名身份、`.p12` 文件、描述文件（provisioning profile）、Apple 账号信息或个人开发团队标识符。

如需在真机上运行，请在 Xcode 中设置你的团队，但不要提交这项改动。pre-commit 钩子和 `CI / No development team` 检查会拒绝 `project.pbxproj` 或任何 `.xcconfig` 文件中出现的 `DEVELOPMENT_TEAM` 值。如果你因为其他改动需要暂存项目文件，请只暂存你打算提交的代码块（`git add -p`）。

## 字符串与翻译

应用中显示的每个字符串都在 Weblate 上翻译。请按照 [`docs/zh-Hans/LOCALIZATION.md`](docs/zh-Hans/LOCALIZATION.md) 中的说明编写新字符串，并在提交 PR 之前同步字符串目录（String Catalog）。翻译本身请在 Weblate 上贡献，不要直接编辑 `Localization/`。

## 构建渠道

- **稳定版（Stable）：** 由 `v1.3.0` 这样的标签触发，只能打在已经包含在 `main` 中的提交上。
- **开发版（Dev）：** `main` 每次推送都会自动构建，供抢先体验用户测试。

两个渠道使用相同的 Bundle ID，因此安装其中一个会替换另一个。如果要让两个渠道并存安装，需要分别配置 Xcode configuration 和 Bundle ID，并审查相关授权（entitlements）。

另请参阅 [`docs/zh-Hans/BRANCHING_AND_CHANNELS.md`](docs/zh-Hans/BRANCHING_AND_CHANNELS.md) 和 [`docs/zh-Hans/RELEASING.md`](docs/zh-Hans/RELEASING.md)。

> 本文为英文 [CONTRIBUTING.md](CONTRIBUTING.md) 的中文译本，如有出入，以英文原文为准。
