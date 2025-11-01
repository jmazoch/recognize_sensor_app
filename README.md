# GestureDetector Demo (Flutter)

This app showcases Flutter's `GestureDetector` handling of tap, double-tap, long-press, and pan (drag) gestures inside a square area. It updates counters and status text in real‑time.

## What it does

- Tracks: Tap, Double tap, Long press, Pan position
- Visual feedback: color changes on different gestures
- Testable: a widget test verifies tap behavior

## Run it

Prereqs: Flutter 3.35+ installed and `flutter doctor` mostly green.

Run on Android (emulator or device):

```powershell
# From the project root
flutter devices
flutter run -d <deviceId>
```

Run on Windows desktop (optional):

```powershell
flutter run -d windows
```

Run on Edge (web, optional):

```powershell
flutter run -d edge
```

## Tests and analysis

```powershell
flutter analyze
flutter test
```

## Android SDK path with spaces (Windows)

If `flutter doctor` warns that your Android SDK path contains spaces (e.g. `C:\Users\Your Name\AppData\Local\Android\sdk`), move the SDK to a path without spaces and point Android Studio to it:

1. Close Android Studio and emulators.
2. Move the folder to e.g. `C:\Android\sdk`.
3. In Android Studio: File → Settings → Appearance & Behavior → System Settings → Android SDK → set the new path.
4. Set the environment variable for Flutter/Dart tools (PowerShell profile or system env):

	```powershell
	[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT','C:\\Android\\sdk','User')
	```

5. Re-run `flutter doctor`.

## Useful links

- GestureDetector API: https://api.flutter.dev/flutter/widgets/GestureDetector-class.html
- Flutter docs: https://docs.flutter.dev
