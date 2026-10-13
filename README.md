# Little Ripper

A native macOS app for ripping optical discs that feels like Apple made it. Insert a
CD, DVD, or Blu-ray and Little Ripper identifies it, rips it, names and files it for
Plex and Jellyfin, keeps an exact burnable backup, and ejects it — either fully
automatically or asking you what to do per disc.

**Platform:** macOS 14+ (Apple silicon) · **Language:** Swift / SwiftUI · **License:** MIT

---

## What it does

- **Audio CDs** → bit-accurate FLAC with a cue sheet and rip log (secure `cd-paranoia`
  rip + verified `flac` encode). The FLAC + cue pair burns back to an identical CD.
  Tagged automatically from MusicBrainz, falling back to the metadata macOS already
  fetched (Gracenote), with cover art from the Cover Art Archive or iTunes.
- **DVDs & Blu-rays** → your choice of either or both copies, read from the disc only
  once:
  - **For Plex & Jellyfin** — MKV files named and foldered exactly how those servers
    expect (`Movies/Title (Year)/Title (Year).mkv`,
    `TV Shows/Show/Season 01/Show - S01E01.mkv`), with a `poster.jpg`.
  - **Exact backup** — full decrypted disc copy (MakeMKV `backup --decrypt`), plus a
    burnable `.iso` for DVDs.
  - Titles are identified against [The Movie Database](https://www.themoviedb.org)
    (optional API key) so even a mangled disc label becomes a correct name.
- **Burn audio CDs** back from any album in your library — or any folder or `.cue` on
  disk — using Apple's native DiscRecording engine.
- **Fix names after the fact** — an *Edit info* action re-tags, renames, re-files, and
  re-fetches art for an album, movie, or show whose disc was mislabeled.
- **Two modes:** *Automatic* (rips and ejects on its own) or *Ask Each Time* (reads
  the disc, then you choose).
- **Multiple drives at once** — rips them in parallel, one disc per drive.
- **Auto-updates** via [Sparkle](https://sparkle-project.org), live progress, a queue,
  history, and desktop notifications.

## Library layout

```
~/Movies/Little Ripper/          (configurable in Settings → General)
├── Movies/
│   └── The Matrix (1999)/The Matrix (1999).mkv   (+ poster.jpg)
├── TV Shows/
│   └── The Wire (2002)/Season 01/The Wire - S01E01.mkv
├── Music/
│   └── Radiohead/OK Computer (1997)/01 - Airbag.flac   (+ .cue, Rip Log.txt, cover.jpg)
└── Backups/
    ├── DVD/The Matrix/               (VIDEO_TS)  + The Matrix.iso
    └── Blu-ray/The Matrix/           (BDMV)
```

## Install (users)

Download the latest notarized build, unzip, and drag it to **Applications**. Audio-CD
ripping and burning work out of the box — `cd-paranoia`, `flac`, and `metaflac` are
bundled inside the app. **DVD/Blu-ray ripping additionally requires
[MakeMKV](https://makemkv.com)** (free during its beta; open it once to enter the key).
Updates install themselves via Sparkle.

## Build from source

Requires macOS 14+ and the Xcode command-line tools.

```bash
# Development: build and run in place. Install the backends it drives:
brew install libcdio-paranoia flac
brew install --cask makemkv          # only needed for DVD/Blu-ray
swift run

# A distributable .app bundle (compiles release, bundles the audio tools + their
# dylibs + Sparkle, renders the icon, and code-signs):
./Scripts/build-app.sh
open "build/Little Ripper.app"
```

The **Engines** tab in Settings shows which backends are found and the exact install
command for anything missing. In development, Little Ripper finds the tools on your
`PATH`; `build-app.sh` copies them into the `.app` so a released build needs no
Homebrew.

### Signing, notarizing, releasing

`build-app.sh` auto-detects a *Developer ID Application* certificate and signs with a
hardened runtime (falling back to ad-hoc if none is present). The other scripts need
your own Apple credentials and are no-ops without them:

```bash
./Scripts/notarize.sh      # submit to Apple's notary service + staple (needs your API key)
./Scripts/make-release.sh  # build → notarize → package → sign the Sparkle update → write appcast
```

None of these credentials live in the repo. See `Scripts/notarize.sh` for the two ways
to supply notary credentials; `Scripts/notary.env` is gitignored.

### Forking / your own distribution

To ship your own build, override the defaults (they're environment variables in
`build-app.sh`) and generate your own Sparkle keys:

```bash
# one-time: a signing keypair (private key → your keychain, public key printed)
.build/artifacts/sparkle/Sparkle/bin/generate_keys

BUNDLE_ID=com.example.littleripper \
FEED_URL=https://example.com/littleripper/appcast.xml \
SU_PUBLIC_ED_KEY="<your public key from generate_keys>" \
  ./Scripts/build-app.sh
```

The landing page and Cloudflare Worker that distribute the official build aren't part
of this repository; provide your own hosting and point `FEED_URL` at it.

## How it works

- **DiskArbitration** (`DiscMonitor`) watches for optical media appearing/disappearing.
- **`DiscInspector`** waits for the volume to mount and classifies it (cddafs → CD,
  `VIDEO_TS` → DVD, `BDMV` → Blu-ray), reading the CD metadata macOS already fetched
  from the mounted `.aiff` filenames.
- **`RipEngine`** serializes jobs *within* a single drive but runs different drives in
  parallel. It streams each backend's progress into the UI and moves finished output
  out of a hidden `.ripping` staging folder into the library only once complete.
- **Rippers** wrap the backends: `AudioCDRipper` (cd-paranoia + flac + metaflac),
  `VideoDiscRipper` (MakeMKV), `CDBurner`/`BurnController` (DiscRecording).
- MusicBrainz disc IDs are computed natively (SHA-1 over the TOC); no extra tools.

The code is organized as `Models/`, `Services/` (the engines and lookups), `Views/`
(SwiftUI), and `App/` (app entry + shared `AppState`), under `Sources/LittleRipper/`.

## Third-party components

Little Ripper drives independent programs rather than reinventing them. It invokes each
as a separate process at runtime; it does not statically link the GPL tools.

| Component | Used for | License | In release build? |
|-----------|----------|---------|-------------------|
| [cd-paranoia](https://www.gnu.org/software/libcdio/) (libcdio-paranoia) | Secure audio-CD extraction | GPL | Bundled |
| [FLAC / metaflac](https://xiph.org/flac/) | Lossless encode + tagging | BSD (libFLAC) / GPL (tools) | Bundled |
| [Sparkle](https://sparkle-project.org) | Auto-updates | MIT | Bundled (framework) |
| [MakeMKV](https://makemkv.com) | DVD/Blu-ray rip & decrypt | Proprietary | **Not** bundled — user installs |

Metadata comes from MusicBrainz, the Cover Art Archive, Apple's iTunes Search API, and
The Movie Database. Redistribute any bundled binaries per their licenses.

## Contributing

Issues and pull requests are welcome. Keep the existing style: doc comments on types
and non-obvious logic, no force-unwraps except on constant literals, and UI strings
that read like Apple wrote them. `swift build` should stay warning-clean.

## Legal

Only rip discs you own. Decryption of commercial discs may be regulated where you live;
this tool is for personal archival of your own collection.

## License

MIT © 2026 Gabriel Jeffrey. See [LICENSE](LICENSE) — note the third-party components
above keep their own licenses.
