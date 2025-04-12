import 'package:driveguard/Pothole%20Mode.dart';
import 'package:driveguard/Trafic%20Mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:driveguard/MapShowing.dart';  // Map Showing Page
import 'package:driveguard/DrowsinessCamera.dart';  // Drowsiness Detection Page
import 'DrowsinessCamera.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Colors.deepPurple],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24.w),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _animation,
                  child: Icon(
                    Icons.traffic,
                    size: 80.w,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 20.h),
                Text(
                  "Choose Mode",
                  style: GoogleFonts.poppins(
                    fontSize: 28.sp,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 30.h),
                _buildModeButton(
                  "Traffic Mode",
                  Colors.deepPurpleAccent,
                  Icons.directions_car,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const Traficmode())),
                ),
                SizedBox(height: 20.h),
                _buildModeButton(
                  "Pothole Mode",
                  Colors.redAccent,
                  Icons.warning_amber_rounded,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const Pothole())),
                ),
                SizedBox(height: 20.h),
                _buildModeButton(
                  "Map",
                  Colors.greenAccent,
                  Icons.location_on,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const Mapshowing())),
                ),
                SizedBox(height: 20.h),
                _buildModeButton(
                  "Drowsiness Detection",
                  Colors.orangeAccent,
                  Icons.visibility,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DrowsinessCamera())), // ✅ Fixed
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeButton(String title, Color color, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(vertical: 15.h),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12.r),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.5),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 28.w),
            SizedBox(width: 10.w),
            Text(
              title,
              style: GoogleFonts.poppins(
                fontSize: 20.sp,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
