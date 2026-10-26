# Lyrenne for iPad

A personal, sideloaded iPad port of [Lyrenne](https://github.com/Doctordefector/Lyrenne), the
YouTube Music desktop player. SwiftUI + AVPlayer, built with [xtool](https://github.com/xtool-org/xtool).

Ported from Lyrenne `81ac0ac` (2026-10-25).

## What it does

- Search YouTube Music songs, tap one to play it and everything below it
- Autoplay: the queue tops itself up with YouTube Music's radio for the playing song
- Queue tab: jump to, swipe to remove; long-press a search result to add it to the queue
- Synced lyrics from lrclib (tap a line to seek), plain lyrics when that's all there is
- Keeps playing in the background and with the screen locked; lock screen / Control Center controls with artwork
- iPad only, split view: search and queue on the left, now playing and lyrics on the right

Not ported (desktop features that need more than this): sign-in and library, downloads/offline,
playlists, Discord, Last.fm, Listen Together, equalizer, crossfade. Add one when you miss it.

## Layout

| Path | What |
|------|------|
| `Sources/LyrenneCore/` | Foundation only, no UI. InnerTube (search, radio, stream URL with desktop's per-client check and fallback) and lrclib lyrics. Builds on Linux too |
| `Sources/Lyrenne/` | The iPad app: `Player.swift` (queue, AVPlayer, lock screen), `LyrenneApp.swift` (views) |
| `Sources/lyrenne-check/` | Live end-to-end check of LyrenneCore: search, stream, radio, lyrics |
| `Info.plist` | Merged by xtool: iPad-only family, background audio |
| `.github/workflows/ipa.yml` | Builds the unsigned `.ipa` on a GitHub macOS runner |

## Streams

Desktop tries web clients too, but their URLs need YouTube's JS signature deobfuscation (NewPipe),
which has no iOS port. The iPad build uses only clients that hand out direct URLs (Android VR,
iOS), takes the best AAC (m4a) format since AVPlayer can't decode Opus, and checks each URL with a
one-byte request before using it, same as desktop's fix for issue #17. If playback breaks one day,
compare `streamClients` in `InnerTube.swift` with desktop's `YouTubeClient.kt` and copy the newer versions.

## Getting the .ipa (no Mac needed)

Push this folder to a GitHub repo. The **Build IPA** workflow runs on every push (or by hand from
the Actions tab) and uploads `Lyrenne-iPad` as an artifact; unzip it to get `Lyrenne.ipa`.

## Installing on the iPad

The .ipa is unsigned; sideloading tools sign it with a free Apple ID (create one at
<https://account.apple.com>, no Apple hardware needed).

1. On Windows, install [iTunes](https://www.apple.com/itunes/) (the non-Store version) and [Sideloadly](https://sideloadly.io).
2. Plug in the iPad, trust the computer, drag `Lyrenne.ipa` into Sideloadly, enter the Apple ID, Start.
3. On the iPad: Settings → General → VPN & Device Management → trust your Apple ID.
   On iPadOS 16+, also turn on Settings → Privacy & Security → Developer Mode.

With a free Apple ID the app expires after 7 days; re-run Sideloadly (it can auto-refresh over Wi-Fi).

## Developing on Windows

The Linux side of xtool lives in a WSL distro whose disk is `../toolchain-wsl/ext4.vhdx`.
See [../README.md](../README.md).

```bash
wsl -d Ubuntu-24.04
cd "/mnt/s/Dev/XTool/iOS/Lyrenne-iPad"
swift run lyrenne-check   # live check of the core, on Linux, no SDK needed
```

Building the app itself locally (`xtool dev`) needs the iOS SDK, which on Linux comes from
`xtool setup` with an Xcode.xip downloaded under your Apple ID. CI makes that optional.
