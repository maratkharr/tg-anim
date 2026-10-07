load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "CirclesGridNode",
    module_name = "CirclesGridNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/ContextUI",
        "//submodules/PhotoResources",
        "//submodules/TelegramStringFormatting",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/GridMessageSelectionNode",
        "//submodules/TelegramUniversalVideoContent",
        "//submodules/TelegramUI/Components/Chat/InstantVideoRadialStatusNode",
        "//submodules/FileMediaResourceStatus",
        "//submodules/AppBundle",
        "//submodules/ComponentFlow",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/TelegramUI/Components/GlobalControlPanelsContext",
        "//submodules/TelegramUI/Components/MediaPlaybackHeaderPanelComponent",
        "//submodules/TelegramUI/Components/HeaderPanelContainerComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)
