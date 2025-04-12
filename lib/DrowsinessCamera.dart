import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:web_socket_channel/io.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';

class DrowsinessCamera extends StatefulWidget {
  const DrowsinessCamera({super.key});

  @override
  _DrowsinessCameraState createState() => _DrowsinessCameraState();
}

class _DrowsinessCameraState extends State<DrowsinessCamera> with WidgetsBindingObserver {
  late CameraController _cameraController;
  bool _isStreaming = false;
  IOWebSocketChannel? _channel;
  bool _isDrowsy = false;
  String _drowsinessMessage = "Eyes Open";
  FlutterTts flutterTts = FlutterTts();
  AudioPlayer audioPlayer = AudioPlayer();
  Uint8List? _latestFrame;
  bool _isCameraInitialized = false;
  bool _isProcessingFrame = false;
  bool _alertsEnabled = true;
  bool _showAlert = false;
  bool _alarmOn = false;
  bool _isCalibrating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _initializeTts();
    _checkVibrationCapability();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStreaming();
    _cameraController.dispose();
    flutterTts.stop();
    audioPlayer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_cameraController.value.isInitialized) {
        _initializeCamera();
      }
    }
  }

  Future<void> _checkVibrationCapability() async {
    bool? hasVibrator = await Vibration.hasVibrator();
    if (kDebugMode) {
      print("Device has vibrator: $hasVibrator");
    }
  }

  Future<void> _initializeTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setPitch(1.0);
    await flutterTts.setVolume(1.0);
    await flutterTts.setEngine("com.google.android.tts");
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }

      // Use the front camera for drowsiness detection
      final camera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });

      _startStreaming();
    } catch (e) {
      debugPrint("Error initializing camera: $e");
      if (mounted) {
        setState(() {
          _isCameraInitialized = false;
        });
      }
    }
  }

  void _startStreaming() {
    if (!_isCameraInitialized || _isStreaming) return;

    _channel = IOWebSocketChannel.connect('ws://192.168.164.81:8000/ws/DrowsinessCamera/');

    _channel?.sink.add(jsonEncode({"action": "start"}));

    _cameraController.startImageStream((CameraImage image) async {
      if (!_isStreaming || _isProcessingFrame) return;
      _isProcessingFrame = true;

      Uint8List? jpegBytes = await _convertToJpeg(image);
      if (jpegBytes != null) {
        if (mounted) {
          setState(() {
            _latestFrame = jpegBytes;
          });
        }
        _channel?.sink.add(jpegBytes);
      }

      _isProcessingFrame = false;
    });

    _channel?.stream.listen((data) {
      if (!mounted) return;

      if (kDebugMode) {
        print("Raw WebSocket Data: $data");
      }

      try {
        final jsonResponse = jsonDecode(data);
        
        if (jsonResponse.containsKey('drowsy')) {
          setState(() {
            _isDrowsy = jsonResponse['drowsy'];
            _drowsinessMessage = jsonResponse['message'];
            _alarmOn = jsonResponse['alarm_on'] ?? false;
            _isCalibrating = jsonResponse['message'] == "Calibrating...";
          });

          if (_isDrowsy && _alertsEnabled) {
            _triggerAlert();
          }
        }

        if (jsonResponse.containsKey('error')) {
          debugPrint("Server error: ${jsonResponse['error']}");
        }
      } catch (e) {
        debugPrint("Error parsing WebSocket data: $e");
      }
    }, onDone: () {
      if (mounted) {
        setState(() {
          _isStreaming = false;
        });
      }
    }, onError: (error) {
      debugPrint("WebSocket error: $error");
      if (mounted) {
        setState(() {
          _isStreaming = false;
        });
      }
    });

    setState(() {
      _isStreaming = true;
    });
  }

  Future<void> _triggerAlert() async {
    if (!mounted || !_alertsEnabled) return;

    setState(() {
      _showAlert = true;
    });

    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 500, 100, 500]);
    }

    try {
      await audioPlayer.play(AssetSource('alarm.mp3'));
    } catch (e) {
      if (kDebugMode) {
        print("Error playing alert sound: $e");
      }
    }

    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _showAlert = false;
        });
      }
    });
  }

  Future<void> _stopStreaming() async {
    if (!_isStreaming) return;

    try {
      await _cameraController.stopImageStream();
      _channel?.sink.add(jsonEncode({"action": "stop"}));
      _channel?.sink.close();

      if (mounted) {
        setState(() {
          _isStreaming = false;
        });
      }
    } catch (e) {
      debugPrint("Error stopping stream: $e");
    }
  }

  Future<Uint8List?> _convertToJpeg(CameraImage image) async {
    try {
      final int width = image.width;
      final int height = image.height;

      // Convert YUV to RGB
      img.Image imgFrame = img.Image(width: width, height: height);
      imgFrame = _convertYUV420ToRGB(image);

      // Resize the image to 640x640
      imgFrame = img.copyResize(imgFrame, width: 640, height: 640);

      return Uint8List.fromList(img.encodeJpg(imgFrame, quality: 80));
    } catch (e) {
      debugPrint("Error converting image: $e");
      return null;
    }
  }

  img.Image _convertYUV420ToRGB(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final img.Image imgFrame = img.Image(width: width, height: height);

    final Uint8List yPlane = image.planes[0].bytes;
    final Uint8List uPlane = image.planes[1].bytes;
    final Uint8List vPlane = image.planes[2].bytes;

    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel!;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int yIndex = y * image.planes[0].bytesPerRow + x;
        int uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

        int Y = yPlane[yIndex] & 0xFF;
        int U = uPlane[uvIndex] & 0xFF;
        int V = vPlane[uvIndex] & 0xFF;

        int R = (Y + 1.370705 * (V - 128)).clamp(0, 255).toInt();
        int G = (Y - 0.337633 * (U - 128) - 0.698001 * (V - 128)).clamp(0, 255).toInt();
        int B = (Y + 1.732446 * (U - 128)).clamp(0, 255).toInt();

        imgFrame.setPixelRgb(x, y, R, G, B);
      }
    }

    return imgFrame;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Drowsiness Detection"),
        actions: [
          IconButton(
            icon: Icon(_alertsEnabled ? Icons.notifications_active : Icons.notifications_off),
            onPressed: () {
              setState(() {
                _alertsEnabled = !_alertsEnabled;
                audioPlayer.stop();
              });
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _isCameraInitialized
              ? CameraPreview(_cameraController)
              : const Center(child: CircularProgressIndicator()),

          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isCalibrating)
                    const Text(
                      "Calibrating... Please look straight ahead",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                  Text(
                    _drowsinessMessage,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _isDrowsy ? Colors.red : Colors.green,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _isStreaming ? _stopStreaming : _startStreaming,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isStreaming ? Colors.red : Colors.green,
                      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                    ),
                    child: Text(
                      _isStreaming ? "Stop Detection" : "Start Detection",
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_showAlert)
            Container(
              color: Colors.red.withOpacity(0.3),
              width: double.infinity,
              height: double.infinity,
              child: const Center(
                child: Text(
                  "DROWSINESS ALERT!",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}