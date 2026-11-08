# MyTablet

Turn an Android tablet into a low-latency touch display for your Mac. It streams a pixel-exact virtual
display over USB and adds an iPadOS 27-inspired home screen on the tablet, while your Mac's own screen,
pointer and focus keep working normally.

[Türkçe](README.tr.md)

Built and tested on a Samsung Galaxy Tab A8 (SM-X207) with an M4 MacBook Air on macOS 27.2.
The resolution is currently fixed to that tablet's 1920×1200 panel.

## Features

- **Streaming:** H.264 through `adb` with credit-based flow control. About 20 ms from captured frame to
  decoded frame on the test hardware, 50–57 fps under continuous motion.
- **Wireless:** after one USB connection the tablet works over Wi-Fi, with AES-256-GCM encryption, mutual authentication
  and bitrate that adapts to the network. Unplugging switches to Wi-Fi; plugging back in returns to USB.
- **Sharp text:** the virtual display maps 1:1 to the panel, and still frames are re-encoded until they settle.
- **Touch:** tap, double tap, scroll with momentum, press-and-drag, long press for secondary click, two-finger
  scroll, pinch and rotate.
- **Use both at once:** tablet input is delivered straight to the window, so the Mac's pointer, active app and typing are
  not affected.
- **Settings app:** glass style per surface, icon and Dock size, labels, recent apps, scroll speed, long press, key sounds,
  screen area and connection, all applied live.
- **Liquid Glass:** Dock, Control Center, folders, keyboard and widgets use Apple's own `NSGlassEffectView` with its clear,
  edge-refracting internal variant (the same look as the system Dock), placed over a backdrop in their own window, because
  the effect only refracts content in the same window.
- **Home screen:** your real apps and Dock, spring animations, edit mode, drag to reorder, folders, and a
  layout that persists.
- **Windowing:** apps open as free windows over the wallpaper, like iPadOS. The Mac's menu bar is replaced by a
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

## Wireless use

Connect by USB once to pair. After that, open MyTablet on the tablet while both devices are on the same network; the Mac
finds it by itself. The Mac must stay on with the app running and its lid open. The menu bar item can force USB or Wi-Fi.
Expect roughly 45–55 fps at 55–90 ms on a weak 2.4 GHz link; 5 GHz gives the tablet much more room.

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

Touches are delivered to the window under the finger with SkyLight's `SLEventPostToPid`, using window-local coordinates
(required on macOS 27), and the window is made key without activating its app. The Mac's pointer and frontmost app stay
untouched. The field numbers and focus record follow [Cua Driver](https://github.com/trycua/cua) (MIT) and yabai. System UI
with no window of its own (the menu bar) still uses the shared pointer for an instant.

## Known limitations

- macOS tracks one open menu at a time, so a menu open on the tablet holds the Mac's keyboard focus until it closes.
- Dragging files or list rows still needs the real pointer, because AppKit tracks drag sessions with it.
- To stop Android's bars appearing over the stream, the receiver turns the `user_setup_complete` secure setting off while
  streaming and back on when streaming stops. If the tablet loses power mid-session and acts oddly, run
  `adb shell settings put secure user_setup_complete 1`.
- Widgets are mirrored images: you can't interact inside one, and a tap opens its app for known widgets only.
- No Split View or portrait orientation yet.
- Private APIs are used (`CGVirtualDisplay`, the glass view's `_variant`, `SLEventPostToPid` and related SkyLight calls, gesture event fields, `_AXUIElementGetWindow`, IOBluetooth power
  control), so a macOS update can break them.
- Baseline H.264 is used because the T618 decoder holds frames with other profiles.

## Project layout

- `mac/` Swift menu bar app: capture, encoding, gestures and the tablet shell
- `android/` receiver app, built with plain `javac` and `d8` (no Gradle)
- `tools/TouchLab.swift` diagnostic window that logs every input event it receives

## License

MIT. Not affiliated with Apple or Samsung.
