# Live Stack

Turns a batch of Live Photos into snappy bounce loops and cuts them into one vertical reel, with transitions,
camera motion, lifted-subject stickers and a title. Native iOS 17+, SwiftUI + AVFoundation, no server.

## Open and run

1. Open `LiveStack.xcodeproj` in Xcode 16 or newer.
2. Select the `LiveStack` target, set your Team under Signing & Capabilities (the project ships with an empty team
   and bundle id `com.example.LiveStack`; change both to yours).
3. Run on a real iPhone. The simulator has no Live Photos, but every test runs there.

If the project refuses to open on your Xcode, regenerate it: `brew install xcodegen && xcodegen generate`
(the spec is `project.yml`, equivalent to the checked-in project).

## Without Xcode on your Mac

You do not need Xcode installed to build, test or install this app. The iOS SDK only ships inside Xcode, so the
compiling happens on GitHub's macOS runners instead:

1. Push this folder to a GitHub repository. `.github/workflows/ios.yml` runs on every push: core tests on Linux,
   then on macOS a simulator build, the integration tests, the UI smoke test, and an **unsigned IPA** as a
   downloadable artifact. A public repository gets unlimited free minutes; a private one has a monthly quota
   (macOS minutes count ten to one).
2. Fix-and-rerun loop: Claude Code connected to the repository can push changes and read the run logs, so the
   compile errors from the first run get fixed without a Mac toolchain.
3. Install on your iPhone with a free Apple ID using a sideloading tool on the Mac: [Sideloadly](https://sideloadly.io)
   or [AltStore](https://altstore.io). Download `LiveStack-unsigned.ipa` from the Actions run, drag it into the
   tool with your iPhone connected, sign in with your Apple ID. The app expires after 7 days with a free Apple ID;
   install it again to renew. A paid developer account removes that limit and allows TestFlight from CI.

What is lost without Xcode: the visual debugger and instruments. Everything else in this README still applies.

## Verify

```sh
scripts/verify.sh "iPhone 16"
```

That runs, in order:

| Step | What runs | What it proves |
|---|---|---|
| 1 | `swift test` in `Packages/LiveStackCore` (32 tests, pure Swift) | Loop plans, bounce order, timeline overlap maths, span partitioning, fit and zoom geometry, transition endpoints, sticker poses, motion energy, auto cut and shuffle |
| 2 | `xcodebuild build` for the simulator | The app compiles |
| 3 | `xcodebuild test -only-testing:LiveStackTests` | Integration tests on the real media pipeline using synthetic videos: loop file duration vs plan, bounce symmetry, speed, motion analysis finds the moving stretch, composition matches the timeline, exported MP4 shows each loop's colour at its midpoint and a blend inside a fade, slide shows both sides, stickers and title are baked in, flash peaks white, GIF frame count, project model import, shuffle, reset, re-render and export |
| 4 | `xcodebuild test -only-testing:LiveStackUITests` | The tab shell launches |

Or in Xcode: `Cmd+U` on the `LiveStack` scheme runs steps 1, 3 and 4.

`.github/workflows/ios.yml` runs the same on every push (core on Linux, app on macOS).

## How it works

```
Photos library ──PHAssetResource (paired video)──▶ MotionAnalyzer ──energy, filmstrip──▶ AutoCut (core) ──LoopSpec──▶ LoopRenderer
                                                                                                                      │
   AVAssetReader decodes only the window ─▶ frames reordered by LoopPlan.playOrder ─▶ AVAssetWriter ─▶ loop.mp4 ◀─────┘
                                                                                                        │
ReelComposer: two alternating tracks, ReelTimeline (core) places loops with overlap, per-span transform and opacity ramps
              implement fade / slide / zoom / flash / cut, Ken Burns zoom, crop-to-fill or fit; stickers, title and flashes
              are CALayers driven by item-time animations (AVSynchronizedLayer for preview, AVVideoCompositionCoreAnimationTool for export)
                                                                                                        │
ReelExporter: AVAssetExportSession ─▶ 1080-wide MP4 ─▶ Photos          ImageIO ─▶ looping GIF (per loop or whole reel)
```

* `Packages/LiveStackCore` has no UIKit or AVFoundation. Everything that is maths lives there so it can be tested anywhere.
* One loop is decoded and encoded at a time (`LoopRenderer` is an actor). The phone never has more than a couple of
  decoders open, which was the failure mode of the web prototype.
* The picker grid plays Live Photos with `PHLivePhotoView`; cells only play while on screen.
* Stickers come from any photo. `SubjectLifter` uses Vision's foreground instance mask (the same lift as touch and hold
  in Photos). Drag, pinch and twist them on the loop preview.
* The reel preview is the same composition the export uses, so what you see is what you get. Reels are silent; add music
  when posting.

## Project layout

```
LiveStack/                 app target (SwiftUI)
  Models/Project.swift     LoopClip, Sticker, LoopAsset, errors, paths
  Services/                PhotoLibrary, MotionAnalyzer, LoopRenderer, ReelComposer (+OverlayBuilder), ReelExporter, SubjectLifter
  ViewModels/ProjectModel  import, editing, debounced renders, reel rebuilds, exports
  Views/                   ContentView (tabs), PickView (playing grid), LoopsView, LoopEditorView, ReelView
LiveStackTests/            integration tests + SyntheticVideo helper
LiveStackUITests/          launch smoke test
Packages/LiveStackCore/    pure Swift package with its own tests
scripts/verify.sh          runs everything
```

## Known limits

* Needs iOS 17 for the subject lifter and the Live Photo grid APIs used.
* Transitions are approximated per span with linear ramps (exact at span boundaries). Zoom-in-while-sliding is a
  linear blend of both; visually fine, not mathematically separate.
* "Fit on black" is letterboxing; no blurred background variant yet.
* Audio is dropped on purpose.
