# MyTablet

Turn an Android tablet into a low-latency touch display for your Mac. It streams a pixel-exact virtual
display over USB and adds an iPadOS-inspired home screen on the tablet, while your Mac's own screen,
pointer and focus keep working normally.

[Türkçe](README.tr.md)

Built and tested on a Samsung Galaxy Tab A8 (SM-X207) with an M4 MacBook Air on macOS 27.2.
The resolution is currently fixed to that tablet's 1920×1200 panel.

## Features

- **Streaming:** H.264 through `adb` with credit-based flow control. About 20 ms from captured frame to
  decoded frame on the test hardware, 50–57 fps under continuous motion.
- **Sharp text:** the virtual display maps 1:1 to the panel, and still frames are re-encoded until they settle.
- **Touch:** tap, double tap, scroll with momentum, press-and-drag, long press for secondary click, two-finger
  scroll, pinch and rotate.
- **Two people's worth of input:** tablet taps and scrolls don't take the Mac's pointer or focus.
- **Liquid Glass:** Dock, Control Center, folders, keyboard and widgets use Apple's own `NSGlassEffectView`.
- **Home screen:** your real apps and Dock, spring animations, edit mode, drag to reorder, folders, and a
  layout that persists.
- **Windowing:** apps open as free windows over the wallpaper, like iPadOS 26. The Mac's menu bar is replaced by a
  status bar; pull down from the top left for the real one.
- **Widgets:** the macOS widgets on your desktop, mirrored live on real glass. Tapping one opens its app.
- **Control Center:** Wi-Fi, Bluetooth, dark mode, media keys, Mac volume, tablet brightness, screenshots.
- **Multitasking:** swipe home with the window following your finger, app switcher with live thumbnails, Dock
  with recent apps.
- **Keyboard:** follows your active macOS layout, plays key clicks on the tablet, opens when a text field is tapped.

## Build and run

Requires macOS 26+, Xcode, the Android SDK (`build-tools;35.0.0`, `platforms;android-34`, `platform-tools`)
and a tablet with USB debugging enabled.

    ./build.sh
    open build/MyTablet.app

Use `open`. Started from a shell, macOS attributes the permissions to your terminal and touch input won't work.
Grant **Screen Recording** and **Accessibility** on first launch. The receiver APK installs itself.

Signing picks your first `Apple Development` certificate, or set `MYTABLET_SIGN_IDENTITY`. Without one the app is
ad-hoc signed and macOS will ask for the permissions again after every build.

## Gestures

| Gesture | Result |
| --- | --- |
| Pull up from the bottom edge | Home (short pull: Dock, pull and hold: app switcher) |
| Slide along the bottom edge | Switch apps |
| Pull down from the top right | Control Center |
| Pull down from the top left, in an app | Real macOS menu bar for 6 seconds |
| Long press on the home screen | Edit mode |
| Drag an app onto another | Create a folder |
| Three fingers up / left / right | App switcher / switch apps |
| Press, hold, then drag | Drag and drop, text selection |

## How it works

macOS has one pointer and no public way to inject direct touches. Pointer events posted to a specific process are
dropped (measured on macOS 27), so each click and scroll moves the pointer to the finger and straight back
(about 10 ms for a click, 0.3 ms for a scroll event). Keyboard input goes directly to the tablet's focused app,
and window dragging uses Accessibility, so neither touches the pointer.

## Known limitations

- Pinches and drags hold the Mac's pointer for as long as they last, because macOS routes them by the live pointer
  position. They also make the target app active for that time.
- A tap briefly activates the tapped app (roughly 100 ms) before focus returns to the Mac's app.
- Android can briefly show its system bars when a swipe starts at the very edge of the screen.
- Widgets are mirrored images: you can't interact inside one, and a tap opens its app for known widgets only.
- No Split View or portrait orientation yet.
- Private APIs are used (`CGVirtualDisplay`, gesture event fields, `_AXUIElementGetWindow`, IOBluetooth power
  control), so a macOS update can break them.
- Baseline H.264 is used because the T618 decoder holds frames with other profiles.

## Project layout

- `mac/` Swift menu bar app: capture, encoding, gestures and the tablet shell
- `android/` receiver app, built with plain `javac` and `d8` (no Gradle)
- `tools/TouchLab.swift` diagnostic window that logs every input event it receives

## License

MIT. Not affiliated with Apple or Samsung.
