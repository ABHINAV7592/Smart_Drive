import 'dart:io';
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
// Add these packages for location and Firestore
import 'package:location/location.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class Pothole extends StatefulWidget {
  const Pothole({super.key});

  @override
  _PotholeState createState() => _PotholeState();
}

class _PotholeState extends State<Pothole> {
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

  // Location tracking
  Location location = Location();
  LocationData? _currentLocation;

  // Set of already detected potholes (to avoid duplicates)
  final Set<String> _detectedPotholeIds = {};

  // Timestamp of the last detection to prevent too many close records
  DateTime? _lastDetectionTime;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _initializeTts();
    _checkVibrationCapability();
    _initializeLocation();
  }

  Future<void> _initializeLocation() async {
    bool _serviceEnabled;
    PermissionStatus _permissionGranted;

    // Check if location service is enabled
    _serviceEnabled = await location.serviceEnabled();
    if (!_serviceEnabled) {
      _serviceEnabled = await location.requestService();
      if (!_serviceEnabled) {
        return;
      }
    }

    // Check if permission is granted
    _permissionGranted = await location.hasPermission();
    if (_permissionGranted == PermissionStatus.denied) {
      _permissionGranted = await location.requestPermission();
      if (_permissionGranted != PermissionStatus.granted) {
        return;
      }
    }

    // Listen for location changes
    location.onLocationChanged.listen((LocationData currentLocation) {
      setState(() {
        _currentLocation = currentLocation;
      });
    });

    // Start getting location updates
    location.enableBackgroundMode(enable: true);
    location.changeSettings(
      accuracy: LocationAccuracy.high,
      interval: 5000, // Update every 5 seconds
    );
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

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.low,
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
    }
  }

  void _startStreaming() {
    if (!_isCameraInitialized || _isStreaming) return;

    _channel = IOWebSocketChannel.connect('ws://192.168.164.81:8000/ws/pothole-detection/');

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

      final jsonResponse = jsonDecode(data);

      // FIX 1: Properly parse 'sensor_data' as int
      if (jsonResponse.containsKey('sensor_data')) {
        final sensorValue = jsonResponse['sensor_data'];
        int parsedSensorData;

        // Convert sensor_data to int, whether it's a string or already an int
        if (sensorValue is String) {
          parsedSensorData = int.tryParse(sensorValue) ?? 0;
        } else if (sensorValue is int) {
          parsedSensorData = sensorValue;
        } else {
          parsedSensorData = 0;
        }

        setState(() {
          _sensorData = parsedSensorData;
        });

        if (_sensorData == 0 && _alertsEnabled) {
          _triggerAlert();
          _savePotholeDetection("sensor_trigger");
        }
      }

      // Process detections from 'detections' key (based on the logs)
      if (jsonResponse.containsKey('detections')) {
        setState(() {
          _detectedObjects = jsonResponse['detections'];
        });

        if (_detectedObjects.isNotEmpty) {
          String detectedText = _detectedObjects.map((obj) => obj['label']).join(", ");
          if (kDebugMode) {
            print("Detected Objects: $detectedText");
          }
          _speak(detectedText);

          // Check if pothole is among the detected objects
          bool hasPothole = _detectedObjects.any((obj) =>
              obj['label'].toString().toLowerCase().contains('pothole'));

          if (hasPothole && _alertsEnabled) {
            _triggerAlert();
            _savePotholeDetection("vision_detection", detectedText);
          }
        }
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

  Future<void> _savePotholeDetection(String detectionType, [String? detectedLabels]) async {
    // Ensure we have location data
    if (_currentLocation == null) {
      if (kDebugMode) {
        print("Cannot save pothole detection: No location data available");
      }
      return;
    }

    // Avoid storing too many detections within a short time period (minimum 5 seconds between detections)
    final now = DateTime.now();
    if (_lastDetectionTime != null &&
        now.difference(_lastDetectionTime!).inSeconds < 5) {
      if (kDebugMode) {
        print("Skipping duplicate pothole detection (too close to previous detection)");
      }
      return;
    }

    _lastDetectionTime = now;

    try {
      // Get current user ID
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        if (kDebugMode) {
          print("Cannot save pothole detection: No user logged in");
        }
        return;
      }

      // Generate a unique ID for the detection
      final String detectionId = "${now.millisecondsSinceEpoch}_${_currentLocation!.latitude}_${_currentLocation!.longitude}";

      // Check if we already saved this pothole (based on location proximity)
      if (_detectedPotholeIds.contains(detectionId)) {
        if (kDebugMode) {
          print("Skipping already detected pothole");
        }
        return;
      }

      _detectedPotholeIds.add(detectionId);

      // Create the pothole data
      final Map<String, dynamic> potholeData = {
        'timestamp': Timestamp.now(),
        'location': GeoPoint(
          _currentLocation!.latitude ?? 0.0,
          _currentLocation!.longitude ?? 0.0,
        ),
        'accuracy': _currentLocation!.accuracy,
        'speed': _currentLocation!.speed,
        'heading': _currentLocation!.heading,
        'altitude': _currentLocation!.altitude,
        'detection_type': detectionType,
        'sensor_value': _sensorData,
        'detected_objects': detectedLabels ?? '',
      };

      // Store in Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('potholes')
          .doc(detectionId)
          .set(potholeData);

      if (kDebugMode) {
        print("Saved pothole detection to Firestore: $detectionId");
      }

    } catch (e) {
      if (kDebugMode) {
        print("Error saving pothole detection: $e");
      }
    }
  }

  Future<void> _triggerAlert() async {
    if (!mounted) return;

    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 500, 100, 500]);
    }

    try {
      await audioPlayer.play(AssetSource('alaram.mp3'));
    } catch (e) {
      if (kDebugMode) {
        print("Error playing alert sound: $e");
        // Add more details about the error
        print("Error details: ${e.toString()}");
      }
    }

    setState(() {
      _showAlert = true;
    });

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

  Future<void> _speak(String text) async {
    if (text.isNotEmpty) {
      if (kDebugMode) {
        print("Speaking: $text");
      }
      await flutterTts.awaitSpeakCompletion(true);
      await flutterTts.speak(text);
    }
  }

  @override
  void dispose() {
    _stopStreaming();
    _cameraController.dispose();
    flutterTts.stop();
    audioPlayer.dispose();
    super.dispose();
  }
late int _quarterTurns;
  void _adjustRotation() {
    final CameraController controller = _cameraController;
    final CameraDescription description = controller.description;

    final int sensorOrientation = description.sensorOrientation;
    final bool isFrontCamera = description.lensDirection == CameraLensDirection.front;

    // Get preview size to check aspect ratio
    final Size previewSize = controller.value.previewSize ?? Size(1, 1);
    final bool isPortrait = previewSize.height > previewSize.width;

    setState(() {
      if (Platform.isAndroid) {
        if (isFrontCamera) {
          _quarterTurns = (sensorOrientation == 90) ? 3 : (sensorOrientation == 270 ? 1 : 0);
        } else {
          _quarterTurns = sensorOrientation ~/ 90;
        }
      } else {
        // iOS handles rotation differently
        _quarterTurns = isPortrait ? 0 : 1;
      }
    });
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 812.h, width: 375.w,
                  child: _isCameraInitialized
                      ? RotatedBox(
                    quarterTurns: _cameraController.description.sensorOrientation ~/ 270,
                    child: CameraPreview(_cameraController),
                  )
                      : const Center(child: CircularProgressIndicator()),
                ),

                if (_detectedObjects.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      children: [
                        Text(
                          _detectedObjects.map((obj) => obj['label']).join(", "),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Sensor Data: $_sensorData",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: _sensorData == 0 ? Colors.red : Colors.green,
                          ),
                        ),
                        if (_currentLocation != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Text(
                              "Location: ${_currentLocation!.latitude?.toStringAsFixed(6)}, ${_currentLocation!.longitude?.toStringAsFixed(6)}",
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          if (_showAlert)
            Container(
              color: Colors.red.withOpacity(0.3),
              width: double.infinity,
              height: double.infinity,
              child: const Center(
                child: Text(
                  "ALERT!",
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
          // FIX 2: Add unique heroTag to each FloatingActionButton
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