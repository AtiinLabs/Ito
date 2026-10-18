<div align="center">
  <img src="Ito/Assets.xcassets/AppIcon.appiconset/app.png" alt="Ito app icon" width="144" />

  <h1>Ito</h1>

  <p><strong>Anime, manga, and novels in one native iOS app.</strong></p>
  <p>Discover, read, watch, and track without ads.</p>

  <p>
    <img src="https://img.shields.io/badge/iOS-15.4%2B-black?style=flat-square&logo=apple&logoColor=white" alt="iOS 15.4 or later" />
    <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2" />
    <a href="LICENSE">
      <img src="https://img.shields.io/badge/License-MPL--2.0-blue?style=flat-square" alt="MPL 2.0 license" />
    </a>
    <a href="https://discord.gg/Es5qTB9BcN">
      <img src="https://img.shields.io/discord/1475329802532552869?color=5865F2&label=Discord&logo=discord&logoColor=white&style=flat-square" alt="Discord" />
    </a>
  </p>
</div>

---

Ito is a free, open-source client for iPhone and iPad. It combines dedicated readers, native video playback, AniList integration, and an extensible WebAssembly plugin system in a single app.

## Features

* **Anime, manga, and novels** — Keep different media types together in one library.
* **Native reading** — Dedicated manga and novel readers designed for iOS.
* **Native video playback** — Select available video quality, audio tracks, and subtitles.
* **AniList discovery** — Browse, search, and filter titles using AniList.
* **Progress tracking** — Connect AniList to track what you read and watch.
* **WASM plugins** — Install `.ito` plugins from user-added repositories. Downloaded packages are SHA-256 verified before installation.
* **Backup and migration** — Export native `.itobackup` files or import libraries from Aidoku and Paperback.
* **On-device storage** — Library data and history are stored locally, with tracker credentials protected by Keychain.
* **No advertisements** — Ito is free and ad-free.

## Install

Unsigned builds are published for sideloading. [atiinlabs.github.io/Ito](https://atiinlabs.github.io/Ito/) has one-tap install links for Stable, and [its builds page](https://atiinlabs.github.io/Ito/install/) for both channels.

* **AltStore, SideStore, Feather:** add the source `https://atiinlabs.github.io/Ito/apps.json` (Stable) or `https://atiinlabs.github.io/Ito/apps-dev.json` (Dev, built from every change to `main`).
* **TrollStore:** install the `.tipa` from the [latest release](https://github.com/AtiinLabs/Ito/releases/latest).

## Showcase

<p align="center">
  <img src="assets/screenshots/details.png" alt="Media details" width="23%" />
  &nbsp;
  <img src="assets/screenshots/reader.png" alt="Manga reader" width="23%" />
  &nbsp;
  <img src="assets/screenshots/discover.png" alt="Discover view" width="23%" />
  &nbsp;
  <img src="assets/screenshots/library.png" alt="Library view" width="23%" />
</p>

## Supported imports

| Source         | Formats         |
| -------------- | --------------- |
| Ito            | `.itobackup`    |
| Aidoku         | `.aib`, `.json` |
| Paperback v0.8 | `.pas4`, `.zip` |

Backups can replace the existing library or be merged with it. Imported sources are matched against installed Ito plugins when possible.

## Build from source

### Requirements

* Xcode 26.2 or later
* Swift 6.2
* iOS or iPadOS 15.4 deployment target
* Swift Package Manager

Ito uses `ito-runner` as a local Swift package. Both repositories must be placed in the same parent directory:

```text
ito-dev/
├── Ito/
└── ito-runner/
```

Clone and open the project:

```sh
mkdir ito-dev
cd ito-dev

git clone https://github.com/itoapp/ito-runner.git
git clone https://github.com/itoapp/Ito.git

open Ito/Ito.xcodeproj
```

Allow Swift Package Manager to resolve the remaining dependencies, select a signing team and target device, then build with `⌘R`.

## Contributing

Pull requests are welcome. Keep changes focused, follow the existing SwiftLint configuration, and include tests for behavioral changes where practical.

## License

Ito is licensed under the [Mozilla Public License 2.0](LICENSE).

## Content and legal notice

> [!WARNING]
> Ito is a client and does not include or host media sources. Users are responsible for the repositories and plugins they install and for complying with applicable laws, licenses, and service terms. The maintainers do not endorse copyright infringement or other unlawful use.
