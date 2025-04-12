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
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

class Traficmode extends StatefulWidget {
  const Traficmode({super.key});

  @override
  _TraficmodeState createState() => _TraficmodeState();
}

class _TraficmodeState extends State<Traficmode> with WidgetsBindingObserver {
  late CameraController _cameraController;
  bool _isStreaming = false;
  IOWebSocketChannel? _channel;
  List<dynamic> _detectedObjects = [];
  FlutterTts flutterTts = FlutterTts();
  AudioPlayer audioPlayer = AudioPlayer();
  Uint8List? _latestFrame;
  bool _isCameraInitialized = false;
  bool _isProcessingFrame = false;
  bool _alertsEnabled = true;
  int _sensorData = 0;
  bool _showAlert = false;
  DeviceOrientation _currentOrientation = DeviceOrientation.portraitUp;
  String _lastDetectionMessage = "";
  String _lastSensorMessage = "";

  late FirebaseFirestore _firestore;
  String? _userId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeFirebase();
    _initializeCamera();
    _initializeTts();
    _checkVibrationCapability();
    _getCurrentUserId();
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
    if (!_isCameraInitialized) return;
    
    if (state == AppLifecycleState.inactive) {
      _cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (_cameraController.value.isInitialized) {
        _updateCameraOrientation();
      }
    }
  }

  Future<void> _initializeFirebase() async {
    await Firebase.initializeApp();
    _firestore = FirebaseFirestore.instance;
  }

  Future<void> _getCurrentUserId() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      setState(() {
        _userId = user.uid;
      });
    }
  }

  Future<void> _checkVibrationCapability() async {
    await Vibration.hasVibrator();
  }

  Future<void> _initializeTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setPitch(1.0);
    await flutterTts.setVolume(1.0);
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('No cameras available');
      
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController.initialize();
      await _updateCameraOrientation();
      
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });

      _startStreaming();
    } catch (e) {
      debugPrint("Error initializing camera: $e");
    }
  }

  Future<void> _updateCameraOrientation() async {
    if (!_isCameraInitialized) return;

    final orientation = MediaQuery.of(context).orientation;
    _currentOrientation = orientation == Orientation.portrait 
        ? DeviceOrientation.portraitUp 
        : DeviceOrientation.landscapeRight;

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);

    await _cameraController.lockCaptureOrientation(_currentOrientation);
  }

  void _startStreaming() {
    if (!_isCameraInitialized || _isStreaming) return;

    _channel = IOWebSocketChannel.connect('ws://192.168.164.81:8000/ws/traffic-detection/');

    _cameraController.startImageStream((CameraImage image) async {
      if (!_isStreaming || _isProcessingFrame) return;
      _isProcessingFrame = true;

      Uint8List? jpegBytes = await _convertToJpeg(image);
      if (jpegBytes != null) {
        _channel?.sink.add(jpegBytes);
      }

      _isProcessingFrame = false;
    });

    _channel?.stream.listen((data) async {
      if (!mounted) return;

      final jsonResponse = jsonDecode(data);

      if (jsonResponse.containsKey('sensor_data')) {
        final sensorValue = jsonResponse['sensor_data'];
        int parsedSensorData = sensorValue is String ? int.tryParse(sensorValue) ?? 0 : sensorValue is int ? sensorValue : 0;

        setState(() {
          _sensorData = parsedSensorData;
          _lastSensorMessage = "Obstacle Sensor: ${_sensorData == 0 ? "DETECTED" : "Clear"}";
        });

        if (_sensorData == 0 && _alertsEnabled) {
          _triggerAlert();
        }
      }

      if (jsonResponse.containsKey('detections')) {
        setState(() {
          _detectedObjects = jsonResponse['detections'];
          if (_detectedObjects.isNotEmpty) {
            _lastDetectionMessage = "Detected: ${_detectedObjects.map((obj) => obj['label'].toString().replaceAll('_', ' ')).join(", ")}";
          } else {
            _lastDetectionMessage = "No traffic signs detected";
          }
        });

        if (_detectedObjects.isNotEmpty) {
          String detectedText = _detectedObjects.map((obj) => obj['label']).join(", ");
          _speak(detectedText);

          bool isTrafficSignOrSignal = _detectedObjects.any((obj) {
            String label = obj['label'].toString().toLowerCase();
            return label.contains('sign') ||
                label.contains('signal') ||
                label.contains('light') ||
                label.contains('traffic');
          });

          if (isTrafficSignOrSignal && _userId != null) {
            await _storeTrafficLocation(detectedText);
          }
        }
      }
    }, onDone: () {
      if (mounted) setState(() => _isStreaming = false);
    }, onError: (error) {
      debugPrint("WebSocket error: $error");
      if (mounted) setState(() => _isStreaming = false);
    });

    setState(() {
      _isStreaming = true;
    });
  }

  Future<void> _storeTrafficLocation(String detectedText) async {
    try {
      if (_userId == null) return;

      Position position = await _getCurrentLocation();

      await _firestore
          .collection('users')
          .doc(_userId)
          .collection('traffic')
          .add({
        'label': detectedText,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("Error storing traffic location: $e");
    }
  }

  Future<Position> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permissions are denied.');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permissions are permanently denied.');
    }

    return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  Future<void> _triggerAlert() async {
    if (!mounted) return;

    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 500, 100, 500]);
    }

    try {
      await audioPlayer.play(AssetSource('alarm.mp3'));
    } catch (e) {
      debugPrint("Error playing alert sound: $e");
    }

    setState(() {
      _showAlert = true;
    });

    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showAlert = false);
    });
  }

  Future<void> _stopStreaming() async {
    if (!_isStreaming) return;

    try {
      await _cameraController.stopImageStream();
      _channel?.sink.close();
      if (mounted) setState(() => _isStreaming = false);
    } catch (e) {
      debugPrint("Error stopping stream: $e");
    }
  }

  Future<Uint8List?> _convertToJpeg(CameraImage image) async {
    try {
      img.Image imgFrame = _convertYUV420ToRGB(image);
      imgFrame = img.copyResize(imgFrame, width: 640, height: 640);
      return Uint8List.fromList(img.encodeJpg(imgFrame, quality: 80));
    } catch (e) {
      debugPrint("Error converting image: $e");
      return null;
    }
  }

  img.Image _convertYUV420ToRGB(CameraImage image) {
    final img.Image imgFrame = img.Image(width: image.width, height: image.height);

    final Uint8List yPlane = image.planes[0].bytes;
    final Uint8List uPlane = image.planes[1].bytes;
    final Uint8List vPlane = image.planes[2].bytes;

    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel!;

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
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

  Future<void> _speak(String text) async {
    if (text.isNotEmpty) {
      String cleanText = text.replaceAll('_', ' ').replaceAll('-', ' ');
      await flutterTts.awaitSpeakCompletion(true);
      await flutterTts.speak(cleanText);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Camera Preview
          SizedBox(
            width: MediaQuery.of(context).size.width,
            height: MediaQuery.of(context).size.height,
            child: _isCameraInitialized
                ? CameraPreview(_cameraController)
                : const Center(child: CircularProgressIndicator()),
          ),

          // Detection and Sensor Information Panel
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _lastDetectionMessage,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _lastSensorMessage,
                    style: TextStyle(
                      color: _sensorData == 0 ? Colors.red : Colors.green,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Alert Overlay
          if (_showAlert)
            Container(
              color: Colors.red.withOpacity(0.3),
              width: double.infinity,
              height: double.infinity,
              child: const Center(
                child: Text(
                  "OBSTACLE DETECTED!",
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
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: "alertToggleButton",
            onPressed: () {
              setState(() {
                _alertsEnabled = !_alertsEnabled;
                audioPlayer.stop();
              });
            },
            backgroundColor: _alertsEnabled ? Colors.green : Colors.red,
            mini: true,
            child: Icon(_alertsEnabled ? Icons.notifications_active : Icons.notifications_off),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: "streamToggleButton",
            onPressed: () {
              if (_isStreaming) {
                _stopStreaming();
              } else {
                _startStreaming();
              }
            },
            child: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
          ),
        ],
      ),
    );
  }
}