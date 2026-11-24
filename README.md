# سبحة — Watch tasbeeh counter

An Apple Watch app for counting tasbeeh: سبحان الله → الحمد لله → الله أكبر, repeating.

## How it works

1. Open the app. Tap **33** or **99** to pick the count per statement.
2. The current statement fills the screen. **Tap anywhere** to count one.
   Each tap vibrates the Watch (a light click).
3. When the round finishes, the Watch plays a stronger vibration, speaks the next
   statement in Arabic, and moves to it.
4. The screen shows the current count, the round target, the total so far, and a
   small row of totals per statement. **إعادة** (Reset) clears everything after
   confirmation.

On watchOS 11 or later (Series 9 / Ultra 2 and newer), the native double-tap
gesture also counts — but only while the wrist is raised. Apple disables the
gesture when the wrist is down.

While counting, a `mindfulness` extended runtime session keeps the app alive, so
a lowered wrist does not end the session. Counting itself still needs a screen
tap until gesture detection is proven (see the probe below).

## Storage

The counter state lives in `Documents/tasbeeh.sqlite` inside the Watch app.
Every tap saves immediately, so force-quitting loses nothing. Reopening the app
resumes the round exactly where it stopped.

## Spoken statements

Three short clips ship in the app bundle (`WatchApp/Audio/*.m4a`), generated
with the macOS Majed voice:

```sh
say -v Majed -r 150 -o subhan_allah.aiff "سبحان الله"
afconvert -f m4af -d aac -b 48000 subhan_allah.aiff subhan_allah.m4a
```

To use real recordings instead, replace the three `.m4a` files with recordings
using the same names, and rebuild.

## Motion probe (test tool)

The first screen's **اختبار الحركة** link opens the original Core Motion probe.
It records 30 seconds of wrist movement to `Documents/MotionProbe/motion.sqlite`
plus CSV. Its job is to answer whether a thumb–finger touch can be detected in
motion data with the wrist down — the future counting trigger.

It has **not yet run on a real Watch**. Finger counting by motion alone is
unproven, which is why the app counts on taps for now.

The probe tests are unchanged; see `WatchApp/ProbeView.swift` and
`WatchApp/ProbeRecorder.swift`.

## Open and install

1. Open `MotionProbe.xcodeproj` in Xcode.
2. Select the `MotionProbe` target. In **Signing & Capabilities**, select your Apple development team. Use a unique bundle ID if Xcode asks for one.
3. Pair your Watch for development and enable Developer Mode if Xcode asks.
4. Select your real Watch as the run destination. Press Run.

The app targets watchOS 9 or later. This Mac has Xcode 15.4 and the watchOS 10.5
SDK. The native double-tap shortcut needs the watchOS 11 SDK (Xcode 16+) and is
compiled out on older toolchains.

## Local checks

Run the storage and counter checks:

```sh
sh scripts/test.sh
```

The tests cover the counter state machine (rounds, cycle order, totals,
snapshot restore) and both SQLite stores, using real temporary databases.

To compile the Watch target without signing or selecting a device:

```sh
xcodebuild -project MotionProbe.xcodeproj -target MotionProbe \
  -configuration Debug -sdk watchos CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$PWD/.build/WatchTarget/Products" \
  OBJROOT="$PWD/.build/WatchTarget/Intermediates" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/WatchTarget/ModuleCache" build
```

Verified locally: all 13 tests pass. The device target (arm64 + arm64_32) and
the simulator target both build with the watchOS 10.5 SDK. Vibration, audio
playback, and screen taps still need to be checked on a real Watch — the
simulator cannot prove them.
