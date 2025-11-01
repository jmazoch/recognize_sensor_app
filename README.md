# Recognize Sensor App (Flutter + ML Kit)

Camera-driven hand gesture recognition that pops animated sensor “bubbles”, plus a hamburger menu to see live sensor values and configure which gesture triggers which sensor.

Works best on a real Android device. Emulators often feed low-quality/virtual camera frames that degrade pose detection accuracy.

## What’s inside

- ML-based gesture detection (front camera):
	- Left hand up, Right hand up, Both hands up, and Waving
	- Uses Google ML Kit Pose Detection (base model) in stream mode
- Sensor bubbles (animated, 5s TTL):
	- Left up → GPS position
	- Right up → Accelerometer (x,y,z and |a|)
	- Waving → Wi‑Fi RSSI (dBm)
	- Both up → Battery level (%)
- Hamburger menu (Drawer):
	- Live readouts for GPS, Accelerometer, Wi‑Fi RSSI, Battery (manual refresh + periodic while open)
	- Configurator: map each gesture to any sensor (defaults above). Persisted via shared_preferences.
- Performance: throttled processing (~4 FPS), half-resolution NV21 conversion, front camera only, 3s gesture cooldowns.

## How it works (high level)

- Camera stream → YUV420 → custom NV21 bytes (half-res) → ML Kit Pose Detection
- Pose landmarks are analyzed:
	- “Hand up” when wrist.y < shoulder.y
	- “Waving” when wrist X oscillates with enough amplitude and direction flips (2s window)
- On gesture, a mapped sensor read is performed and shown as a top overlay bubble with smooth in/out animations and auto-dismiss after ~5s.
- A status banner at the bottom shows the latest recognized gesture.

## Code map

- Entry: `lib/main.dart` → home is `CameraGesturePage`
- Core: `lib/camera_gesture_page.dart`
	- Camera init: CameraX via `camera` plugin. Front camera, YUV420, low/medium resolution fallback.
	- Pose detection: `google_mlkit_pose_detection`
		- Options set here (see PoseDetectorOptions):
			- `mode: PoseDetectionMode.stream`
			- `model: PoseDetectionModel.base`
		- Tuning parameters live here as well:
			- Wrist wave tracker: 2s window, minAmplitude=40 px, minDirectionChanges=2
			- Processing throttle: ~250 ms between frames
			- Gesture cooldowns: 3s per gesture
			- Image conversion: `_yuv420ToNv21(image, half: true)`
	- Gesture→Sensor mapping & config:
		- Enums: `GestureType { leftUp, rightUp, bothUp, wave }`, `SensorType { gps, accelerometer, wifiRssi, battery, none }`
		- Defaults are set in `_gestureMap` in `CameraGesturePage` state
		- Persisted with `shared_preferences` using keys like `map_leftUp`, etc.
	- Drawer (hamburger menu): `_buildDrawer()` shows live sensor tiles and mapping dropdowns; `onDrawerChanged` starts/stops lightweight periodic refresh.
	- Sensor collectors:
		- GPS: `geolocator` (low accuracy); permissions via `permission_handler`
		- Accelerometer: `sensors_plus` (stream cached)
		- Wi‑Fi RSSI (Android): platform channel to native (see below)
		- Battery: `battery_plus`
	- Bubbles overlay: `_addBubble(title, value, icon)` with `AnimatedSlide` + `AnimatedOpacity`
- Android native bridge: `android/app/src/main/kotlin/.../MainActivity.kt`
	- Method channel: `com.example.gesture_inject/signal` → `getWifiRssiDbm` using `WifiManager`
- Android Manifest: `android/app/src/main/AndroidManifest.xml`
	- Permissions: `CAMERA`, `ACCESS_FINE_LOCATION`, `ACCESS_WIFI_STATE`

## Run it (Windows PowerShell)

Prereqs: Flutter 3.35+, Android SDK, an Android device connected with USB debugging enabled. On first run you’ll be prompted for camera and (when needed) location permission.

```powershell
# In the project root
flutter pub get
flutter analyze
flutter devices
flutter run -d <deviceId>
```

Notes:
- Use a real device for camera-based pose detection (emulator cameras are unreliable/slow for this use case).
- Wi‑Fi RSSI may require location services enabled on some Android versions/vendors.

## Configuration defaults and where to tweak

- Gesture→Sensor defaults: `_gestureMap` in `CameraGesturePage` (and change via Drawer UI). Persisted in `shared_preferences`.
- Pose model selection and mode: `PoseDetectorOptions` in `CameraGesturePage` (`base` model, `stream` mode)
- Waving heuristic: `_WristWaveTracker` (window, minAmplitude, direction changes)
- Performance: `_lastProcessed` throttle (250ms), NV21 half‑res conversion, 3s cooldowns per gesture

## Testing and analysis

```powershell
flutter analyze
# Widget tests are limited because camera plugins don’t run in widget test env
```

## What was done (summary)

- Replaced touch `GestureDetector` demo with ML Kit pose-based camera gestures
- Auto-start front camera on launch; added robust image pipeline and throttling
- Implemented gesture classification (left/right/both up, waving)
- Mapped gestures to sensor reads; showed results as animated bubbles (5s TTL)
- Added platform channel for Wi‑Fi RSSI dBm (Android)
- Added Drawer with live sensor tiles and a configurator to change gesture→sensor mapping (persisted)
- Cleaned up lints; kept analyzer green

## Troubleshooting

- If you see “Unable to acquire a buffer item…” warnings: it’s typically due to camera buffer pressure; throttling mitigates it. Real devices work better.
- If the app disconnects during `flutter run`, just relaunch; logs still show bubble triggers (`debugPrint` in `_addBubble`).

## License

For demo purposes only. Review and adapt to your use case.
