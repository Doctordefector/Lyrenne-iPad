# Lyrenne for iPad

A personal, sideloaded iPad port of [Lyrenne](https://github.com/Doctordefector/Lyrenne), the
YouTube Music desktop player. SwiftUI + AVPlayer, built with [xtool](https://github.com/xtool-org/xtool).

Ported from Lyrenne `81ac0ac` (2026-10-25).

## What it does

- Search YouTube Music songs, tap one to play it and everything below it
- Library tab: sign in with Google, then your Liked songs and playlists (Play, Shuffle, Download all)
- Downloads tab: songs kept for offline listening; downloaded songs always play from disk. They
  are also in the Files app under **On My iPad > Lyrenne** as `Artist - Title [id].m4a` (the id is
  how the app finds them; deleting one there removes the download)
- Autoplay: the queue tops itself up with YouTube Music's radio for the playing song
- Queue tab: jump to, swipe to remove. Long-press any song: Play next, Add to queue, Download
- Synced lyrics from lrclib (tap a line to seek), plain lyrics when that's all there is
- Keeps playing in the background and with the screen locked; lock screen / Control Center controls with artwork
- Listen Together (guest): join a room started in desktop or Android Lyrenne with its code; the
  host's songs, play/pause and seeks follow here. Hosting from the iPad is not built
- iPad only, split view: browsing on the left, now playing and lyrics on the right, over the
  blurred cover. Gold accent and app icon from desktop

Left out on purpose: Discord, Last.fm, hosting a Listen Together room, equalizer, crossfade.

## Layout

| Path | What |
|------|------|
| `Sources/LyrenneCore/` | Foundation only, no UI, builds on Linux too. `InnerTube.swift` (search, radio, stream URLs), `Account.swift` (signed-in calls, session refresh), `Downloads.swift` (fetching audio, offline files), `Lyrics.swift` (lrclib), `ListenTogether.swift` (guest client, hand-rolled protobuf for desktop's `listentogether.proto`) |
| `Sources/Lyrenne/` | The iPad app: `Player.swift` (queue, AVPlayer, lock screen), `Library.swift` (sign-in, Keychain, library, playlists), `DownloadsView.swift`, `TogetherView.swift` (Listen Together room), `LyrenneApp.swift` (layout, search, now playing, lyrics) |
| `Sources/lyrenne-check/` | Live end-to-end check of the core: search, radio, lyrics, per-client stream report, download, 500-song playlist paging; with `LYRENNE_COOKIE` set, the library too |
| `Info.plist` | Merged by xtool: iPad-only family, background audio |
| `Resources/AppIcon.png` | App icon, desktop's lyre (`icon-small.svg`) full-bleed at 1024 px |
| `.github/workflows/ipa.yml` | Builds the unsigned `.ipa`, and runs the app on an iPad simulator with screenshots |

## Sign-in

Google's sign-in page in a web view, the same flow as upstream Android. The resulting cookie is
kept in the Keychain. Google rotates session cookies and a stored copy dies within weeks unless the
rotated ones are folded back, so every launch loads music.youtube.com with it, reads `LOGGED_IN`, and
merges the new cookies (desktop's `AuthManager.refreshSession`). An expired session says so and asks
you to sign in again; being offline keeps the login.

## Streams (October 2026)

- Most clients now hand out URLs that serve only the first MiB without a PO token (which needs
  BotGuard, not available here). Desktop's **VISIONOS** client still gets whole-file URLs, so it is
  tried first, with `visitorData` sent like desktop. The check before using a URL probes the file's
  **last** byte; desktop's first-byte check passes the truncated URLs.
- googlevideo also refuses (403) a plain GET, open-ended Ranges and any Range over 1 MiB. AVPlayer
  streams with open-ended Ranges, so the app fetches each song in 1 MiB ranges, in parallel (~0.3 s
  for a 6 MB song), and plays the file. Downloads use the same fetch.
- Web clients need YouTube's JS signature deobfuscation (NewPipe), which has no iOS port.

When playback breaks: run `swift run lyrenne-check` and read its `client ...` lines, then compare
`streamClients` in `InnerTube.swift` with desktop's `YouTubeClient.kt` / `ContentAwareFallbackStrategy.kt`.
The app's error under the player also lists each client's reason.

## Listen Together

Same server (`wss://metroserverx.meowery.eu/ws`) and messages as desktop's `listentogether/`.
The iPad only joins: it sends `join_room`, follows `sync_playback` / `sync_state`, and sends
`buffer_ready` once the host's song has loaded so the host can start everyone together.
`lyrenne-check` decodes a sample message and, on macOS, joins a made-up room and expects the
server's "Room not found" (Linux Foundation has no WebSockets, so that part is skipped there).

## CI and the simulator

YouTube answers every client from GitHub's runners with "Sign in to confirm you're not a bot"
(datacenter IPs), so on CI streams fail by design, while the same code plays from a home connection.
The simulator job therefore proves playback offline: it places a spoken test tone in the app's
Downloads and plays it. Screenshots are uploaded as the `simulator-screenshots` artifact.

## Getting the .ipa (no Mac needed)

The repo is <https://github.com/Doctordefector/Lyrenne-iPad>. The **Build IPA** workflow runs on every push (or by hand from
the Actions tab) and uploads `Lyrenne-iPad` as an artifact; unzip it to get `Lyrenne.ipa`.

## Installing on the iPad

The .ipa is unsigned; sideloading tools sign it with a free Apple ID (create one at
<https://account.apple.com>, no Apple hardware needed).

1. On Windows, install [iTunes](https://www.apple.com/itunes/) (the non-Store version) and [Sideloadly](https://sideloadly.io).
2. Plug in the iPad, trust the computer, drag `Lyrenne.ipa` into Sideloadly, enter the Apple ID, Start.
3. On the iPad: Settings → General → VPN & Device Management → trust your Apple ID.
   On iPadOS 16+, also turn on Settings → Privacy & Security → Developer Mode.

With a free Apple ID the app expires after 7 days; re-run Sideloadly (it can auto-refresh over Wi-Fi).

## Working from more than one PC

Everything lives in two GitHub repos; nothing machine-specific is committed. The same layout on
every machine (Windows, Linux or Mac) keeps the relative links between them working:

```bash
git clone https://github.com/Doctordefector/Lyrenne       XTool/Windows-Linux/Lyrenne
git clone https://github.com/Doctordefector/Lyrenne-iPad  XTool/iOS/Lyrenne-iPad
```

Pull in both before starting, push before switching machines. `.gitattributes` keeps line endings
LF everywhere, so a checkout on Windows also builds from WSL. The WSL toolchain disk and `xtool/`
(build output, CI screenshots) are per machine and not in git.

## Developing on Windows (WSL)

Optional: CI builds the .ipa. Locally, a WSL distro runs the core check on Linux. Set one up per
machine (on this PC its disk lives at `XTool/iOS/toolchain-wsl/`):

1. `wsl --install -d Ubuntu-24.04`
2. In it: [swiftly](https://www.swift.org/install/linux/) for Swift 6.x; for xtool, the AppImage
   from [xtool releases](https://github.com/xtool-org/xtool/releases) at `/usr/local/bin/xtool`
   (needs `libfuse2t64`); for an iPad over USB, `usbmuxd libimobiledevice-utils`.
3. Only to build or install from Windows without CI (`xtool dev`): download Xcode.xip under a free
   Apple ID from <https://developer.apple.com/download/all/?q=Xcode>, then `xtool setup`, choose
   Password, and give the .xip's path. For USB, [usbipd-win](https://learn.microsoft.com/en-us/windows/wsl/connect-usb)
   `bind`/`attach` the iPad; on `AFCClient.Error.muxError` see
   <https://github.com/xtool-org/xtool/issues/19#issuecomment-2898986718>.

Linux Foundation has no WebSockets, so the Listen Together part of the check only runs on macOS (CI).
Swift UI code can't be compiled on Linux; `swiftc -parse Sources/Lyrenne/*.swift` catches syntax
errors, and CI's simulator screenshots show the result.

```bash
wsl -d Ubuntu-24.04
cd "/mnt/s/Dev/XTool/iOS/Lyrenne-iPad"
swift run lyrenne-check   # live check of the core, on Linux, no SDK needed
```
