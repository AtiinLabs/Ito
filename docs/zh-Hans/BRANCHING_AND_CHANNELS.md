[English](../BRANCHING_AND_CHANNELS.md) | [简体中文](BRANCHING_AND_CHANNELS.md)

# 分支与二进制发布渠道

## 开发与发布流程图

```text
feat/* ─────┐
fix/* ──────┤  reviewed PR, squash merge
            ▼
main ──●────●────●────────●────────────► next version
       │    │    │        │
       │    │    │        └─ v1.3.0 (stable tag)
       │    │    └─ dev build on every push
       │    └─ dev build on every push
       └─ dev build on every push
```

（图中：经审查的 Pull Request（PR） 以 Squash 合并方式进入 `main`；每次推送都会生成开发版构建；`v1.3.0` 为稳定版标签。）

## 各分支的职责

`main` 是唯一的长期分支（自动生成的 `gh-pages` 除外）。它在 `Configuration/Version.xcconfig` 中声明下一个稳定版本号，应始终保持可构建，所有改动都通过短期的 PR 分支以 Squash 合并的方式进入。项目没有 release 分支或 hotfix 分支；稳定版发布就是 `main` 上的一个标签。

稳定版会包含 `main` 上已有的全部内容。由于没有用于稳定版本的分支，发布后的紧急修复会合并到 `main`，并以 `main` 当前声明的版本号发布：如果自上次发布以来只合入了修复，就发布补丁版本；否则发布已经包含新功能的次版本。

## 标签规则

稳定版发布标签是如下格式的带注解的标签（annotated tag）：

```text
v1.3.0
```

被打标签的提交必须包含在 `main` 中，并且标签必须与该提交中 `Configuration/Version.xcconfig` 里的 `MARKETING_VERSION` 一致。请勿移动或复用 `v*` 标签。请为 `v*` 配置一条 GitHub 标签规则集（tag ruleset），禁止更新和删除这些标签。

开发版标签会自动创建，格式如下：

```text
dev-124
```

其中的数字是构建号。这些标签是有意设计为临时的：dev 工作流会保留最新的 14 个开发版发布，并删除更早的开发版发布及其标签。

## 二进制发布渠道

| 渠道 | 触发方式 | GitHub 发布类型 | 源文件 | 目标用户 |
|---|---|---|---|---|
| 开发版（Dev） | 每次推送到 `main`，或手动运行 | 预发布版（Prerelease） | `apps-dev.json` | 抢先体验用户（Early testers） |
| 稳定版（Stable） | `main` 上的 `vX.Y.Z` 标签 | 正式发布 | `apps.json` | 普通用户 |

应用的 `MARKETING_VERSION` 在 `Configuration/Version.xcconfig` 中设置，始终保持纯数字格式（`X.Y.Z`）；开发版构建的显示版本号（例如 `1.3.0-dev.124`）会出现在产物文件名、发布标题和源的发布说明中。源的 `version` 字段填写的是纯数字的应用版本号，因为当应用版本与源中的版本不一致时，AltStore 和 SideStore 会拒绝安装。两个渠道的构建号都是被构建提交的提交总数，因此同一个提交的开发版构建和稳定版标签共用同一个构建号。

## 当前的安装行为

两个渠道都使用 `moe.itoapp.ito`。因此，安装开发版或稳定版都会替换掉另一个。

如果以后要支持两者并存安装，需要引入使用不同值的 Xcode configuration 或 scheme，例如：

```text
Stable: moe.itoapp.ito
Dev:    moe.itoapp.ito.dev
```

在 CI 中覆盖 Bundle ID 之前，这项改动还必须审查 App Groups、钥匙串群组（keychain groups）、URL Scheme、扩展、关联域（associated domains）以及其他授权（entitlements）。

> 本文为英文 [BRANCHING_AND_CHANNELS.md](../BRANCHING_AND_CHANNELS.md) 的中文译本，如有出入，以英文原文为准。
