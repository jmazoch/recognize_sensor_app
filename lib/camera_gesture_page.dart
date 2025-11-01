import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum GestureType { leftUp, rightUp, bothUp, wave }
enum SensorType { gps, accelerometer, wifiRssi, battery, none }

class CameraGesturePage extends StatefulWidget {
  const CameraGesturePage({super.key});

  @override
  State<CameraGesturePage> createState() => _CameraGesturePageState();
}

class _CameraGesturePageState extends State<CameraGesturePage> {
  CameraController? _controller;
  PoseDetector? _poseDetector;
  bool _processing = false;
  String _status = 'Inicializuji kameru…';
  Timer? _statusResetTimer;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;
  int _consecutiveImageErrors = 0;
  final ImageFormatGroup _formatGroup = ImageFormatGroup.yuv420;
  final CameraLensDirection _preferredLens = CameraLensDirection.front; // always front camera
  final _rightWristTracker = _WristWaveTracker();
  final _leftWristTracker = _WristWaveTracker();

  // Gesture mapping (configurable)
  final Map<GestureType, SensorType> _gestureMap = {
    GestureType.leftUp: SensorType.gps,
    GestureType.rightUp: SensorType.accelerometer,
    GestureType.wave: SensorType.wifiRssi,
    GestureType.bothUp: SensorType.battery,
  };

  // Gesture edge/cooldown tracking
  bool _prevLeftUp = false;
  bool _prevRightUp = false;
  DateTime _lastLeftFire = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRightFire = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastWaveFire = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBothFire = DateTime.fromMillisecondsSinceEpoch(0);
  final Duration _fireCooldown = const Duration(seconds: 3);

  // Sensors
  StreamSubscription<AccelerometerEvent>? _accelSub;
  AccelerometerEvent? _lastAccel;
  static const _signalChannel = MethodChannel('com.example.gesture_inject/signal');
  final Battery _battery = Battery();

  // Drawer + live sensor values
  bool _drawerOpen = false;
  Timer? _drawerTimer;
  int _drawerTick = 0;
  String _curGps = '—';
  String _curAccel = '—';
  String _curWifi = '—';
  String _curBattery = '—';

  // Bubbles overlay
  final List<_Bubble> _bubbles = [];
  int _bubbleSeq = 0;

  @override
  void initState() {
    super.initState();
    _init();
    _loadGestureMap();
    // Start accelerometer stream (lightweight)
    _accelSub = accelerometerEventStream().listen((e) {
      _lastAccel = e;
    });
    // Pre-request location permission to speed up first GPS read
    () async {
      await Permission.locationWhenInUse.request();
    }();
  }

  Future<void> _loadGestureMap() async {
    final prefs = await SharedPreferences.getInstance();
    for (final g in GestureType.values) {
      final key = _prefKeyForGesture(g);
      final v = prefs.getString(key);
      if (v != null) {
        final sensor = _sensorFromKey(v);
        if (sensor != null) _gestureMap[g] = sensor;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveGestureMap(GestureType g, SensorType s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyForGesture(g), _sensorKey(s));
  }

  Future<void> _init() async {
    final granted = await _ensurePermission();
    if (!granted) {
      setState(() => _status = 'Povolení kamery zamítnuto');
      return;
    }

    final cameras = await availableCameras();
    CameraDescription camera = cameras.firstWhere(
      (c) => c.lensDirection == _preferredLens,
      orElse: () => cameras.first,
    );

    CameraController controller = CameraController(
      camera,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: _formatGroup,
    );
    await controller.initialize();

    final options = PoseDetectorOptions(
      mode: PoseDetectionMode.stream,
      model: PoseDetectionModel.base,
    );
    _poseDetector = PoseDetector(options: options);

    setState(() {
      _controller = controller;
      _status = 'Zaměř kameru na ruce…';
    });

    try {
      await controller.startImageStream(_processImage);
    } catch (_) {
      // Retry with medium resolution
      try {
        await controller.stopImageStream();
      } catch (_) {}
      await controller.dispose();
      controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: _formatGroup,
      );
      await controller.initialize();
      if (mounted) setState(() => _controller = controller);
      await controller.startImageStream(_processImage);
    }
  }

  Future<bool> _ensurePermission() async {
    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    final req = await Permission.camera.request();
    return req.isGranted;
  }

  void _processImage(CameraImage image) async {
    if (_disposed) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed).inMilliseconds < 250) {
      return;
    }
    if (_processing) return;
    _processing = true;
    try {
      final inputImage = _toInputImage(image, _controller!);
      if (inputImage == null) {
        _consecutiveImageErrors++;
        if (_consecutiveImageErrors > 8) {
          _restartStream('Neplatný snímek – restart streamu');
        }
        return;
      }
      _consecutiveImageErrors = 0;
      _lastProcessed = now;
      final poses = await _poseDetector!.processImage(inputImage);
      if (!mounted) return;

      if (poses.isEmpty) {
        _setStatus('Nenalezen žádný postoj');
      } else {
        final pose = poses.first;
        final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
        final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
        final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
        final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];

        bool leftUp = false;
        bool rightUp = false;
        if (leftWrist != null && leftShoulder != null) {
          leftUp = leftWrist.y < leftShoulder.y;
        }
        if (rightWrist != null && rightShoulder != null) {
          rightUp = rightWrist.y < rightShoulder.y;
        }

        bool waved = false;
        if (rightWrist != null) {
          waved = _rightWristTracker.update(rightWrist.x, DateTime.now());
        }
        if (!waved && leftWrist != null) {
          waved = _leftWristTracker.update(leftWrist.x, DateTime.now());
        }

        if (waved) {
          _setStatus('Mávání 👋');
          _maybeFireWave();
        } else if (leftUp && rightUp) {
          _setStatus('Obě ruce nahoře ✋✋');
          _maybeFireBoth();
        } else if (leftUp) {
          _setStatus('Levá ruka nahoře ✋');
          _maybeFireLeft(leftUp);
        } else if (rightUp) {
          _setStatus('Pravá ruka nahoře ✋');
          _maybeFireRight(rightUp);
        } else {
          _setStatus('Žádné gesto');
        }

        // Update previous flags for edge-detection
        _prevLeftUp = leftUp;
        _prevRightUp = rightUp;
      }
    } catch (_) {
      _consecutiveImageErrors++;
      if (_consecutiveImageErrors > 8) {
        _restartStream('Chyba streamu – restart');
      }
    } finally {
      _processing = false;
    }
  }

  void _maybeFireBoth() {
    final now = DateTime.now();
    if (now.difference(_lastBothFire) > _fireCooldown) {
      _lastBothFire = now;
      _triggerGesture(GestureType.bothUp);
    }
  }

  void _maybeFireLeft(bool leftUp) {
    final now = DateTime.now();
    if (leftUp && !_prevLeftUp && now.difference(_lastLeftFire) > _fireCooldown) {
      _lastLeftFire = now;
      _triggerGesture(GestureType.leftUp);
    }
  }

  void _maybeFireRight(bool rightUp) {
    final now = DateTime.now();
    if (rightUp && !_prevRightUp && now.difference(_lastRightFire) > _fireCooldown) {
      _lastRightFire = now;
      _triggerGesture(GestureType.rightUp);
    }
  }

  void _maybeFireWave() {
    final now = DateTime.now();
    if (now.difference(_lastWaveFire) > _fireCooldown) {
      _lastWaveFire = now;
      _triggerGesture(GestureType.wave);
    }
  }

  void _triggerGesture(GestureType gesture) {
    final sensor = _gestureMap[gesture] ?? SensorType.none;
    switch (sensor) {
      case SensorType.gps:
        _readGpsAndBubble();
        break;
      case SensorType.accelerometer:
        _readAccelAndBubble();
        break;
      case SensorType.wifiRssi:
        _readSignalAndBubble();
        break;
      case SensorType.battery:
        _readBatteryAndBubble();
        break;
      case SensorType.none:
        // no-op
        break;
    }
  }

  Future<void> _readGpsAndBubble() async {
    try {
      // Ensure permission
      final perm = await Permission.locationWhenInUse.request();
      if (!perm.isGranted) {
        _addBubble('GPS', 'povoleni zamitnuto', Icons.location_off);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
      );
      final lat = pos.latitude.toStringAsFixed(5);
      final lon = pos.longitude.toStringAsFixed(5);
      _curGps = '$lat, $lon';
      _addBubble('GPS', '$lat, $lon', Icons.location_on);
    } catch (e) {
      _addBubble('GPS', 'chyba: ${e.runtimeType}', Icons.location_off);
    }
  }

  void _readAccelAndBubble() {
    final a = _lastAccel;
    if (a == null) {
      _addBubble('Akcelerometr', 'žádná data', Icons.sensors);
      return;
    }
    final mag = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    final v = 'x:${a.x.toStringAsFixed(2)} y:${a.y.toStringAsFixed(2)} z:${a.z.toStringAsFixed(2)} | |a|:${mag.toStringAsFixed(2)}';
    _curAccel = v;
    _addBubble('Akcelerometr', v, Icons.sensors);
  }

  Future<void> _readSignalAndBubble() async {
    try {
      final rssi = await _signalChannel.invokeMethod<int>('getWifiRssiDbm');
      if (rssi == null || rssi == 0 || rssi == -127) {
        _curWifi = 'N/A';
        _addBubble('Signál', 'N/A', Icons.network_wifi);
      } else {
        _curWifi = '$rssi dBm';
        _addBubble('Signál', '$rssi dBm', Icons.network_wifi);
      }
    } catch (e) {
      _addBubble('Signál', 'chyba', Icons.network_wifi);
    }
  }

  Future<void> _readBatteryAndBubble() async {
    try {
      final level = await _battery.batteryLevel; // 0-100
      _curBattery = '$level%';
      _addBubble('Baterie', '$level%', Icons.battery_full);
    } catch (_) {
      _addBubble('Baterie', 'N/A', Icons.battery_alert);
    }
  }

  void _addBubble(String title, String value, IconData icon) {
    if (!mounted) return;
    // Log to console for quick verification during runs (useful when device disconnects from debugger)
    // This helps confirm that gestures triggered and bubbles were created.
    // Keep lightweight to avoid impacting performance.
  debugPrint('Bubble -> $title: $value');
    final b = _Bubble(
      id: _bubbleSeq++,
      title: title,
      value: value,
      icon: icon,
      visible: false,
    );
    setState(() {
      _bubbles.insert(0, b); // newest on top
    });
    // Animate in
    Future.microtask(() {
      if (!mounted) return;
      setState(() => b.visible = true);
    });
    // Schedule hide after 5s
    Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => b.visible = false);
      // Remove after fade-out
      Timer(const Duration(milliseconds: 320), () {
        if (!mounted) return;
        setState(() => _bubbles.removeWhere((x) => x.id == b.id));
      });
    });
  }

  Future<void> _restartStream(String reason) async {
    if (!mounted || _controller == null) return;
    _setStatus(reason);
    try {
      await _controller!.stopImageStream();
    } catch (_) {}
    await _controller!.dispose();
    _controller = null;
    await _init();
  }

  void _setStatus(String s) {
    if (!mounted) return;
    setState(() => _status = s);
    _statusResetTimer?.cancel();
    _statusResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _status = 'Zaměř kameru na ruce…');
    });
  }

  InputImage? _toInputImage(CameraImage image, CameraController controller) {
    try {
      final conv = _yuv420ToNv21(image, half: true); // half-res for performance
      final bytes = conv.bytes;
      final int w = conv.width;
      final int h = conv.height;
      final Size imageSize = Size(w.toDouble(), h.toDouble());

      final camera = controller.description;
      final rotation = _inputImageRotationFromSensor(camera.sensorOrientation);

      final metadata = InputImageMetadata(
        size: imageSize,
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: w,
      );

      return InputImage.fromBytes(bytes: bytes, metadata: metadata);
    } catch (_) {
      return null;
    }
  }

  _Nv21 _yuv420ToNv21(CameraImage image, {bool half = false}) {
    final int width = image.width;
    final int height = image.height;

    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    final int yRowStride = yPlane.bytesPerRow;
    final int uRowStride = uPlane.bytesPerRow;
    final int vRowStride = vPlane.bytesPerRow;
    final int uPixelStride = uPlane.bytesPerPixel ?? 2;
    final int vPixelStride = vPlane.bytesPerPixel ?? 2;

    final Uint8List yBytes = yPlane.bytes;
    final Uint8List uBytes = uPlane.bytes;
    final Uint8List vBytes = vPlane.bytes;

    final int outW = half ? (width >> 1) : width;
    final int outH = half ? (height >> 1) : height;

    final int ySize = outW * outH;
    final int uvSize = outW * outH ~/ 2;
    final Uint8List nv21 = Uint8List(ySize + uvSize);

    // Y plane
    int dst = 0;
    if (!half) {
      for (int y = 0; y < height; y++) {
        final int src = y * yRowStride;
        nv21.setRange(dst, dst + width, yBytes.sublist(src, src + width));
        dst += width;
      }
    } else {
      for (int y = 0; y < outH; y++) {
        final int srcY = (y << 1);
        final int row = srcY * yRowStride;
        for (int x = 0; x < outW; x++) {
          final int srcX = (x << 1);
          nv21[dst++] = yBytes[row + srcX];
        }
      }
    }

    // UV (NV21: V then U)
    int uvDst = ySize;
    if (!half) {
      for (int y = 0; y < height; y += 2) {
        final int uRow = (y >> 1) * uRowStride;
        final int vRow = (y >> 1) * vRowStride;
        for (int x = 0; x < width; x += 2) {
          final int uIdx = uRow + (x >> 1) * uPixelStride;
          final int vIdx = vRow + (x >> 1) * vPixelStride;
          nv21[uvDst++] = vBytes[vIdx];
          nv21[uvDst++] = uBytes[uIdx];
        }
      }
    } else {
      final int outUvW = outW >> 1;
      final int outUvH = outH >> 1;
      for (int y = 0; y < outUvH; y++) {
        final int srcUvRow = (y << 1) * uRowStride;
        final int srcVvRow = (y << 1) * vRowStride;
        for (int x = 0; x < outUvW; x++) {
          final int srcUvCol = (x << 1) * uPixelStride;
          final int srcVvCol = (x << 1) * vPixelStride;
          nv21[uvDst++] = vBytes[srcVvRow + srcVvCol];
          nv21[uvDst++] = uBytes[srcUvRow + srcUvCol];
        }
      }
    }

    return _Nv21(bytes: nv21, width: outW, height: outH);
  }

  InputImageRotation _inputImageRotationFromSensor(int sensorOrientation) {
    switch (sensorOrientation) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  @override
  void dispose() {
    _statusResetTimer?.cancel();
    _disposed = true;
    _accelSub?.cancel();
    _controller?.dispose();
    _poseDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gesta z kamery (ML Kit)'),
      ),
      onDrawerChanged: _onDrawerChanged,
      drawer: _buildDrawer(),
      body: _controller == null || !_controller!.value.isInitialized
          ? Center(child: Text(_status))
          : Stack(
              fit: StackFit.expand,
              children: [
                Center(child: CameraPreview(_controller!)),
                // Top bubbles overlay
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: _bubbles
                              .map((b) => _BubbleWidget(
                                    bubble: b,
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 24,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      child: Text(
                        _status,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Drawer _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text('Senzory', style: Theme.of(context).textTheme.titleLarge),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  _sensorTile(icon: Icons.location_on, title: 'GPS', value: _curGps, onRefresh: _refreshGpsOnce),
                  _sensorTile(icon: Icons.sensors, title: 'Akcelerometr', value: _curAccel, onRefresh: _refreshAccelOnce),
                  _sensorTile(icon: Icons.network_wifi, title: 'Wi‑Fi RSSI', value: _curWifi, onRefresh: _refreshWifiOnce),
                  _sensorTile(icon: Icons.battery_full, title: 'Baterie', value: _curBattery, onRefresh: _refreshBatteryOnce),

                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    child: Text('Konfigurace gest', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  const SizedBox(height: 4),
                  _gestureConfigRow('Levá ruka nahoře', GestureType.leftUp),
                  _gestureConfigRow('Pravá ruka nahoře', GestureType.rightUp),
                  _gestureConfigRow('Obě ruce nahoře', GestureType.bothUp),
                  _gestureConfigRow('Mávání', GestureType.wave),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sensorTile({required IconData icon, required String title, required String value, required VoidCallback onRefresh}) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(value),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: onRefresh,
          tooltip: 'Aktualizovat',
        ),
      ),
    );
  }

  Widget _gestureConfigRow(String label, GestureType g) {
    final current = _gestureMap[g] ?? SensorType.none;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            const SizedBox(width: 12),
            DropdownButton<SensorType>(
              value: current,
              onChanged: (v) {
                if (v == null) return;
                setState(() => _gestureMap[g] = v);
                _saveGestureMap(g, v);
              },
              items: SensorType.values.map((s) => DropdownMenuItem(
                    value: s,
                    child: Row(
                      children: [Icon(_sensorIcon(s), size: 18), const SizedBox(width: 8), Text(_sensorLabel(s))],
                    ),
                  ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _refreshWifiOnce() async {
    try {
      final rssi = await _signalChannel.invokeMethod<int>('getWifiRssiDbm');
      setState(() => _curWifi = (rssi == null || rssi == 0 || rssi == -127) ? 'N/A' : '$rssi dBm');
    } catch (_) {
      setState(() => _curWifi = 'chyba');
    }
  }

  void _refreshBatteryOnce() async {
    try {
      final lvl = await _battery.batteryLevel;
      setState(() => _curBattery = '$lvl%');
    } catch (_) {
      setState(() => _curBattery = 'N/A');
    }
  }

  void _refreshGpsOnce() async {
    try {
      final perm = await Permission.locationWhenInUse.request();
      if (!perm.isGranted) {
        setState(() => _curGps = 'povoleni zamitnuto');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.low));
      setState(() => _curGps = '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}');
    } catch (e) {
      setState(() => _curGps = 'chyba');
    }
  }

  void _refreshAccelOnce() {
    final a = _lastAccel;
    if (a == null) {
      setState(() => _curAccel = 'žádná data');
      return;
    }
    final mag = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    setState(() => _curAccel = 'x:${a.x.toStringAsFixed(2)} y:${a.y.toStringAsFixed(2)} z:${a.z.toStringAsFixed(2)} | |a|:${mag.toStringAsFixed(2)}');
  }

  void _onDrawerChanged(bool opened) {
    _drawerOpen = opened;
    _drawerTimer?.cancel();
    if (opened) {
      // Immediate refresh, then periodic lightweight updates
      _refreshWifiOnce();
      _refreshBatteryOnce();
      _refreshGpsOnce();
      _refreshAccelOnce();
      _drawerTick = 0;
      _drawerTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
        if (!_drawerOpen) return;
        _drawerTick++;
        _refreshWifiOnce();
        _refreshAccelOnce();
        if (_drawerTick % 3 == 0) {
          _refreshGpsOnce();
          _refreshBatteryOnce();
        }
      });
    }
  }

  String _prefKeyForGesture(GestureType g) => 'map_${g.name}';
  String _sensorKey(SensorType s) => s.name;
  SensorType? _sensorFromKey(String k) {
    return SensorType.values.firstWhere((e) => e.name == k, orElse: () => SensorType.none);
  }

  String _sensorLabel(SensorType s) {
    switch (s) {
      case SensorType.gps:
        return 'GPS';
      case SensorType.accelerometer:
        return 'Akcelerometr';
      case SensorType.wifiRssi:
        return 'Wi‑Fi RSSI';
      case SensorType.battery:
        return 'Baterie';
      case SensorType.none:
        return 'Žádný';
    }
  }

  IconData _sensorIcon(SensorType s) {
    switch (s) {
      case SensorType.gps:
        return Icons.location_on;
      case SensorType.accelerometer:
        return Icons.sensors;
      case SensorType.wifiRssi:
        return Icons.network_wifi;
      case SensorType.battery:
        return Icons.battery_full;
      case SensorType.none:
        return Icons.block;
    }
  }
}

class _Nv21 {
  _Nv21({required this.bytes, required this.width, required this.height});
  final Uint8List bytes;
  final int width;
  final int height;
}

class _WristWaveTracker {
  final List<_Sample> _samples = [];
  final Duration window = const Duration(seconds: 2);
  final double minAmplitude = 40; // pixels in image coordinates
  final int minDirectionChanges = 2; // left<->right flips

  bool update(double x, DateTime now) {
    _samples.add(_Sample(now, x));
    final cutoff = now.subtract(window);
    while (_samples.isNotEmpty && _samples.first.t.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
    if (_samples.length < 5) return false;

    double minX = _samples.first.x;
    double maxX = _samples.first.x;
    for (final s in _samples) {
      if (s.x < minX) minX = s.x;
      if (s.x > maxX) maxX = s.x;
    }
    if ((maxX - minX) < minAmplitude) return false;

    int changes = 0;
    double? prevDx;
    for (int i = 1; i < _samples.length; i++) {
      final dx = _samples[i].x - _samples[i - 1].x;
      if (dx == 0) continue;
      if (prevDx != null && (dx > 0) != (prevDx > 0)) {
        changes++;
      }
      prevDx = dx;
    }
    return changes >= minDirectionChanges;
  }
}

class _Sample {
  _Sample(this.t, this.x);
  final DateTime t;
  final double x;
}

class _Bubble {
  _Bubble({required this.id, required this.title, required this.value, required this.icon, required this.visible});
  final int id;
  final String title;
  final String value;
  final IconData icon;
  bool visible;
}

class _BubbleWidget extends StatelessWidget {
  const _BubbleWidget({required this.bubble});
  final _Bubble bubble;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      key: ValueKey(bubble.id),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      offset: bubble.visible ? Offset.zero : const Offset(0, -0.2),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        opacity: bubble.visible ? 1 : 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(bubble.icon, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '${bubble.title}: ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Flexible(
                    child: Text(
                      bubble.value,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
