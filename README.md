# Compose Multiplatform iOS: the accessibility display link keeps running after a tree read

A minimal reproduction of a Compose Multiplatform (CMP) bug on iOS. Once anything reads a Compose
screen's accessibility tree (VoiceOver, Voice Control, Switch Control, an XCUITest-based test tool,
the Accessibility Inspector), CMP starts a `CADisplayLink`. If the screen then stays static, nothing
ever stops it: the app's main thread wakes on every display frame for as long as the process lives,
in front and behind Home.

- YouTrack issue: [CMP-11004](https://youtrack.jetbrains.com/issue/CMP-11004)
- Upstream fix: _TBD (link to the compose-multiplatform-core pull request)_

## Why it matters

A suspended iOS app costs nothing, so most apps never notice. Two groups do:

- **Apps with a background mode** (audio, location, Bluetooth, VoIP). They keep running behind Home,
  and so does the display link. In this repository's measurement the app's CPU almost triples and
  its wakeups rise from about 2 to about 64 per second behind Home, with nothing on screen and no
  work to do. Frequent wakeups keep the CPU from idling deeply, which is what costs battery.
- **People who use assistive technology.** CMP skips the cleanup while VoiceOver focus is inside the
  Compose view (see below), so for a VoiceOver user the display link runs the whole time the app is
  open, static screens included. Measured: with VoiceOver on and focus resting on the static screen,
  the app sits at 62 wakeups/s and 0.8 % CPU, against 2/s and 0.1 % for the same screen without
  VoiceOver.

The finding came from a production app with a background audio mode: paused behind Home after a
UI-test runner had read its tree, it used 1.56 % CPU at about 132 wakeups/s, against 0.38 % and
about 13/s when the same state was reached without the tree read.

## Results

iPhone 12 Pro (60 Hz display), iOS 27.0.1, Release build, each run a fresh launch, 60 s window
starting 10 s after the last action, runs interleaved across scenarios. CPU is a share of one core
(100 % = one core busy), from the process's cumulative CPU time; wakeups are the kernel's interrupt
wakeups for the process. Mean ± standard deviation, range in brackets.

**CMP 1.12.1, Kotlin 2.4.20 (4 runs each)**

| Scenario | App state | CPU % | Wakeups/s |
|---|---|---|---|
| (a) control: no tree read | foreground, static screen | 0.09 ± 0.02 [0.08–0.12] | 2.1 ± 0.0 [2.1–2.2] |
| (b) tree read once | foreground, static screen | 0.93 ± 0.13 [0.80–1.09] | 84.5 ± 27.0 [62.0–118.2] |
| (c) tree read once | behind Home, background audio | 1.26 ± 0.01 [1.24–1.27] | 63.6 ± 0.9 [62.8–64.8] |
| (d) control: no tree read | behind Home, background audio | 0.44 ± 0.00 [0.44–0.44] | 2.2 ± 0.0 [2.1–2.2] |

**CMP 1.13.0-beta01 (the newest published pre-release), Kotlin 2.4.20 (3 runs each)**

| Scenario | App state | CPU % | Wakeups/s |
|---|---|---|---|
| (a) control: no tree read | foreground, static screen | 0.11 ± 0.02 [0.08–0.12] | 2.2 ± 0.0 [2.2–2.3] |
| (b) tree read once | foreground, static screen | 0.89 ± 0.11 [0.81–1.01] | 76.2 ± 24.7 [61.9–104.8] |
| (c) tree read once | behind Home, background audio | 1.30 ± 0.07 [1.25–1.39] | 71.3 ± 14.7 [62.0–88.3] |
| (d) control: no tree read | behind Home, background audio | 0.44 ± 0.01 [0.44–0.45] | 2.2 ± 0.0 [2.2–2.2] |

**It does not wear off.** One `read-bg` process, sampled again without touching it (CMP 1.12.1):

| Time since leaving the app | CPU % | Wakeups/s |
|---|---|---|
| 2 min | 1.29 | 63.0 |
| 10 min | 1.27 | 62.0 |
| 30 min | 1.27 | 63.0 |

**With VoiceOver on** (CMP 1.12.1). VoiceOver switched on in Settings, the app launched, VoiceOver's
focus left where it landed on the first element, nothing touched; three consecutive 60 s windows of
one process, starting 10 s after launch:

| Window | CPU % | Wakeups/s |
|---|---|---|
| 1 (10–70 s after launch) | 0.94 | 92.0 |
| 2 | 0.80 | 62.0 |
| 3 | 0.80 | 62.0 |

From the second minute on it is the same per-frame floor as after a one-shot UI-test read, and it
does not decay. The first window is higher while VoiceOver is still reading the new screen.

Reading the numbers:

- The floor after a read is about 62 wakeups/s: one per frame of the 60 Hz display plus the app's
  baseline of about 2. Some runs sit higher (up to 118/s); the cause of that spread was not
  investigated. The control runs never left 2.1–2.3/s.
- Behind Home, (c) − (d) is the cost of the bug alone: about +0.8 % of a core and +61 wakeups/s.
  The 0.44 % baseline in (d) is the silent audio itself.
- In front, CMP's own render loop is idle on a static screen (control: 2 wakeups/s), so the extra
  60+ wakeups/s there are the accessibility display link too.

## Root cause

All links point at [`Accessibility.ios.kt`][file] on `jb-main` at commit `117bb897` (2026-10-23).
The same code ships in CMP 1.12.1, and 1.13.0-beta01 behaves the same on the device.

1. **A read starts the display link.** Every read of the tree from iOS goes through
   `AccessibilityRoot`: [`accessibilityElements()`][read1], [`focusItemsInRect()`][read2] and
   [`accessibilityHitTest()`][read3] each call `activateAccessibilityIfNeeded()`. On the first read
   that [calls `sync()`][activate], and `sync()` [creates and starts a `DisplayLinkListener`][start]
   when none runs: a `CADisplayLink` [added to the main run loop in common modes][dl].
2. **Only `cleanUp()` stops it** ([invalidates the listener][cleanup]), and `cleanUp()` runs only
   from the 2-second timer in [`scheduleAccessibilityDisablingAndCleanup()`][schedule].
3. **The timer is armed only by a semantics change.** Its one caller outside `dispose()` is the
   [invalidation loop][loop], which runs after `onSemanticsChange()`/`onLayoutChange()`.
4. **Every read disarms it.** `activateAccessibilityIfNeeded()` ends in
   [`cancelAccessibilityDisabling()`][cancel] and never re-arms the timer. So when the last read
   comes after the last semantics change (always the case on a screen that is static after it was
   read), `cleanUp()` never runs and the display link fires every frame until the view is disposed.
5. **With VoiceOver focus inside the view, the timer is never armed at all**:
   `scheduleAccessibilityDisablingAndCleanup()` [returns early][early] when [`hasFocusedElement()`][focused]
   (or keyboard focus, or `KeepFocus`).

The display link has one consumer: [`scrollToAccessibilityElement`][scroll] uses its `frameClock` to
animate scrolling a focused element into view. Between such scrolls it has nothing to do.

**Seen in a profile.** A 10 s Time Profiler trace (all processes) of the app behind Home has 96
main-thread samples (1 sample = 1 ms of CPU) after a tree read, against 7 in the control. Almost
all of them are the main run loop waking up and dispatching the frame (`mach_msg`, `UpdateCycle`);
`DisplayLinkListener$start$1.animationDidUpdate` itself shows in one sample. The cost is the
per-frame wakeup, not work done in Kotlin.

## Proposed fix

Two independent changes; the first one alone removes the cost in every scenario above.

1. **Run the display link only while it is needed.** Start it in `scrollToAccessibilityElement` when
   a scroll job is launched, and invalidate it when that job completes or is cancelled, instead of
   starting it in `sync()`. The frame clock exists only for that scroll animation, so nothing else
   changes. This also covers VoiceOver users idling on a static screen: the tree stays (VoiceOver
   needs it), but nothing ticks.

   ```kotlin
   private fun scrollToAccessibilityElement(element: NSObject) {
       if (root.element == null) return // was: displayLinkListener ?: return
       val scrollableContainer = findFirstAccessibilityElementInHierarchy(element) {
           it.node.semanticsNode.canScroll
       } ?: return
       scrollJob?.cancel()
       val listener = displayLinkListener ?: DisplayLinkListener().also {
           it.start()
           displayLinkListener = it
       }
       val rect = /* unchanged */
       val job = CoroutineScope(coroutineContext + listener.frameClock).launch {
           scrollableContainer.node.semanticsNode.scrollToCenterRectIfNeeded(rect, safeAreaRectInWindow)
       }
       scrollJob = job
       job.invokeOnCompletion {
           if (scrollJob === job) {
               scrollJob = null
               displayLinkListener?.invalidate()
               displayLinkListener = null
           }
       }
   }
   ```

   (A sketch against `117bb897`, not compiled. `sync()` drops its display-link start; `cleanUp()`
   keeps its `invalidate()` for `dispose()`.)

2. **Let a read re-arm the idle cleanup.** Make the 2-second cleanup a debounce on the *last read*
   rather than a timer that a read cancels: record a monotonic time mark in
   `activateAccessibilityIfNeeded()`, keep at most one cleanup job, and let it wait until two
   seconds have passed since the latest read before calling `cleanUp()`. The focus checks
   (`hasFocusedElement()`, keyboard focus, `KeepFocus`) are then evaluated when the job fires, not
   only when it is scheduled, so a VoiceOver user who leaves focus in the view keeps the tree.
   This frees the accessibility element tree after automation or a short assistive-tech session;
   with change 1 it is a memory question, not a CPU one.

## Reproduce it

Needs a Mac with Xcode 27 and a JDK 17+, an iPhone in Developer Mode on USB with Auto-Lock off,
an Apple development team, and [`uv`](https://docs.astral.sh/uv/) for the sampler
([pymobiledevice3](https://github.com/doronz88/pymobiledevice3) 11.26.0, pulled by `uvx`; no root,
no tunnel daemon).

```bash
TEAM_ID=ABCDE12345 BUNDLE_ID_PREFIX=com.yourname scripts/build.sh
UDID=<iPhone UDID> scripts/measure.sh -n 4 -s 60 read-bg control-bg read-fg control-fg
```

`build.sh` builds the Release app and the UI-test runner (the Kotlin framework is compiled by the
Xcode build phase). `CMP_VERSION=1.13.0-beta01 DERIVED_DATA=build/dd-1.13 scripts/build.sh` builds
against another release; pass the same `DERIVED_DATA` to `measure.sh`.

`measure.sh` installs the app, then for each run:

| Scenario | Steps |
|---|---|
| `control-fg` | launch, wait 10 s, sample |
| `read-fg` | launch, wait 10 s, run the UI test, wait 10 s, sample |
| `read-bg` | launch with `-backgroundAudio YES`, wait 10 s, run the UI test, open the Settings app, wait 10 s, sample |
| `control-bg` | launch with `-backgroundAudio YES`, wait 10 s, open the Settings app, wait 10 s, sample |

Details that matter for a clean result:

- **The UI test attaches, it does not launch.** [`TreeReadTests`](iosApp/ReproUITests/TreeReadTests.swift)
  uses `XCUIApplication(bundleIdentifier:)` on the running app, queries one button and one text and
  takes one snapshot, then ends. The app is neither relaunched nor terminated, and after the test
  nothing reads its tree again.
- **The app goes behind Home by opening another app** (`devicectl ... launch com.apple.Preferences`),
  not by `XCUIDevice.press(.home)`: test tools tend to read the tree again around a Home press.
- **The background mode is real but silent.** With `-backgroundAudio YES` the app loops a buffer of
  silence through `AVAudioEngine` ([`SilentAudio.swift`](iosApp/ReproApp/SilentAudio.swift)), so iOS
  keeps it running behind Home, as for any app with an audio background mode.
- **The screen is static.** [`App.kt`](composeApp/src/commonMain/kotlin/repro/App.kt): two texts, two
  buttons and a 30-row `LazyColumn`; nothing animates.
- [`scripts/sample.py`](scripts/sample.py) reads Instruments' `sysmontap` service once a second and
  reports CPU from cumulative CPU time and wakeups from the process's interrupt-wakeup counter. Stop
  any live device log stream (`pymobiledevice3 syslog live`, Console) before measuring: streaming
  every log line off the phone costs the device far more than this bug.

The per-run JSON summaries behind the tables are in [`results/`](results/).

## Environment

| | |
|---|---|
| Device | iPhone 12 Pro (iPhone13,3), 60 Hz display |
| iOS | 27.0.1 (24A446) |
| Mac | macOS 26.6.2, Xcode 27.0 (27A266a) |
| Compose Multiplatform | 1.12.1 (also 1.13.0-beta01); material3 1.9.0 |
| Kotlin | 2.4.20 |
| Gradle | 9.6.1 |
| Sampler | pymobiledevice3 11.26.0 (`sysmontap`, userspace tunnel) |

## Open points

- The VoiceOver case was measured in the foreground only (above). Behind Home with VoiceOver on was
  not measured separately.
- The upward spread of the wakeup rate in some runs (62 to 118/s) is not explained.

## Layout

```
composeApp/        Kotlin Multiplatform module: the Compose screen and MainViewController()
iosApp/            Xcode project (generated from project.yml with XcodeGen 2.46, committed)
  ReproApp/        UIKit host app, optional silent background audio
  ReproUITests/    the one-shot tree read
scripts/           build.sh, measure.sh, sample.py
```

## License

MIT, see [LICENSE](LICENSE).

[file]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt
[read1]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L466-L472
[read2]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L485-L492
[read3]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L494-L499
[activate]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1343-L1349
[cancel]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1338-L1341
[start]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1699-L1702
[cleanup]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1413-L1415
[schedule]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1314-L1329
[early]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1315-L1320
[focused]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1331-L1336
[loop]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1277-L1283
[scroll]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/platform/Accessibility.ios.kt#L1183-L1205
[dl]: https://github.com/JetBrains/compose-multiplatform-core/blob/117bb897e8c25e9aef0b30e406e43128619cc983/compose/ui/ui/src/iosMain/kotlin/androidx/compose/ui/window/DisplayLinkListener.ios.kt#L36-L52
