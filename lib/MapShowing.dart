import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class Mapshowing extends StatefulWidget {
  const Mapshowing({super.key});

  @override
  State<Mapshowing> createState() => _MapshowingState();
}

class _MapshowingState extends State<Mapshowing> {
  late GoogleMapController mapController;
  LatLng _currentPosition = const LatLng(10.8505, 76.2711); // Default Kerala
  Set<Marker> _markers = {};
  String? _userId; // To store current user ID

  @override
  void initState() {
    super.initState();
    _getCurrentUserId();
    _requestLocationPermission();
  }

  /// Get current user ID from Firebase Auth
  Future<void> _getCurrentUserId() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      setState(() {
        _userId = user.uid;
      });
      _fetchPotholeLocations(user.uid); // Fetch potholes for the user
      _fetchTrafficSignals(user.uid); // Fetch traffic signals for the user
    }
  }

  /// Request location permission
  Future<void> _requestLocationPermission() async {
    var status = await Permission.location.request();
    if (status.isGranted) {
      _getCurrentLocation();
    }
  }

  /// Get current user location
  Future<void> _getCurrentLocation() async {
    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    setState(() {
      _currentPosition = LatLng(position.latitude, position.longitude);
    });
    // Move camera to current location after fetching
    mapController.animateCamera(CameraUpdate.newLatLng(_currentPosition));
  }

  /// Fetch pothole locations from Firestore for the current user
  Future<void> _fetchPotholeLocations(String userId) async {
    FirebaseFirestore.instance
        .collection("users")
        .doc(userId)
        .collection("potholes")
        .get()
        .then((snapshot) {
      Set<Marker> markers = {};
      for (var doc in snapshot.docs) {
        List<String> pathParts = doc.id.split("_");
        if (pathParts.length == 3) {
          double lat = double.parse(pathParts[1]);
          double lng = double.parse(pathParts[2]);

          markers.add(
            Marker(
              markerId: MarkerId(doc.id),
              position: LatLng(lat, lng),
              infoWindow: const InfoWindow(title: "Pothole Location"),
              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed), // Changed to blue for potholes
            ),
          );
        }
      }
      setState(() {
        _markers.addAll(markers);
      });
    }).catchError((error) {
      debugPrint("Error fetching potholes: $error");
    });
  }
  /// Fetch traffic signals from the user's 'traffic' subcollection
  Future<void> _fetchTrafficSignals(String userId) async {
    FirebaseFirestore.instance
        .collection("users")
        .doc(userId)
        .collection("traffic")
        .get()
        .then((snapshot) {
      Set<Marker> markers = {};
      for (var doc in snapshot.docs) {
        var data = doc.data();
        double? lat = data['latitude']?.toDouble();
        double? lng = data['longitude']?.toDouble();
        String label = data['label'] ?? "Traffic Signal";

        if (lat != null && lng != null) {
          markers.add(
            Marker(
              markerId: MarkerId(doc.id),
              position: LatLng(lat, lng),
              infoWindow: InfoWindow(title: label),
              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue), // Changed to red for traffic signals
            ),
          );
        }
      }
      setState(() {
        _markers.addAll(markers);
      });
    }).catchError((error) {
      debugPrint("Error fetching traffic signals: $error");
    });
  }
  void _onMapCreated(GoogleMapController controller) {
    mapController = controller;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Google Map with Potholes & Traffic Signals")),
      body: _userId == null
          ? const Center(child: CircularProgressIndicator()) // Show loader until user ID is fetched
          : GoogleMap(
        onMapCreated: _onMapCreated,
        initialCameraPosition: CameraPosition(
          target: _currentPosition,
          zoom: 14.0,
        ),
        markers: _markers,
        mapType: MapType.normal,
        myLocationEnabled: true,
        myLocationButtonEnabled: true,
      ),
    );
  }

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }
}