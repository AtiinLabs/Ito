<div align="center">
  <img src="Ito/Assets.xcassets/AppIcon.appiconset/app.png" alt="Ito app icon" width="144" />

  <h1>Ito</h1>

  <p><strong>Anime, manga, and novels in one native iOS app.</strong></p>
  <p>Free, open source, and ad-free. For iPhone and iPad.</p>

  <p>
    <img src="https://img.shields.io/badge/iOS-15.4%2B-black?style=flat-square&logo=apple&logoColor=white" alt="iOS 15.4 or later" />
    <a href="LICENSE">
      <img src="https://img.shields.io/badge/License-MPL--2.0-blue?style=flat-square" alt="MPL 2.0 license" />
    </a>
  </p>
</div>

---

## Features

* Native manga and novel readers, plus video playback.
* One library with local history and backups.
* AniList discovery and progress tracking with AniList, MyAnimeList or MangaBaka.
* Extensible `.ito` source plugins with search and source settings.

## Install

Unsigned builds are published for sideloading. [atiinlabs.github.io/Ito](https://atiinlabs.github.io/Ito/) has one-tap install links for Stable, and [its builds page](https://atiinlabs.github.io/Ito/install/) for both channels.

* **AltStore, SideStore, Feather:** add the source `https://atiinlabs.github.io/Ito/apps.json` (Stable) or `https://atiinlabs.github.io/Ito/apps-dev.json` (Dev, built from every change to `main`).
* **TrollStore:** install the `.tipa` from the [latest release](https://github.com/AtiinLabs/Ito/releases/latest).

## Showcase

<p align="center">
  <img src="assets/screenshots/library.png" alt="Library with custom lists" width="23%" />
  &nbsp;
  <img src="assets/screenshots/details.png" alt="Anime details with the episode list" width="23%" />
  &nbsp;
  <img src="assets/screenshots/reader.png" alt="Webtoon reader" width="23%" />
  &nbsp;
  <img src="assets/screenshots/novel.png" alt="Novel reader" width="23%" />
</p>

## Build from source

Requires Xcode 26.2 or later. Supports iOS and iPadOS 15.4+.

```sh
git clone https://github.com/AtiinLabs/Ito.git
open Ito/Ito.xcodeproj
```

Let Swift packages resolve, select your signing team and device, then run with `⌘R`.

## Contributing

Focused pull requests and bug reports are welcome. Follow SwiftLint and include behavioral tests. Join the [Discord](https://discord.gg/Es5qTB9BcN) for discussion.

## License

Ito is licensed under the [Mozilla Public License 2.0](LICENSE).

## Content and legal notice

> [!WARNING]
> Ito is a client and does not include or host media sources. Users are responsible for the repositories and plugins they install and for complying with applicable laws, licenses, and service terms. The maintainers do not endorse copyright infringement or other unlawful use.

Series data from [MangaBaka](https://mangabaka.org) is licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). Ito is not affiliated with AniList, MyAnimeList or MangaBaka.
