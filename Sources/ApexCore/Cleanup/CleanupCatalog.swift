import Foundation

/// The cleanup path catalog.
///
/// Path knowledge is adapted from the Mole CLI (GPL-3.0) and extended. Rules are
/// deliberately narrow: they target directories vendors themselves treat as
/// disposable (`Cache`, `GPUCache`, `Code Cache`, `logs`) rather than whole
/// application-support trees.
public enum CleanupCatalog {
    public static var all: [CleanupRule] {
        userCaches + logs + systemJunk + browsers + developer + aiTools + installers
    }

    public static func rules(for category: CleanupCategory) -> [CleanupRule] {
        all.filter { $0.category == category }
    }

    // MARK: - Application caches

    static var userCaches: [CleanupRule] {
        var rules: [CleanupRule] = []

        // Per-app caches keyed by bundle identifier. These live under
        // ~/Library/Caches/<bundle-id>, which every vendor treats as disposable.
        let bundleCaches: [(String, String)] = [
            ("Slack", "com.tinyspeck.slackmacgap"),
            ("Discord", "com.hnc.Discord"),
            ("Figma", "com.figma.Desktop"),
            ("Notion", "notion.id"),
            ("Obsidian", "md.obsidian"),
            ("Zoom", "us.zoom.xos"),
            ("Microsoft Teams", "com.microsoft.teams2"),
            ("Microsoft Outlook", "com.microsoft.Outlook"),
            ("Microsoft Word", "com.microsoft.Word"),
            ("Microsoft Excel", "com.microsoft.Excel"),
            ("Microsoft PowerPoint", "com.microsoft.Powerpoint"),
            ("OneDrive", "com.microsoft.OneDrive"),
            ("Dropbox", "com.getdropbox.dropbox"),
            ("Google Drive", "com.google.GoogleDrive"),
            ("Box", "com.box.desktop"),
            ("WhatsApp", "net.whatsapp.WhatsApp"),
            ("Telegram", "ru.keepcoder.Telegram"),
            ("Signal", "org.whispersystems.signal-desktop"),
            ("Skype", "com.skype.skype"),
            ("Steam", "com.valvesoftware.steam"),
            ("Epic Games", "com.epicgames.EpicGamesLauncher"),
            ("Battle.net", "com.blizzard.Battle.net"),
            ("GOG Galaxy", "com.gog.galaxy"),
            ("VLC", "org.videolan.vlc"),
            ("IINA", "com.colliderli.iina"),
            ("Plex", "tv.plex.player.desktop"),
            ("Transmission", "org.m0k.transmission"),
            ("qBittorrent", "com.qbittorrent.qBittorrent"),
            ("Sketch", "com.bohemiancoding.sketch3"),
            ("Blender", "org.blenderfoundation.blender"),
            ("DaVinci Resolve", "com.blackmagic-design.DaVinciResolve"),
            ("Cinema 4D", "com.maxon.cinema4d"),
            ("ScreenFlow", "net.telestream.screenflow10"),
            ("CleanShot", "com.cleanshot.*"),
            ("Alfred", "com.runningwithcrayons.Alfred"),
            ("Bear", "com.bear-writer.*"),
            ("Todoist", "com.todoist.mac.Todoist"),
            ("Evernote", "com.evernote.*"),
            ("Logseq", "com.logseq.*"),
            ("GitHub Desktop", "com.github.GitHubDesktop"),
            ("Postman", "com.postmanlabs.mac"),
            ("Insomnia", "com.konghq.insomnia"),
            ("Proxyman", "com.proxyman.NSProxy"),
            ("Charles Proxy", "com.charlesproxy.charles"),
            ("TablePlus", "com.tinyapp.TablePlus"),
            ("Sequel Ace", "com.sequel-ace.sequel-ace"),
            ("MongoDB Compass", "com.mongodb.compass"),
            ("Redis Insight", "com.redis.RedisInsight"),
            ("DBeaver", "com.dbeaver.*"),
            ("Sublime Text", "com.sublimetext.*"),
            ("Ghostty", "com.mitchellh.ghostty"),
            ("Warp", "dev.warp.Warp-Stable"),
            ("Parallels", "com.parallels.*"),
            ("VMware Fusion", "com.vmware.fusion"),
            ("UTM", "com.utmapp.UTM"),
            ("TeamViewer", "com.teamviewer.*"),
            ("AnyDesk", "com.anydesk.*"),
            ("The Unarchiver", "cx.c3.theunarchiver"),
            ("Unity", "com.unity3d.*"),
            ("SketchUp", "com.sketchup.*"),
            ("Autodesk", "com.autodesk.*"),
        ]
        rules += bundleCaches.map {
            CleanupRule("\($0.0) cache", "~/Library/Caches/\($0.1)/*", .userCaches)
        }

        // Adobe keeps very large media caches that are pure scratch space.
        rules += [
            CleanupRule("Adobe application caches", "~/Library/Caches/Adobe/*", .userCaches),
            CleanupRule("Adobe app caches", "~/Library/Caches/com.adobe.*/*", .userCaches),
            CleanupRule(
                "Adobe media cache", "~/Library/Application Support/Adobe/Common/Media Cache Files/*",
                .userCaches, risk: .rebuildCost),
            CleanupRule(
                "Premiere Pro cache", "~/Library/Caches/com.adobe.PremierePro.*/*", .userCaches,
                risk: .rebuildCost),
            CleanupRule(
                "Final Cut Pro cache", "~/Library/Caches/com.apple.FinalCut/*", .userCaches,
                risk: .rebuildCost),
        ]

        // Apple first-party caches that are explicitly disposable.
        rules += [
            CleanupRule(
                "QuickLook thumbnails", "~/Library/Caches/com.apple.QuickLook.thumbnailcache", .userCaches),
            CleanupRule("QuickLook cache", "~/Library/Caches/Quick Look/*", .userCaches),
            CleanupRule("Icon services cache", "~/Library/Caches/com.apple.iconservices*", .userCaches),
            CleanupRule("Help system cache", "~/Library/Caches/com.apple.helpd/*", .userCaches),
            CleanupRule("Maps tile cache", "~/Library/Caches/GeoServices/*", .userCaches, risk: .rebuildCost),
            CleanupRule("Apple Music cache", "~/Library/Caches/com.apple.Music", .userCaches),
            CleanupRule("Apple TV cache", "~/Library/Caches/com.apple.TV/*", .userCaches),
            CleanupRule("Podcasts cache", "~/Library/Caches/com.apple.podcasts", .userCaches),
            CleanupRule(
                "Album art cache", "~/Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches/*",
                .userCaches),
            CleanupRule(
                "App Store cache", "~/Library/Containers/com.apple.AppStore/Data/Library/Caches/*",
                .userCaches),
            CleanupRule(
                "Photo analysis cache", "~/Library/Caches/com.apple.photoanalysisd", .userCaches,
                risk: .rebuildCost),
            CleanupRule(
                "Media analysis cache", "~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/*",
                .userCaches, risk: .rebuildCost),
            CleanupRule("Siri suggestions cache", "~/Library/Suggestions/*", .userCaches),
            CleanupRule("Identity caches", "~/Library/IdentityCaches/*", .userCaches),
            CleanupRule(
                "Wallpaper agent cache",
                "~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/*", .userCaches),
            CleanupRule(
                "Stocks cache", "~/Library/Containers/com.apple.stocks/Data/Library/Caches/*", .userCaches),
            CleanupRule("Messages sticker cache", "~/Library/Messages/StickerCache/*", .userCaches),
            CleanupRule(
                "Messages preview cache", "~/Library/Messages/Caches/Previews/Attachments/*", .userCaches),
            CleanupRule(
                "WebKit network cache", "~/Library/Caches/com.apple.WebKit.Networking/*", .userCaches),
        ]

        // Electron apps share one cache layout; enumerate the common ones.
        //
        // Every one of these carries the bundle identifier it belongs to, so
        // the caches are held back while the app is running. They are Chromium
        // underneath, and emptying `Code Cache` or `GPUCache` under a live
        // Chromium is a documented route to a profile that will not reopen.
        // These rules previously had no quit requirement at all, which made the
        // reassurance in the review sheet untrue for the majority of the
        // catalogue's cache entries.
        let electronApps: [(name: String, bundleID: String)] = [
            ("Slack", "com.tinyspeck.slackmacgap"),
            ("discord", "com.hnc.Discord"),
            ("Claude", "com.anthropic.claudefordesktop"),
            ("Code", "com.microsoft.VSCode"),
            ("legcord", "com.legcord.app"),
            ("mihomo-party", "party.mihomo.app"),
            ("Notion", "notion.id"),
            ("Figma", "com.figma.Desktop"),
            ("Linear", "com.linear"),
            ("Postman", "com.postmanlabs.mac"),
            ("Obsidian", "md.obsidian"),
        ]
        for app in electronApps {
            let quit = [app.bundleID]
            rules += [
                CleanupRule(
                    "\(app.name) HTTP cache", "~/Library/Application Support/\(app.name)/Cache/*",
                    .userCaches, requiresQuit: quit),
                CleanupRule(
                    "\(app.name) code cache",
                    "~/Library/Application Support/\(app.name)/Code Cache/*", .userCaches,
                    requiresQuit: quit),
                CleanupRule(
                    "\(app.name) GPU cache", "~/Library/Application Support/\(app.name)/GPUCache/*",
                    .userCaches, requiresQuit: quit),
                CleanupRule(
                    "\(app.name) shader cache",
                    "~/Library/Application Support/\(app.name)/DawnGraphiteCache/*",
                    .userCaches, requiresQuit: quit),
                CleanupRule(
                    "\(app.name) WebGPU cache",
                    "~/Library/Application Support/\(app.name)/DawnWebGPUCache/*",
                    .userCaches, requiresQuit: quit),
            ]
        }

        rules += [
            CleanupRule(
                "Steam shader cache", "~/Library/Application Support/Steam/steamapps/shadercache/*",
                .userCaches, requiresQuit: ["com.valvesoftware.steam"]),
            CleanupRule(
                "Steam depot cache", "~/Library/Application Support/Steam/depotcache/*", .userCaches,
                requiresQuit: ["com.valvesoftware.steam"]),
            CleanupRule(
                "Steam web cache", "~/Library/Application Support/Steam/htmlcache/*", .userCaches,
                requiresQuit: ["com.valvesoftware.steam"]),
            CleanupRule(
                "Steam app cache", "~/Library/Application Support/Steam/appcache/*", .userCaches,
                requiresQuit: ["com.valvesoftware.steam"]),
            CleanupRule("Battle.net cache", "~/Library/Application Support/Battle.net/Cache/*", .userCaches),
            CleanupRule(
                "Minecraft web cache", "~/Library/Application Support/minecraft/webcache*/*", .userCaches),
            CleanupRule(
                "Saved application states", "~/Library/Saved Application State/*.savedState", .userCaches,
                risk: .noticeable, minimumAgeDays: 30),
        ]

        return rules
    }

    // MARK: - Logs and diagnostics

    static var logs: [CleanupRule] {
        [
            CleanupRule("Diagnostic reports", "~/Library/Logs/DiagnosticReports/*", .appLogs),
            CleanupRule("Crash reports", "~/Library/DiagnosticReports/*", .appLogs),
            CleanupRule("Crashlytics data", "~/Library/Caches/com.crashlytics.data/*", .appLogs),
            CleanupRule("Sentry crash reports", "~/Library/Caches/SentryCrash/*", .appLogs),
            CleanupRule("KSCrash reports", "~/Library/Caches/KSCrash/*", .appLogs),
            CleanupRule("JetBrains IDE logs", "~/Library/Logs/JetBrains/*", .appLogs),
            CleanupRule("CoreSimulator logs", "~/Library/Logs/CoreSimulator/*", .appLogs),
            CleanupRule("Steam logs", "~/Library/Application Support/Steam/logs/*", .appLogs),
            CleanupRule("VS Code logs", "~/Library/Application Support/Code/logs/*", .appLogs),
            CleanupRule("Minecraft logs", "~/Library/Application Support/minecraft/logs/*", .appLogs),
            CleanupRule("Google Cloud logs", "~/.config/gcloud/logs/*", .appLogs),
            CleanupRule("Azure CLI logs", "~/.azure/logs/*", .appLogs),
            CleanupRule(
                "Xcode device logs", "~/Library/Developer/Xcode/iOS Device Logs/*", .appLogs,
                requiresQuit: ["com.apple.dt.Xcode"]),
            CleanupRule(
                "watchOS device logs", "~/Library/Developer/Xcode/watchOS Device Logs/*", .appLogs,
                requiresQuit: ["com.apple.dt.Xcode"]),
        ]
    }

    // MARK: - System junk

    static var systemJunk: [CleanupRule] {
        [
            CleanupRule("User temporary files", "~/Library/Caches/TemporaryItems/*", .systemJunk),
            CleanupRule(
                "Incomplete Safari downloads", "~/Downloads/*.download", .systemJunk, risk: .noticeable,
                minimumAgeDays: 1),
            CleanupRule(
                "Incomplete Chrome downloads", "~/Downloads/*.crdownload", .systemJunk, risk: .noticeable,
                minimumAgeDays: 1),
            CleanupRule(
                "Partial downloads", "~/Downloads/*.part", .systemJunk, risk: .noticeable,
                minimumAgeDays: 1),
            CleanupRule(
                "Recent items list",
                "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.Recent*.sfl*",
                .systemJunk, risk: .noticeable),
            CleanupRule("Shell history backups", "~/.zsh_history.bak*", .systemJunk),
            CleanupRule("Bash history backups", "~/.bash_history.bak*", .systemJunk),
            CleanupRule("Zsh completion cache", "~/.zcompdump*", .systemJunk),
            CleanupRule("less history", "~/.lesshst", .systemJunk),
            CleanupRule("wget HSTS cache", "~/.wget-hsts", .systemJunk),
            CleanupRule("Vim temporary files", "~/.viminfo.tmp", .systemJunk),
            CleanupRule("Git config lock", "~/.gitconfig.lock", .systemJunk),
            CleanupRule(
                "Homebrew download cache", "~/Library/Caches/Homebrew/downloads/*", .systemJunk,
                risk: .rebuildCost),
            CleanupRule(
                "Apple Media Services cache", "~/Library/Caches/com.apple.AppleMediaServices/*", .systemJunk),
            CleanupRule("Duet Expert cache", "~/Library/Caches/com.apple.duetexpertd/*", .systemJunk),
            CleanupRule("Parsecd cache", "~/Library/Caches/com.apple.parsecd/*", .systemJunk),
            CleanupRule("Rosetta 2 update cache", "~/Library/Caches/com.apple.rosetta.update", .systemJunk),
            CleanupRule(
                "Wondershare installer payload", "~/Library/Application Support/com.wondershare.Installer/*",
                .systemJunk),
        ]
    }

    // MARK: - Browsers

    static var browsers: [CleanupRule] {
        var rules: [CleanupRule] = []

        // Every Chromium fork uses the same cache directory names. `pattern`
        // covers both the top-level and per-profile variants.
        let chromium: [(name: String, root: String, quit: String)] = [
            ("Chrome", "~/Library/Application Support/Google/Chrome", "com.google.Chrome"),
            ("Edge", "~/Library/Application Support/Microsoft Edge", "com.microsoft.edgemac"),
            ("Brave", "~/Library/Application Support/BraveSoftware/Brave-Browser", "com.brave.Browser"),
            ("Vivaldi", "~/Library/Application Support/Vivaldi", "com.vivaldi.Vivaldi"),
            ("Arc", "~/Library/Application Support/Arc/User Data", "company.thebrowser.Browser"),
            ("Dia", "~/Library/Application Support/Dia/User Data", "company.thebrowser.dia"),
            ("Opera", "~/Library/Application Support/com.operasoftware.Opera", "com.operasoftware.Opera"),
            (
                "Yandex", "~/Library/Application Support/Yandex/YandexBrowser",
                "ru.yandex.desktop.yandex-browser"
            ),
            ("Chromium", "~/Library/Application Support/Chromium", "org.chromium.Chromium"),
        ]

        let cacheDirs = [
            "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
            "DawnWebGPUCache", "GraphiteDawnCache", "GrShaderCache", "ShaderCache",
            "Application Cache",
        ]

        for browser in chromium {
            for dir in cacheDirs {
                rules.append(
                    CleanupRule(
                        "\(browser.name) \(dir.lowercased())",
                        "\(browser.root)/*/\(dir)/*",
                        .browserData,
                        risk: .rebuildCost,
                        requiresQuit: [browser.quit]
                    )
                )
            }
            rules += [
                CleanupRule(
                    "\(browser.name) component cache", "\(browser.root)/component_crx_cache/*", .browserData,
                    requiresQuit: [browser.quit]),
                CleanupRule(
                    "\(browser.name) extension cache", "\(browser.root)/extensions_crx_cache/*", .browserData,
                    requiresQuit: [browser.quit]),
                CleanupRule(
                    "\(browser.name) crash reports", "\(browser.root)/Crashpad/completed/*", .browserData),
                CleanupRule(
                    "\(browser.name) shader cache", "\(browser.root)/ShaderCache/*", .browserData,
                    requiresQuit: [browser.quit]),
            ]
        }

        rules += [
            CleanupRule(
                "Chrome on-device models",
                "~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel/*", .browserData,
                risk: .rebuildCost, requiresQuit: ["com.google.Chrome"]),
            CleanupRule(
                "Chrome optimization models",
                "~/Library/Application Support/Google/Chrome/optimization_guide_model_store/*", .browserData,
                risk: .rebuildCost, requiresQuit: ["com.google.Chrome"]),
            CleanupRule(
                "Google updater cache", "~/Library/Application Support/Google/GoogleUpdater/crx_cache/*",
                .browserData),
            CleanupRule(
                "Safari cache", "~/Library/Caches/com.apple.Safari/*", .browserData, risk: .rebuildCost,
                requiresQuit: ["com.apple.Safari"]),
            CleanupRule(
                "Firefox profile cache", "~/Library/Application Support/Firefox/Profiles/*/cache2/*",
                .browserData, risk: .rebuildCost, requiresQuit: ["org.mozilla.firefox"]),
            CleanupRule(
                "Firefox cache", "~/Library/Caches/Firefox/*", .browserData, risk: .rebuildCost,
                requiresQuit: ["org.mozilla.firefox"]),
            CleanupRule(
                "Thunderbird cache", "~/Library/Caches/org.mozilla.thunderbird/*", .browserData,
                risk: .rebuildCost),
            CleanupRule("Zen cache", "~/Library/Caches/zen/*", .browserData, risk: .rebuildCost),
            CleanupRule(
                "Orion cache", "~/Library/Caches/com.kagi.kagimacOS/*", .browserData, risk: .rebuildCost),
            CleanupRule(
                "Arc cache", "~/Library/Caches/company.thebrowser.Browser/*", .browserData, risk: .rebuildCost
            ),
        ]

        return rules
    }

    // MARK: - Developer

    static var developer: [CleanupRule] {
        var rules: [CleanupRule] = []

        // Package-manager caches. Every one of these is re-downloadable.
        let packageCaches: [(String, String)] = [
            ("npm cache", "~/.npm/_cacache/*"),
            ("npm logs", "~/.npm/_logs/*"),
            ("Yarn cache", "~/Library/Caches/Yarn/*"),
            ("Yarn Berry cache", "~/.yarn/cache/*"),
            ("pnpm store", "~/Library/pnpm/store/*"),
            ("Bun cache", "~/.bun/install/cache/*"),
            ("Deno cache", "~/Library/Caches/deno/*"),
            ("CocoaPods cache", "~/Library/Caches/CocoaPods/*"),
            ("Carthage cache", "~/Library/Caches/org.carthage.CarthageKit/*"),
            ("Swift Package Manager cache", "~/Library/Caches/org.swift.swiftpm/*"),
            ("Swift PM download cache", "~/.cache/swift-package-manager/*"),
            ("Cargo registry cache", "~/.cargo/registry/cache/*"),
            ("Cargo git cache", "~/.cargo/git/*"),
            ("Rustup downloads", "~/.rustup/downloads/*"),
            ("Go module cache", "~/Library/Caches/go-build/*"),
            ("Ivy cache", "~/.ivy2/cache/*"),
            ("SBT boot cache", "~/.sbt/boot/*"),
            ("Composer cache", "~/Library/Caches/composer/*"),
            ("NuGet cache", "~/.nuget/packages/*"),
            ("Ruby Bundler cache", "~/.bundle/cache/*"),
            ("Gem package cache", "~/.gem/ruby/*/cache/*.gem"),
            ("Poetry cache", "~/.cache/poetry/*"),
            ("pip cache", "~/Library/Caches/pip/*"),
            ("uv cache", "~/.cache/uv/*"),
            ("Hex cache", "~/.hex/cache/*"),
            ("Opam cache", "~/.opam/download-cache/*"),
            ("Cabal cache", "~/.cabal/packages/*"),
            ("CPAN build artifacts", "~/.cpan/build/*"),
        ]
        rules += packageCaches.map { CleanupRule($0.0, $0.1, .developerJunk, risk: .rebuildCost) }

        // Build-tool scratch caches.
        let buildCaches: [(String, String)] = [
            ("Webpack cache", "~/.cache/webpack/*"),
            ("Vite cache", "~/.cache/vite/*"),
            ("Parcel cache", "~/.parcel-cache/*"),
            ("Turbo cache", "~/.turbo/cache/*"),
            ("ESLint cache", "~/.cache/eslint/*"),
            ("Prettier cache", "~/.cache/prettier/*"),
            ("TypeScript cache", "~/.cache/typescript/*"),
            ("Babel cache", "~/.cache/babel-loader/*"),
            ("Bazel cache", "~/.cache/bazel/*"),
            ("node-gyp cache", "~/.cache/node-gyp/*"),
            ("node-gyp build cache", "~/.node-gyp/*"),
            ("Electron cache", "~/.cache/electron/*"),
            ("Electron builder cache", "~/Library/Caches/electron-builder/*"),
            ("Puppeteer browsers", "~/.cache/puppeteer/*"),
            ("Cypress binaries", "~/Library/Caches/Cypress/*"),
            ("Pytest cache", "~/.pytest_cache/*"),
            ("MyPy cache", "~/.cache/mypy/*"),
            ("Ruff cache", "~/.cache/ruff/*"),
            ("pre-commit cache", "~/.cache/pre-commit/*"),
            ("Prisma cache", "~/.cache/prisma/*"),
            ("Terraform plugin cache", "~/.cache/terraform/*"),
            ("Zig cache", "~/.cache/zig/*"),
            ("Flutter cache", "~/.cache/flutter/*"),
            ("Corepack cache", "~/.cache/node/corepack/*"),
            ("Docker BuildX cache", "~/.docker/buildx/cache/*"),
            ("Kubernetes cache", "~/.kube/cache/*"),
            ("AWS CLI cache", "~/.aws/cli/cache/*"),
            ("Android build cache", "~/.android/build-cache/*"),
            ("Android SDK cache", "~/.android/cache/*"),
        ]
        rules += buildCaches.map { CleanupRule($0.0, $0.1, .developerJunk, risk: .rebuildCost) }

        // Xcode. Derived data is the single biggest win on most developer Macs.
        rules += [
            CleanupRule(
                "Xcode derived data", "~/Library/Developer/Xcode/DerivedData/*", .developerJunk,
                risk: .rebuildCost, requiresQuit: ["com.apple.dt.Xcode"]),
            CleanupRule(
                "Xcode build products", "~/Library/Developer/Xcode/Products/*", .developerJunk,
                risk: .rebuildCost, requiresQuit: ["com.apple.dt.Xcode"]),
            CleanupRule(
                "Xcode documentation cache", "~/Library/Developer/Xcode/DocumentationCache/*", .developerJunk,
                risk: .rebuildCost, requiresQuit: ["com.apple.dt.Xcode"]),
            CleanupRule(
                "Xcode module cache", "~/Library/Developer/Xcode/ModuleCache.noindex/*", .developerJunk,
                risk: .rebuildCost, requiresQuit: ["com.apple.dt.Xcode"]),
            CleanupRule(
                "Xcode cache", "~/Library/Caches/com.apple.dt.Xcode/*", .developerJunk, risk: .rebuildCost,
                requiresQuit: ["com.apple.dt.Xcode"]),
            CleanupRule(
                "Simulator caches", "~/Library/Developer/CoreSimulator/Caches/*", .developerJunk,
                risk: .rebuildCost,
                requiresQuit: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),
            CleanupRule(
                "Simulator temp files", "~/Library/Developer/CoreSimulator/Devices/*/data/tmp/*",
                .developerJunk,
                requiresQuit: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),
            CleanupRule(
                "Interface Builder cache", "~/Library/Developer/Xcode/UserData/IB Support/*", .developerJunk,
                requiresQuit: ["com.apple.dt.Xcode"]),
            CleanupRule(
                "Android Studio cache", "~/Library/Caches/Google/AndroidStudio*/*", .developerJunk,
                risk: .rebuildCost),
            CleanupRule("Expo caches", "~/.expo/*-cache/*", .developerJunk, risk: .rebuildCost),
            CleanupRule("Vagrant temporary files", "~/.vagrant.d/tmp/*", .developerJunk),
            CleanupRule("Jupyter runtime cache", "~/.jupyter/runtime/*", .developerJunk),
            CleanupRule("Oh My Zsh cache", "~/.oh-my-zsh/cache/*", .developerJunk),
            CleanupRule(
                "VS Code cached data", "~/Library/Application Support/Code/CachedData/*", .developerJunk,
                risk: .rebuildCost),
            CleanupRule(
                "VS Code extension cache", "~/Library/Application Support/Code/CachedExtensions/*",
                .developerJunk, risk: .rebuildCost),
        ]

        return rules
    }

    // MARK: - AI tooling

    static var aiTools: [CleanupRule] {
        [
            CleanupRule("PyTorch model cache", "~/.cache/torch/*", .aiTools, risk: .rebuildCost),
            CleanupRule("TensorFlow cache", "~/.cache/tensorflow/*", .aiTools, risk: .rebuildCost),
            CleanupRule("Weights & Biases cache", "~/.cache/wandb/*", .aiTools),
            CleanupRule(
                "LM Studio cache", "~/Library/Caches/com.lmstudio.lmstudio/*", .aiTools, risk: .rebuildCost),
            CleanupRule("Ollama temporary blobs", "~/.ollama/models/blobs/*-partial*", .aiTools),
            CleanupRule("ChatGPT desktop cache", "~/Library/Caches/com.openai.chat/*", .aiTools),
            CleanupRule(
                "Claude desktop cache", "~/Library/Caches/com.anthropic.claudefordesktop/*", .aiTools),
            CleanupRule("Claude sentry cache", "~/Library/Application Support/Claude/sentry/*", .aiTools),
            CleanupRule("Claude logs", "~/Library/Logs/Claude/*", .aiTools),
            CleanupRule("OpenCode cache", "~/.cache/opencode/*", .aiTools),
            CleanupRule("OpenCode logs", "~/.local/share/opencode/log/*", .aiTools),
            CleanupRule("Copilot CLI cache", "~/.copilot/cache/*", .aiTools),
            CleanupRule(
                "Cursor cache", "~/Library/Application Support/Cursor/Cache/*", .aiTools,
                requiresQuit: ["com.todesktop.230313mzl4w4u92"]),
            CleanupRule(
                "Cursor cached data", "~/Library/Application Support/Cursor/CachedData/*", .aiTools,
                risk: .rebuildCost, requiresQuit: ["com.todesktop.230313mzl4w4u92"]),
            CleanupRule(
                "Cursor GPU cache", "~/Library/Application Support/Cursor/GPUCache/*", .aiTools,
                requiresQuit: ["com.todesktop.230313mzl4w4u92"]),
            CleanupRule(
                "Windsurf cache", "~/Library/Application Support/Windsurf/Cache/*", .aiTools,
                requiresQuit: ["com.exafunction.windsurf"]),
            CleanupRule(
                "Windsurf cached data", "~/Library/Application Support/Windsurf/CachedData/*", .aiTools,
                risk: .rebuildCost, requiresQuit: ["com.exafunction.windsurf"]),
            CleanupRule(
                "Zed language server cache", "~/Library/Caches/Zed/*", .aiTools,
                risk: .rebuildCost, requiresQuit: ["dev.zed.Zed"]),
        ]
    }

    // MARK: - Installers

    static var installers: [CleanupRule] {
        [
            CleanupRule(
                "Homebrew cask downloads", "~/Library/Caches/Homebrew/Cask/*", .installers, risk: .rebuildCost
            )
        ]
    }
}
