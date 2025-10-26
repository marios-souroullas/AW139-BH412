import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:aw139_cruise/export/cruise_report_export.dart'; // <-- add this line
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, debugPrint;
import 'package:flutter/services.dart'
    show rootBundle, Clipboard, ClipboardData;
import 'package:aw139_cruise/export/route_export_kml.dart';
import 'dart:convert' show utf8, jsonDecode, JsonEncoder;
import 'dart:typed_data' show Uint8List;
import 'package:file_selector/file_selector.dart';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:async';

// Windy API key (keep private). Replace YOUR_REAL_WINDY_KEY with your key.
const String kWindyApiKey = 'a4wqVgw3RBBPbjA0PjMtmD1I9PK0ndAX';

enum WindProvider { openMeteo, windy }

// AI optimization objective
enum OptimizationObjective { minFuel, minTime, hybrid }

// SAR pattern types
enum SarPatternType { parallel, expandingSquare, sector }

// + Per‑waypoint SAR parameters (units in NM and degrees)
class SarParams {
  double headingDeg; // first heading or start bearing
  // Parallel
  double legNm;
  double spacingNm;
  int legs;
  // Expanding square
  double stepNm;
  int layers;
  // Sector
  double radiusNm;
  int sectors;

  SarParams({
    this.headingDeg = double.nan, // NaN means "use route"
    this.legNm = 2.0,
    this.spacingNm = 0.5,
    this.legs = 6,
    this.stepNm = 0.5,
    this.layers = 4,
    this.radiusNm = 2.0,
    this.sectors = 6,
  });

  static SarParams defaultsFor(SarPatternType t) {
    switch (t) {
      case SarPatternType.parallel:
        return SarParams(
          headingDeg: double.nan,
          legNm: 2.0,
          spacingNm: 0.5,
          legs: 6,
        );
      case SarPatternType.expandingSquare:
        return SarParams(headingDeg: double.nan, stepNm: 0.5, layers: 4);
      case SarPatternType.sector:
        return SarParams(headingDeg: double.nan, radiusNm: 2.0, sectors: 6);
    }
  }
}

// OpenWeatherMap API key (replace with your OpenWeatherMap key).
// Do NOT commit this value to a public repo.
const String kOpenWeatherApiKey = 'f7084ce97f81d6e4e49b7f393aa69da4';

const Color kPanelColor = Color(0xFF2A2A2A);
double _parseNumber(String s) {
  final t = s.trim().replaceAll(',', '.');
  return double.tryParse(t) ?? 0.0;
}

// ...existing imports and _parseNumber above...

double _niceInterval(double maxY, {int targetTicks = 10}) {
  final safe = (maxY.isFinite && maxY > 0) ? maxY : 100.0;
  final raw = safe / targetTicks;
  final mags = [1, 2, 5, 10];
  double mag = 1;
  while (mag < raw) {
    mag *= 10;
  }
  // pick the smallest “nice” step >= raw
  for (final m in mags) {
    final step = (mag / 10) * m;
    if (step >= raw) return step;
  }
  return mag; // fallback
}

Widget buildInputField(
  String label,
  TextEditingController controller, {
  bool readOnly = false,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6.0),
    child: TextField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: TextInputType.number,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: readOnly
            ? const Icon(Icons.lock, size: 16, color: Colors.orangeAccent)
            : null,
      ),
    ),
  );
}

// make swapAnimationCurvebuildMiniBarChart a TOP-LEVEL function (not inside any other function/class)
Widget swapAnimationCurvebuildMiniBarChart({
  required String title,
  required double value,
  required Color color,
  required double maxY,
  required String unit,
  double height = 320,
}) {
  final safeMaxY = (maxY.isFinite && maxY > 0) ? maxY : 100.0;
  final displayValue = (value.isFinite ? value : 0)
      .clamp(0, safeMaxY)
      .roundToDouble();
  final interval = _niceInterval(safeMaxY, targetTicks: 10);

  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: height,
        width: double.infinity,
        child: IgnorePointer(
          ignoring: kIsWeb,
          child: RepaintBoundary(
            child: BarChart(
              BarChartData(
                minY: 0,
                maxY: safeMaxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: interval,
                ),
                titlesData: FlTitlesData(
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: interval,
                      reservedSize: 44,
                      getTitlesWidget: (v, m) => Text(
                        v.toInt().toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 38,
                      getTitlesWidget: (v, m) => SizedBox(
                        height: 34,
                        child: Text(
                          title,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: color,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                barTouchData: BarTouchData(enabled: false),
                barGroups: [
                  BarChartGroupData(
                    x: 0,
                    barRods: [
                      BarChartRodData(
                        toY: displayValue,
                        color: color,
                        width: 16,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ],
                  ),
                ],
              ),
              duration: Duration.zero,
              curve: Curves.linear,
            ),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        '${displayValue.toStringAsFixed(0)} $unit',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    ],
  );
}

double _degToRad(double d) => d * math.pi / 180.0;
double _radToDeg(double r) => r * 180.0 / math.pi;

// Initial bearing from A(lat1,lon1) to B(lat2,lon2) in degrees (0–360)
double _initialBearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = _degToRad(lat1);
  final phi2 = _degToRad(lat2);
  final deltaLambda = _degToRad(lon2 - lon1);
  final y = math.sin(deltaLambda) * math.cos(phi2);
  final x =
      math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);
  final theta = math.atan2(y, x);
  return ((_radToDeg(theta) + 360.0) % 360.0);
}

// Tailwind component along a course (positive tailwind, negative headwind)
double _tailwindKts(
  double windSpeedMps,
  double windDirDegFrom,
  double trackDeg,
) {
  final wsKts = windSpeedMps * 1.94384449;
  final windTo = (windDirDegFrom + 180.0) % 360.0;
  final diff = ((windTo - trackDeg + 540.0) % 360.0) - 180.0; // [-180,180]
  return wsKts * math.cos(_degToRad(diff));
}

// Parse latitude/longitude in decimal or DMS with hemisphere (N/S/E/W).
// Examples accepted:
//   "37.7749N", "122.4194W", "-33.86", "151.21", "37 46 30 N", "122°25'10\" W"
double _parseCoord(String raw, {required bool isLat}) {
  var s = raw.trim().toUpperCase().replaceAll(',', '.');

  // Detect hemisphere (N/S/E/W)
  int sign = 1;
  if (s.contains('S')) sign = -1;
  if (s.contains('W')) sign = -1;

  // Remove hemisphere letters and symbols
  s = s.replaceAll(RegExp('[NSEW°′’\'″"]'), ' ').trim();

  // Extract numeric parts (deg, min, sec)
  final parts = RegExp(
    r'[-+]?\d+(\.\d+)?',
  ).allMatches(s).map((m) => double.tryParse(m.group(0) ?? '') ?? 0.0).toList();
  // ...existing code..

  double value;
  if (parts.isEmpty) return double.nan;
  if (parts.length == 1) {
    value = parts[0]; // decimal degrees
  } else if (parts.length == 2) {
    value = parts[0] + parts[1] / 60.0; // deg + min
  } else {
    value = parts[0] + parts[1] / 60.0 + parts[2] / 3600.0; // deg + min + sec
  }

  // If the original string had an explicit leading sign, honor it
  if (RegExp(r'^\s*-').hasMatch(raw)) sign = -1;

  value *= sign;

  // Clamp to valid ranges
  final maxAbs = isLat ? 90.0 : 180.0;
  if (value.abs() > maxAbs) return double.nan;

  return value;
}

// Optional: great-circle distance in NM (if you decide to auto-fill Mission Distance)
double _gcDistanceNm(double lat1, double lon1, double lat2, double lon2) {
  const rNm = 3440.065;
  final dLat = _degToRad(lat2 - lat1);
  final dLon = _degToRad(lon2 - lon1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_degToRad(lat1)) *
          math.cos(_degToRad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return rNm * c;
}

String _formatDms(double value, {required bool isLat}) {
  if (!value.isFinite) return '--';
  final hemi = isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W');
  double absVal = value.abs();
  int deg = absVal.floor();
  double minFloat = (absVal - deg) * 60.0;
  int min = minFloat.floor();
  double sec = (minFloat - min) * 60.0;

  if (sec >= 59.95) {
    sec = 0;
    min += 1;
    if (min == 60) {
      min = 0;
      deg += 1;
    }
  }

  final degStr = isLat
      ? deg.toString().padLeft(2, '0')
      : deg.toString().padLeft(3, '0');
  final minStr = min.toString().padLeft(2, '0');
  final secFixed = sec.toStringAsFixed(1);
  final secStr = sec < 10 ? '0$secFixed' : secFixed;
  return '$hemi $degStr° $minStr\' $secStr"';
}

// helper: format a wind component as "Tailwind X kt" or "Headwind X kt"
// ignore: unused_element
String _formatTailOrHead(double w) =>
    '${w >= 0 ? 'Tailwind' : 'Headwind'} ${w.abs().toStringAsFixed(0)} kt';
// unit helpers
double kgToLbs(double kg) => kg * 2.2046226218;
double lbsToKg(double lbs) => lbs / 2.2046226218;
String formatWeight(double kg, bool isBell412, {int frac = 0}) => isBell412
    ? '${kgToLbs(kg).toStringAsFixed(frac)} lbs'
    : '${kg.toStringAsFixed(frac)} kg';

// Safe conversion helper for dynamic/json numbers
double _numToDouble(dynamic v) {
  if (v == null) return 0.0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0.0;
}

// PNR helpers
double _computePnrNm({
  required double fuelOnboardKg,
  required double reserveKg,
  required double hoistMinutes,
  required double burnKgPerHr,
  required double gsOutKts,
  required double gsBackKts,
}) {
  const hoistBurnKgPerHr = 450.0;
  final hoistKg = (hoistMinutes / 60.0) * hoistBurnKgPerHr;
  final usableKg = (fuelOnboardKg - reserveKg - hoistKg).clamp(
    0.0,
    fuelOnboardKg,
  );
  if (burnKgPerHr <= 0) return 0.0;
  final usableHr = usableKg / burnKgPerHr;
  final denom = (1.0 / gsOutKts) + (1.0 / gsBackKts);
  if (denom <= 0) return 0.0;
  return usableHr / denom;
}

LatLng? _pointAlongRoute(List<LatLng> pts, double targetNm) {
  if (pts.length < 2 || targetNm <= 0) return pts.isNotEmpty ? pts.first : null;
  double acc = 0.0;
  for (int i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final seg = _gcDistanceNm(a.latitude, a.longitude, b.latitude, b.longitude);
    if (acc + seg >= targetNm) {
      final remain = targetNm - acc;
      final t = (seg > 0 ? remain / seg : 0).clamp(0.0, 1.0);
      final lat = a.latitude + (b.latitude - a.latitude) * t;
      final lon = a.longitude + (b.longitude - a.longitude) * t;
      return LatLng(lat, lon);
    }
    acc += seg;
  }
  return pts.last;
}

// ...existing code...
// convert pressure (hPa) -> approximate altitude (ft) using ISA barometric formula
double pressureHpaToFeet(
  double pHpa, {
  double p0 = 1013.25,
  double t0 = 288.15,
}) {
  // t0: standard sea-level temperature (K), p0: sea-level pressure (hPa)
  const double L = 0.0065; // K/m
  const double R = 287.05; // J/(kg·K)
  const double g = 9.80665; // m/s^2
  final double exponent = (R * L) / g; // ~0.190263
  // clamp pressure to reasonable positive range
  final p = pHpa.clamp(1.0, double.infinity);
  final ratio = math.pow(p / p0, exponent).toDouble();
  final meters = (t0 / L) * (1.0 - ratio);
  return meters * 3.28084; // meters -> feet
}

// ...existing code...
void showCruiseResultsDialog({
  required BuildContext context,
  required double endurance,
  required double estimatedRange,
  required double missionDistance,
  required double missionDuration,
  required double fuelRemaining,
  required bool lowFuelWarning,
  required double requiredTorque,
  required double cruiseSpeed,
  required double altitude,
  required double temperature,
  required double adjustedFuelBurn,
  required double hoistMinutesRounded,
  required double hoistFuel,
  required double fuelRequired,
  List<Map<String, double>>? fuelTimelineKg,
  double? aiAltitudeFt,
  double? aiTailwindKts,
  double? aiTailwindOutKts,
  double? aiTailwindBackKts,
  double? aiSuggestedIas,
  double? aiSuggestedAltitudeOutFt,
  double? aiSuggestedAltitudeBackFt,
  double? originLat,
  double? originLon,
  double? destLat,
  double? destLon,
  bool roundTrip = true,
  bool isBell412 = false,
  double? sarDistanceNm, // one-way SAR distance included in missionDistance
  double? sarTimeHours, // total added time (out + back if roundTrip)
  double? sarFuelKg, // added fuel for SAR (kg)
}) {
  // Units shown to the user
  final weightUnit = isBell412 ? 'lbs' : 'kg';
  // Convert for display (internal calcs are in kg)
  final displayHoistFuel = isBell412 ? kgToLbs(hoistFuel) : hoistFuel;
  final displayAdjustedBurn = isBell412
      ? kgToLbs(adjustedFuelBurn)
      : adjustedFuelBurn;
  final displayFuelRem = isBell412 ? kgToLbs(fuelRemaining) : fuelRemaining;
  final displayFuelReq = isBell412 ? kgToLbs(fuelRequired) : fuelRequired;
  final fuelRemRoundedDisplay = displayFuelRem.round();
  final displaySarFuel = (sarFuelKg != null)
      ? (isBell412 ? kgToLbs(sarFuelKg) : sarFuelKg)
      : null;

  // Color thresholds in display units (lbs for 412, kg for 139)
  final redThresh = isBell412 ? kgToLbs(184) : 184.0;
  final orangeThresh = isBell412 ? kgToLbs(456) : 456.0;

  showDialog(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cruise Results',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),

                // ...inside showCruiseResultsDialog Column children...
                Text('Endurance: ${endurance.toStringAsFixed(2)} hrs'),
                Text(
                  'Estimated Range: ${estimatedRange.toStringAsFixed(0)} NM',
                ),
                Text(
                  'Mission Distance (one-way): ${missionDistance.toStringAsFixed(0)} NM',
                ),
                if (roundTrip)
                  Text(
                    'Round Trip Distance: ${(missionDistance * 2).toStringAsFixed(0)} NM',
                  )
                else
                  const Text('Return leg not included (single trip)'),
                if ((sarDistanceNm ?? 0) > 0) ...[
                  const SizedBox(height: 6),
                  const Divider(thickness: 1, color: Colors.grey),
                  const SizedBox(height: 6),
                  const Text(
                    'SAR Breakdown',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'SAR distance (one-way): ${sarDistanceNm!.toStringAsFixed(0)} NM',
                  ),
                  Text(
                    'SAR time added: ${(sarTimeHours ?? 0).toStringAsFixed(2)} hrs',
                  ),
                  if (displaySarFuel != null)
                    Text(
                      'SAR fuel: ${displaySarFuel.toStringAsFixed(0)} ${isBell412 ? 'lbs' : 'kg'}',
                    ),
                  // Optional: show base distance (one-way without SAR)
                  Text(
                    'Base route (one-way, no SAR): ${(missionDistance - sarDistanceNm).clamp(0, double.infinity).toStringAsFixed(0)} NM',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
                Text(
                  'Mission Duration: ${missionDuration.toStringAsFixed(2)} hrs',
                ),
                Text(
                  'Hoist Time (rounded): ${hoistMinutesRounded.toStringAsFixed(0)} min',
                ),
                Text(
                  'Hoist Fuel: ${displayHoistFuel.toStringAsFixed(0)} $weightUnit',
                ),

                Text(
                  'Fuel Remaining: $fuelRemRoundedDisplay $weightUnit',
                  style: TextStyle(
                    color: displayFuelRem <= redThresh
                        ? Colors.red
                        : (displayFuelRem <= orangeThresh
                              ? Colors.orange
                              : Colors.white),
                    fontWeight: displayFuelRem <= orangeThresh
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),

                Text(
                  'Fuel Required: ${displayFuelReq.toStringAsFixed(0)} $weightUnit',
                ),
                Text('Required Torque: ${requiredTorque.ceil()} %'),
                Text('Cruise Speed: ${cruiseSpeed.toStringAsFixed(0)} knots'),
                Text('Altitude: ${altitude.toStringAsFixed(0)} ft'),
                Text('Temperature: ${temperature.toStringAsFixed(0)} °C'),

                if (fuelTimelineKg != null && fuelTimelineKg.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(thickness: 1, color: Colors.grey),
                  const SizedBox(height: 8),
                  const Text(
                    'Fuel Remaining every 20 min',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: fuelTimelineKg.map((p) {
                      final mins = p['minute'] ?? 0.0;
                      final remKg = p['remainingKg'] ?? 0.0;
                      final remDisp = isBell412 ? kgToLbs(remKg) : remKg;
                      return Chip(
                        backgroundColor: kPanelColor,
                        label: Text(
                          'T+${mins.toStringAsFixed(0)}: ${remDisp.round()} $weightUnit',
                        ),
                      );
                    }).toList(),
                  ),
                ],

                // Coordinates (shown if provided)
                if (originLat != null && originLon != null)
                  Text(
                    'Origin: ${_formatDms(originLat, isLat: true)}  '
                    '${_formatDms(originLon, isLat: false)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                if (destLat != null && destLon != null)
                  Text(
                    'Destination: ${_formatDms(destLat, isLat: true)}  '
                    '${_formatDms(destLon, isLat: false)}',
                    style: const TextStyle(color: Colors.white70),
                  ),

                // ...existing code...
                // AI suggestions (caller already guards non-null)
                if (aiAltitudeFt != null && aiTailwindKts != null)
                  Text(
                    'AI: Suggested altitude ~${aiAltitudeFt.toStringAsFixed(0)} ft (${_formatTailOrHead(aiTailwindKts)})',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                if (aiSuggestedAltitudeOutFt != null &&
                    aiTailwindOutKts != null)
                  Text(
                    'AI (Out): ~${aiSuggestedAltitudeOutFt.toStringAsFixed(0)} ft (${_formatTailOrHead(aiTailwindOutKts)})',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                if (aiSuggestedAltitudeBackFt != null &&
                    aiTailwindBackKts != null)
                  Text(
                    'AI (Back): ~${aiSuggestedAltitudeBackFt.toStringAsFixed(0)} ft (${_formatTailOrHead(aiTailwindBackKts)})',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                if (aiSuggestedIas != null)
                  Text(
                    'AI: Suggested cruise ≈ ${aiSuggestedIas.toStringAsFixed(0)} kts',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                // ...existing code...
                // ...existing code...
                if (lowFuelWarning) ...[
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '⚠️ Warning: Fuel after mission is below safe threshold!',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],

                // ...existing code...
                const SizedBox(height: 12),
                const Divider(thickness: 1, color: Colors.grey),
                const SizedBox(height: 8),

                // ...existing code...
                // Charts row (horizontal scroll if narrow)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Torque
                      SizedBox(
                        width: 150,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title: 'Torque %',
                            value: requiredTorque,
                            color: Colors.orange,
                            maxY: 120,
                            unit: '%',
                            height: 240,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Fuel Burn
                      SizedBox(
                        width: 150,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title:
                                'Fuel Burn\n(${isBell412 ? 'lbs/hr' : 'kg/hr'})',
                            value: displayAdjustedBurn,
                            color: Colors.yellow,
                            maxY:
                                (displayAdjustedBurn <= 0
                                        ? 100
                                        : (displayAdjustedBurn / 100).ceil() *
                                              100)
                                    .toDouble(),
                            unit: isBell412 ? 'lbs/hr' : 'kg/hr',
                            height: 240,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Fuel Remaining
                      SizedBox(
                        width: 150,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title:
                                'Fuel\nRemaining (${isBell412 ? 'lbs' : 'kg'})',
                            // Use display units and dynamic maxY to avoid clamping at 500
                            value: displayFuelRem,
                            color: displayFuelRem <= redThresh
                                ? Colors.red
                                : (displayFuelRem <= orangeThresh
                                      ? Colors.orange
                                      : Colors.green),
                            maxY:
                                (displayFuelRem <= 0
                                        ? 100
                                        : (displayFuelRem / 100).ceil() * 100)
                                    .toDouble(),
                            unit: isBell412 ? 'lbs' : 'kg',
                            height: 240,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // ...existing code...
                // ...existing code...
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// Bell-412 loaded table: altitude -> oat -> ias -> burn (kg/hr)
final Map<int, Map<int, Map<int, double>>> bh412Tables = {};

final Map<int, Map<int, int>> fuelBurnTable0ft = {
  0: {50: 345, 60: 392, 80: 460, 90: 493, 100: 525},
  20: {50: 365, 60: 398, 80: 465, 90: 491, 100: 535},
  40: {50: 370, 60: 405, 80: 475, 90: 507, 100: 531},
};
final Map<int, Map<int, int>> fuelBurnTable2000ft = {
  0: {50: 345, 60: 380, 80: 445, 90: 480, 100: 515},
  20: {50: 350, 60: 375, 80: 420, 90: 485, 100: 520},
  40: {50: 345, 60: 391, 80: 460, 90: 493, 100: 527},
};
final Map<int, Map<int, int>> fuelBurnTable4000ft = {
  -40: {50: 320, 60: 355, 80: 422, 90: 458, 100: 487},
  -20: {50: 328, 60: 360, 80: 408, 90: 455, 100: 500},
  0: {50: 322, 60: 359, 80: 435, 90: 468, 100: 503},
  20: {50: 338, 60: 372, 80: 430, 90: 475, 100: 510},
  40: {50: 342, 60: 380, 80: 445, 90: 479, 100: 515},
};
final Map<int, Map<int, int>> fuelBurnTable6000ft = {
  -40: {50: 310, 60: 345, 80: 410, 90: 448, 100: 485},
  -20: {50: 315, 60: 350, 80: 415, 90: 455, 100: 488},
  0: {50: 321, 60: 355, 80: 421, 90: 455, 100: 485},
  20: {50: 327, 60: 360, 80: 407, 90: 460, 100: 508},
  40: {50: 327, 60: 360, 80: 407, 90: 460, 100: 508},
};
final Map<int, Map<int, Map<int, int>>> fuelBurnTables = {
  0: fuelBurnTable0ft,
  2000: fuelBurnTable2000ft,
  4000: fuelBurnTable4000ft,
  6000: fuelBurnTable6000ft,
};
final Map<int, Map<int, Map<int, double>>> speedTables = {
  0: {
    0: {50: 107, 60: 131, 70: 145, 80: 154, 90: 162, 100: 167},
    20: {50: 108, 60: 128, 70: 142, 80: 151, 90: 158, 100: 167},
    40: {50: 106, 60: 126, 70: 137, 80: 147, 90: 155, 100: 167},
  },
  2000: {
    0: {50: 108, 60: 129, 70: 145, 80: 152, 90: 158, 100: 167},
    20: {50: 107, 60: 126, 70: 135, 80: 147, 90: 155, 100: 162},
    40: {50: 103, 60: 122, 70: 134, 80: 143, 90: 152, 100: 167},
  },
  4000: {
    -40: {50: 103, 60: 125, 70: 137, 80: 143, 90: 163, 100: 167},
    -20: {50: 108, 60: 129, 70: 142, 80: 151, 90: 158, 100: 165},
    0: {50: 107, 60: 127, 70: 138, 80: 147, 90: 155, 100: 162},
    20: {50: 108, 60: 122, 70: 134, 80: 143, 90: 152, 100: 158},
    40: {50: 100, 60: 108, 70: 129, 80: 138}, // incomplete row
  },
  6000: {
    -40: {50: 108, 60: 129, 70: 142, 80: 152, 90: 160, 100: 167},
    -20: {50: 107, 60: 126, 70: 137, 80: 147, 90: 155, 100: 162},
    0: {50: 103, 60: 122, 70: 134, 80: 146, 90: 150}, // incomplete row
    20: {50: 99, 60: 117, 70: 128, 80: 137, 90: 145}, // incomplete row
    40: {50: 93, 60: 112, 70: 123}, // incomplete row
  },
};

double interpolateFuelBurn(double torque, int altitude, int oat) {
  final altKeys = fuelBurnTables.keys.toList()..sort();
  int closestAlt = altKeys.reduce(
    (a, b) => (a - altitude).abs() < (b - altitude).abs() ? a : b,
  );

  final tempTable = fuelBurnTables[closestAlt]!;
  final tempKeys = tempTable.keys.toList()..sort();
  int closestTemp = tempKeys.reduce(
    (a, b) => (a - oat).abs() < (b - oat).abs() ? a : b,
  );

  final table = tempTable[closestTemp]!;
  final tqKeys = table.keys.toList()..sort();
  for (int i = 0; i < tqKeys.length - 1; i++) {
    final lower = tqKeys[i].toDouble();
    final upper = tqKeys[i + 1].toDouble();
    if (torque >= lower && torque <= upper) {
      final ratio = (torque - lower) / (upper - lower);
      return table[lower.toInt()]! +
          ratio * (table[upper.toInt()]! - table[lower.toInt()]!);
    }
  }
  return table[tqKeys.last]!.toDouble();
}

double getTorqueForIAS(int altitude, int oat, double ias) {
  final altKeys = speedTables.keys.toList()..sort();
  int closestAlt = altKeys.reduce(
    (a, b) => (a - altitude).abs() < (b - altitude).abs() ? a : b,
  );

  final tempTable = speedTables[closestAlt]!;
  final tempKeys = tempTable.keys.toList()..sort();
  int closestTemp = tempKeys.reduce(
    (a, b) => (a - oat).abs() < (b - oat).abs() ? a : b,
  );

  final table = tempTable[closestTemp]!;
  final tqKeys = table.keys.toList()..sort();

  for (int i = 0; i < tqKeys.length - 1; i++) {
    double lowerIAS = table[tqKeys[i]]!;
    double upperIAS = table[tqKeys[i + 1]]!;
    if (ias >= lowerIAS && ias <= upperIAS) {
      double ratio = (ias - lowerIAS) / (upperIAS - lowerIAS);
      return tqKeys[i] + ratio * (tqKeys[i + 1] - tqKeys[i]);
    }
  }
  if (ias < table[tqKeys.first]!) {
    return tqKeys.first.toDouble();
  }

  if (ias > table[tqKeys.last]!) {
    return tqKeys.last.toDouble();
  }

  int closestTorque = tqKeys.reduce(
    (a, b) => (table[a]! - ias).abs() < (table[b]! - ias).abs() ? a : b,
  );
  return closestTorque.toDouble();
}

double getCorrectionFactor({
  required bool searchlight,
  required bool radar,
  required bool flir,
  required bool hoist,
}) {
  double factor = 0.0;
  if (searchlight) factor += 0.3;
  if (radar) factor += 0.3;
  if (flir) factor += 0.3;
  if (hoist) factor += 0.2;
  return factor;
}

List<Map<String, double>> _buildFuelTimeline({
  required double initialFuelKg,
  required double cruiseBurnKgPerHr,
  required double outHours,
  required double backHours,
  required double hoistHours,
  int intervalMin = 20,
}) {
  const hoistBurnKgPerHr = 450.0;
  final outMin = (outHours * 60.0).clamp(0.0, double.infinity);
  final backMin = (backHours * 60.0).clamp(0.0, double.infinity);
  final hoistMin = (hoistHours * 60.0).clamp(0.0, double.infinity);
  final totalMin = outMin + backMin + hoistMin;

  double consumedAt(double tMin) {
    double t = tMin.clamp(0.0, totalMin);
    double c = 0.0;
    final m1 = math.min(t, outMin);
    c += (m1 / 60.0) * cruiseBurnKgPerHr;
    t -= m1;
    if (t <= 0) return c;

    final m2 = math.min(t, backMin);
    c += (m2 / 60.0) * cruiseBurnKgPerHr;
    t -= m2;
    if (t <= 0) return c;

    final m3 = math.min(t, hoistMin);
    c += (m3 / 60.0) * hoistBurnKgPerHr;
    return c;
  }

  final points = <Map<String, double>>[];
  for (int m = 0; m <= totalMin; m += intervalMin) {
    final rem = (initialFuelKg - consumedAt(m.toDouble())).clamp(
      0.0,
      initialFuelKg,
    );
    points.add({'minute': m.toDouble(), 'remainingKg': rem});
  }
  if (points.isEmpty || points.last['minute'] != totalMin) {
    final rem = (initialFuelKg - consumedAt(totalMin)).clamp(
      0.0,
      initialFuelKg,
    );
    points.add({'minute': totalMin, 'remainingKg': rem});
  }
  return points;
}

Map<String, double> calculateCruisePerformance({
  required double distance,
  required double cruiseSpeed,
  required int altitude,
  required int temperature,
  required bool roundTrip,
  required double cf,
}) {
  double baseTorqueReference = getTorqueForIAS(
    altitude,
    temperature,
    cruiseSpeed,
  );
  const double maxCf = 1.1; // sum of all equipment correction factors
  double requiredTorque = baseTorqueReference * (1 + (cf / maxCf) * 0.11);

  double fuelBurnPerHour = interpolateFuelBurn(
    requiredTorque,
    altitude,
    temperature,
  );
  double effectiveDistance = roundTrip ? distance * 2 : distance;
  double cruiseTime = effectiveDistance / cruiseSpeed;
  double totalFuel = fuelBurnPerHour * cruiseTime;
  return {
    'recommendedTorque': requiredTorque,
    'fuelBurnPerHour': fuelBurnPerHour,
    'totalFuel': totalFuel,
  };
}

// Toggle chip builder
Widget buildToggle(
  String label,
  bool value,
  Function(bool) onChanged,
  IconData icon,
) {
  return FilterChip(
    avatar: Icon(icon, color: Colors.greenAccent),
    label: Text(label),
    selected: value,
    onSelected: onChanged,
    selectedColor: Colors.orange,
    backgroundColor: Colors.grey[800],
    labelStyle: TextStyle(color: Colors.greenAccent),
  );
}

Widget buildEquipmentToggles(
  BuildContext context,
  bool searchlight,
  bool radar,
  bool flir,
  bool hoist,
  bool selectAll,
  Function(bool) onSearchlight,
  Function(bool) onRadar,
  Function(bool) onFlir,
  Function(bool) onHoist,
  Function(bool) onSelectAll,
) {
  // ...existing code...
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CheckboxListTile(
        value: selectAll,
        onChanged: (v) => onSelectAll(v ?? false),
        title: const Text('Select All Optional Equipment'),
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        contentPadding: EdgeInsets.zero,
      ),
      Wrap(
        spacing: 8,
        children: [
          buildToggle(
            'Searchlight',
            searchlight,
            onSearchlight,
            Icons.lightbulb,
          ),
          buildToggle('Radar', radar, onRadar, Icons.radar),
          buildToggle('FLIR', flir, onFlir, Icons.camera_alt),
          buildToggle('Hoist', hoist, onHoist, Icons.arrow_upward),
        ],
      ),
    ],
  );
}

class NavFix {
  final String id;
  final String name;
  final double lat;
  final double lon;
  const NavFix({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
  });
}

const List<NavFix> kNavFixes = [
  NavFix(id: 'LCA', name: 'Larnaca VOR/DME (LCA)', lat: 34.8723, lon: 33.6243),
  NavFix(id: 'PHA', name: 'Paphos VOR/DME (PHA)', lat: 34.7117, lon: 32.5058),
];

class WaypointItem {
  final String id; // 'hospital' | 'wpt1' | 'wpt2'
  final String title;
  final TextEditingController lat;
  final TextEditingController lon;
  bool enabled;
  WaypointItem({
    required this.id,
    required this.title,
    required this.lat,
    required this.lon,
    this.enabled = false,
  });
}

// Single, clean widget + state (remove any other duplicate class blocks above)
class CruiseInputScreen extends StatefulWidget {
  const CruiseInputScreen({super.key});
  @override
  State<CruiseInputScreen> createState() => CruiseInputScreenState();
}

class CruiseInputScreenState extends State<CruiseInputScreen>
    with SingleTickerProviderStateMixin {
  // Core numeric state
  double cruiseSpeed = 130;
  double missionDistance = 100;
  double altitude = 2000;
  double temperature = 20;
  double fuelOnboard = 1200;
  double extraHoistMinutes = 0;

  // Last calculation snapshot (for side charts)
  double? _lastRequiredTorque;
  double? _lastAdjustedFuelBurn;
  double? _lastFuelRemaining;

  // Text controllers
  final cruiseSpeedController = TextEditingController();
  final missionDistanceController = TextEditingController();
  final altitudeController = TextEditingController();
  final temperatureController = TextEditingController();
  final fuelController = TextEditingController();
  final hoistTimeController = TextEditingController();
  final originLatController = TextEditingController();
  final originLonController = TextEditingController();
  final destLatController = TextEditingController();
  final destLonController = TextEditingController();
  // Additional coordinate controllers (waypoint / hospital)
  final waypoint1LatController = TextEditingController();
  final waypoint1LonController = TextEditingController();
  final hospitalLatController = TextEditingController();
  final hospitalLonController = TextEditingController();
  // Additional coordinate controllers (waypoint / hospital / waypoint2)
  final waypoint2LatController = TextEditingController();
  final waypoint2LonController = TextEditingController();

  final Map<String, TextEditingController> _sarHeadingCtrls = {};
  final MapController _mapController = MapController();

  bool showSarLabels = true;
  bool includeSarInPnr = true;
  bool _headingUp = false;

  // Flags for optional waypoints
  bool useWaypoint1 = false;
  bool useHospitalWaypoint = false;
  bool useWaypoint2 = false;
  // (removed duplicate small build — full build method appears later)
  // SAR pattern state: per-waypoint generated paths and chosen type
  final Map<String, List<LatLng>> _sarPatternByWp = {};
  final Map<String, SarPatternType> _patternTypeByWp = {};

  final Map<String, SarParams> _sarParamsByWp = {};
  double _normHdg(double v) {
    if (!v.isFinite) return v;
    final n = v % 360.0;
    return n < 0 ? n + 360.0 : n;
  }

  // Ensure params exist for a waypoint for current type
  SarParams _ensureSarParams(String wpId, SarPatternType t) {
    final cur = _sarParamsByWp[wpId];
    if (cur != null) return cur;
    final def = SarParams.defaultsFor(t);
    _sarParamsByWp[wpId] = def;
    return def;
  }

  // Small numeric fields for SAR params
  Widget _sarNumberField({
    required String label,
    required double value,
    required void Function(double) onChanged,
    double width = 90,
    int decimals = 1,
  }) {
    final ctrl = TextEditingController(
      text: value.isFinite ? value.toStringAsFixed(decimals) : '',
    );
    return SizedBox(
      width: width,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: (s) => onChanged(_parseNumber(s)),
      ),
    );
  }

  Widget _sarIntField({
    required String label,
    required int value,
    required void Function(int) onChanged,
    double width = 90,
  }) {
    final ctrl = TextEditingController(text: value.toString());
    return SizedBox(
      width: width,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: (s) => onChanged(_parseNumber(s).round()),
      ),
    );
  }

  LatLng? _aircraftPosition;
  double _aircraftHeading = 0.0;
  Timer? _simTimer;

  // ...inside CruiseInputScreenState...
  LatLng? _aircraftAnimFrom;
  LatLng? _aircraftAnimTo;
  double _aircraftAnimT = 1.0; // 1.0 = at "to" position
  AnimationController? _aircraftAnimController;

  // Geo forward solver reused for SAR legs (bearing deg, distance NM)
  LatLng _fwd(LatLng p, double bearingDeg, double distNm) =>
      _destinationPointFromRadialNm(
        latDeg: p.latitude,
        lonDeg: p.longitude,
        radialDeg: bearingDeg,
        distanceNm: distNm,
      );

  // Helper: append pattern pts (skip first if same anchor) into pts
  void _appendPatternIfAny(List<LatLng> pts, String wpId, LatLng anchor) {
    final pat = _sarPatternByWp[wpId];
    if (pat == null || pat.isEmpty) return;
    final start = pat.first;
    // avoid duplicating the anchor point
    final iterable =
        (start.latitude == anchor.latitude &&
            start.longitude == anchor.longitude)
        ? pat.skip(1)
        : pat;
    pts.addAll(iterable);
  }

  void _clearSarFor(String wpId) {
    setState(() {
      _sarPatternByWp.remove(wpId); // remove generated geometry
      // reset params to defaults for current type
      final t = _patternTypeByWp[wpId] ?? SarPatternType.parallel;
      _sarParamsByWp[wpId] = SarParams.defaultsFor(t);
      // clear heading textbox if any
      _sarHeadingCtrls[wpId]?.text = '';
    });
    _validateAndDistance(); // recompute route length without the pattern
  }

  Future<void> _startGpsTracking() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).listen((pos) {
      setState(() {
        _aircraftPosition = LatLng(pos.latitude, pos.longitude);
        _aircraftHeading = pos.heading.isFinite ? pos.heading : 0.0;
      });
      if (_autoCenterEnabled && _aircraftPosition != null) {
        _mapController.move(_aircraftPosition!, _mapController.camera.zoom);
      }
    });
  }

  void _startSimulation() {
    _simTimer?.cancel();

    // Build the planned route as a list of LatLngs
    final pts = <LatLng>[];
    final oLat = _parseCoord(originLatController.text, isLat: true);
    final oLon = _parseCoord(originLonController.text, isLat: false);
    final dLat = _parseCoord(destLatController.text, isLat: true);
    final dLon = _parseCoord(destLonController.text, isLat: false);
    if (oLat.isFinite && oLon.isFinite) {
      pts.add(LatLng(oLat, oLon));
    }
    for (final wp in _waypoints) {
      if (!wp.enabled) continue;
      final wLat = _parseCoord(wp.lat.text, isLat: true);
      final wLon = _parseCoord(wp.lon.text, isLat: false);
      if (wLat.isFinite && wLon.isFinite) {
        final anchor = LatLng(wLat, wLon);
        pts.add(anchor);
        _appendPatternIfAny(pts, wp.id, anchor);
      }
    }
    if (dLat.isFinite && dLon.isFinite) {
      pts.add(LatLng(dLat, dLon));
    }
    if (pts.length < 2) return;

    int segIdx = 0;
    double segT = 0.0;
    const speedNmPerSec = 70.0 / 3600.0; // 70 knots in NM/sec
    LatLng pos = pts[0];

    _aircraftPosition = pos;
    _aircraftHeading = _initialBearingDeg(
      pts[0].latitude,
      pts[0].longitude,
      pts[1].latitude,
      pts[1].longitude,
    );

    _simTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (segIdx >= pts.length - 1) return;
      final a = pts[segIdx];
      final b = pts[segIdx + 1];
      final segLen = _gcDistanceNm(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
      if (segLen == 0) {
        segIdx++;
        segT = 0.0;
        return;
      }
      final step = speedNmPerSec / segLen;
      segT += step;
      if (segT >= 1.0) {
        segIdx++;
        segT = 0.0;
        if (segIdx >= pts.length - 1) {
          setState(() {
            _aircraftPosition = pts.last;
          });
          return;
        }
      }
      final lat = a.latitude + (b.latitude - a.latitude) * segT;
      final lon = a.longitude + (b.longitude - a.longitude) * segT;
      final hdg = _initialBearingDeg(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
      final newPos = LatLng(lat, lon);
      _aircraftAnimFrom = _aircraftPosition ?? newPos;
      _aircraftAnimTo = newPos;
      _aircraftAnimController?.reset();
      _aircraftAnimController?.forward();
      _aircraftPosition = newPos;
      _aircraftHeading = hdg;
      if (kDebugMode) {
        print('Simulated aircraft position: $_aircraftPosition');
      }
      if (_autoCenterEnabled && _aircraftPosition != null) {
        _mapController.move(_aircraftPosition!, _mapController.camera.zoom);
      }
    });
  }

  void _stopSimulation() {
    _simTimer?.cancel();
    _simTimer = null;
  }

  // Build a lawnmower (parallel track) starting at anchor, along trackDeg
  List<LatLng> _buildParallelTrack({
    required LatLng anchor,
    required double trackDeg,
    required double legNm,
    required double spacingNm,
    required int legs,
  }) {
    final List<LatLng> out = [anchor];
    if (legs <= 0 || legNm <= 0 || spacingNm < 0) return out;
    final fwd = trackDeg % 360.0;
    final back = (fwd + 180.0) % 360.0;
    final right = (fwd + 90.0) % 360.0;
    LatLng cur = anchor;
    bool forward = true;
    for (int i = 0; i < legs; i++) {
      // run leg
      cur = _fwd(cur, forward ? fwd : back, legNm);
      out.add(cur);
      // offset to next lane (except after last leg)
      if (i != legs - 1) {
        cur = _fwd(cur, right, spacingNm);
        out.add(cur);
      }
      forward = !forward;
    }
    return out;
  }

  // Expanding square centered at anchor. stepNm is the first leg; grows each 2 legs.
  List<LatLng> _buildExpandingSquare({
    required LatLng anchor,
    required double initialBearingDeg,
    required double stepNm,
    required int layers,
  }) {
    final List<LatLng> out = [anchor];
    if (layers <= 0 || stepNm <= 0) return out;
    LatLng cur = anchor;
    double bearing = initialBearingDeg % 360.0;
    double leg = stepNm;
    for (int layer = 0; layer < layers; layer++) {
      // two legs of current length
      for (int k = 0; k < 2; k++) {
        cur = _fwd(cur, bearing, leg);
        out.add(cur);
        bearing = (bearing + 90.0) % 360.0;
      }
      // increase leg after two legs
      leg += stepNm;
      // two legs of new length
      for (int k = 0; k < 2; k++) {
        cur = _fwd(cur, bearing, leg);
        out.add(cur);
        bearing = (bearing + 90.0) % 360.0;
      }
      leg += stepNm;
    }
    // Optionally return to center (commented out)
    // out.add(anchor);
    return out;
  }

  // Sector search: radiate out-and-back from center across sectors
  List<LatLng> _buildSector({
    required LatLng anchor,
    required double radiusNm,
    required double startBearingDeg,
    required int sectors,
  }) {
    // Normalize
    final start = _normHdg(startBearingDeg);
    final step = 360.0 / (sectors.clamp(1, 36));
    final pts = <LatLng>[];
    // For each sector: out to rim, back to center, arc to next spoke
    for (int i = 0; i < sectors; i++) {
      final b0 = _normHdg(start + i * step);
      final b1 = _normHdg(start + (i + 1) * step);
      // Out
      final rim = _fwd(anchor, b0, radiusNm);
      if (pts.isEmpty) pts.add(anchor);
      pts.add(rim);
      // Back to center
      pts.add(anchor);
      // Arc along the rim to next sector (connectors)
      pts.addAll(
        _arcPoints(
          center: anchor,
          startBearingDeg: b0,
          endBearingDeg: b1,
          radiusNm: radiusNm,
          steps: 10,
        ),
      );
      // Ensure next leg starts from rim of next spoke (nice visual continuity)
      final nextRim = _fwd(anchor, b1, radiusNm);
      pts.add(nextRim);
      // And return to center so the next loop continues cleanly
      pts.add(anchor);
    }
    return pts;
  }

  // Generate points along a circular arc at constant radius from center
  List<LatLng> _arcPoints({
    required LatLng center,
    required double startBearingDeg,
    required double endBearingDeg,
    required double radiusNm,
    int steps = 8,
  }) {
    // Move counter-clockwise from start to end
    var a0 = _normHdg(startBearingDeg);
    var a1 = _normHdg(endBearingDeg);
    var delta = a1 - a0;
    if (delta <= 0) delta += 360.0;

    final out = <LatLng>[];
    for (int i = 1; i <= steps; i++) {
      final a = a0 + delta * (i / steps);
      out.add(_fwd(center, a, radiusNm));
    }
    return out;
  }

  // Generate pattern for a waypoint id using defaults
  void _generateSarFor(String wpId) {
    final wp = _waypoints.firstWhere(
      (w) => w.id == wpId,
      orElse: () => WaypointItem(
        id: '',
        title: '',
        lat: TextEditingController(),
        lon: TextEditingController(),
      ),
    );
    if (wp.id.isEmpty) return;
    final wLat = _parseCoord(wp.lat.text, isLat: true);
    final wLon = _parseCoord(wp.lon.text, isLat: false);
    if (!(wLat.isFinite && wLon.isFinite)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Enter valid ${wp.title} coordinates')),
      );
      return;
    }
    // Base track from origin->dest if available, else 0°
    final oLat = _parseCoord(originLatController.text, isLat: true);
    final oLon = _parseCoord(originLonController.text, isLat: false);
    final dLat = _parseCoord(destLatController.text, isLat: true);
    final dLon = _parseCoord(destLonController.text, isLat: false);
    final trackDeg =
        (oLat.isFinite && oLon.isFinite && dLat.isFinite && dLon.isFinite)
        ? _initialBearingDeg(oLat, oLon, dLat, dLon)
        : 0.0;

    final anchor = LatLng(wLat, wLon);
    final typ = _patternTypeByWp[wpId] ?? SarPatternType.parallel;
    final p = _ensureSarParams(wpId, typ);

    // Conservative defaults
    late final List<LatLng> pts;
    switch (typ) {
      case SarPatternType.parallel:
        pts = _buildParallelTrack(
          anchor: anchor,
          trackDeg: p.headingDeg.isFinite ? _normHdg(p.headingDeg) : trackDeg,
          legNm: (p.legNm > 0 ? p.legNm : 2.0),
          spacingNm: (p.spacingNm >= 0 ? p.spacingNm : 0.5),
          legs: (p.legs > 0 ? p.legs : 6),
        );
        break;
      case SarPatternType.expandingSquare:
        pts = _buildExpandingSquare(
          anchor: anchor,
          initialBearingDeg: p.headingDeg.isFinite
              ? _normHdg(p.headingDeg)
              : trackDeg,
          stepNm: (p.stepNm > 0 ? p.stepNm : 0.5),
          layers: (p.layers > 0 ? p.layers : 4),
        );
        break;
      case SarPatternType.sector:
        pts = _buildSector(
          anchor: anchor,
          radiusNm: (p.radiusNm > 0 ? p.radiusNm : 2.0),
          startBearingDeg: p.headingDeg.isFinite
              ? _normHdg(p.headingDeg)
              : trackDeg,
          sectors: (p.sectors > 0 ? p.sectors : 6),
        );
        break;
    }
    setState(() {
      _sarPatternByWp[wpId] = pts;
      // Ensure the wp is enabled (so route includes it)
      wp.enabled = true;
      _syncWaypointFlagsFromList();
    });
    // Recompute route distance including pattern
    _validateAndDistance();
  }

  // Coordinate validation errors for the extra waypoints
  String? waypoint1LatError,
      waypoint1LonError,
      hospitalLatError,
      hospitalLonError;
  String? waypoint2LatError, waypoint2LonError;

  void _syncWaypointFlagsFromList() {
    for (final wp in _waypoints) {
      switch (wp.id) {
        case 'hospital':
          useHospitalWaypoint = wp.enabled;
          break;
        case 'wpt1':
          useWaypoint1 = wp.enabled;
          break;
        case 'wpt2':
          useWaypoint2 = wp.enabled;
          break;
      }
    }
  }

  // Equipment toggles
  bool selectAllOptional = false;
  bool searchlight = false;
  bool radar = false;
  bool flir = false;
  bool hoist = false;

  // Wind / coordinate logic
  bool useWindsAloft = false;
  bool standardWinds = true;
  bool useDeviceLocation = true;
  bool autoDistanceFromLatLon = true;
  bool showMap = false;

  // Async calc guard
  bool _calculating = false;
  bool autoApplyAi = true;
  bool keepDmsFormat = true;
  bool _autoCenterEnabled = true;
  bool _simulateAircraft = false;

  // Coordinate validation errors
  String? originLatError, originLonError, destLatError, destLonError;
  // ignore: unused_field
  CruiseReportData? _lastReport;

  // AI suggestionsExport KML/Share/Print
  double? _aiSuggestedAltitudeFt;
  double? _aiSuggestedAltitudeOutFt;
  double? _aiSuggestedAltitudeBackFt;
  double? _aiTailwindKts;
  double? _aiTailwindOutKts;
  double? _aiTailwindBackKts;
  double? _aiSuggestedIas;

  double reserveFuel = 184; // kg default (≈ final reserve for AW139)
  final reserveController = TextEditingController(text: '184');

  double? _pnrNm; // Point of No Return distance from origin (NM)
  LatLng? _pnrPoint; // Geographic position along route for map pin

  // Nav tool controllers/state
  final _navRadialController = TextEditingController(text: '090');
  final _navDistanceController = TextEditingController(text: '10'); // NM
  int _selectedFixIndex = 0; // must be mutable for Dropdown
  // ignore: unused_field
  String? _navResultDecimal;
  // ignore: unused_field
  String? _navResultDms;
  bool showNavTool = false;
  final _navOutLatController = TextEditingController();
  final _navOutLonController = TextEditingController();
  // "Custom lat/lon…" option for the Nav tool dropdown
  static const int _customBaseIndex = -1;
  // Controllers for custom base coordinates (shown when _customBaseIndex selected)
  final _navBaseLatController = TextEditingController();
  final _navBaseLonController = TextEditingController();

  LatLng _destinationPointFromRadialNm({
    required double latDeg,
    required double lonDeg,
    required double radialDeg, // from the fix
    required double distanceNm,
  }) {
    const double rNm = 3440.065;
    final double bearing = radialDeg % 360.0;
    final double phi1 = _degToRad(latDeg);
    final double lambda1 = _degToRad(lonDeg);
    final double theta = _degToRad(bearing);
    final double delta = distanceNm / rNm;

    final double sinPhi2 =
        math.sin(phi1) * math.cos(delta) +
        math.cos(phi1) * math.sin(delta) * math.cos(theta);
    final double phi2 = math.asin(sinPhi2);

    final double y = math.sin(theta) * math.sin(delta) * math.cos(phi1);
    final double x = math.cos(delta) - math.sin(phi1) * math.sin(phi2);
    final double lambda2 = lambda1 + math.atan2(y, x);

    final double lat2 = _radToDeg(phi2);
    final double lon2 = ((_radToDeg(lambda2) + 540) % 360) - 180;
    return LatLng(lat2, lon2);
  }

  // Base-point resolver for Nav tool (uses dropdown, including Custom option)
  LatLng? _navBasePoint() {
    if (_selectedFixIndex == _customBaseIndex) {
      final bLat = _parseCoord(_navBaseLatController.text, isLat: true);
      final bLon = _parseCoord(_navBaseLonController.text, isLat: false);
      if (bLat.isFinite && bLon.isFinite) return LatLng(bLat, bLon);
      return null;
    }
    if (kNavFixes.isEmpty) return null;
    final i = _selectedFixIndex.clamp(0, kNavFixes.length - 1);
    final f = kNavFixes[i];
    return LatLng(f.lat, f.lon);
  }

  // ignore: unused_element
  void _computeNavFixPoint() {
    final base = _navBasePoint();
    final radial = _parseNumber(_navRadialController.text);
    final distNm = _parseNumber(_navDistanceController.text);
    if (base == null || !radial.isFinite || !distNm.isFinite) return;

    final p = _destinationPointFromRadialNm(
      latDeg: base.latitude,
      lonDeg: base.longitude,
      radialDeg: radial,
      distanceNm: distNm,
    );
    _navOutLatController.text = _formatDms(p.latitude, isLat: true);
    _navOutLonController.text = _formatDms(p.longitude, isLat: false);
    setState(() {});
  }

  void _applyNavResultTo(String id) {
    final base = _navBasePoint();
    final radial = _parseNumber(_navRadialController.text);
    final distNm = _parseNumber(_navDistanceController.text);
    if (base == null || !radial.isFinite || !distNm.isFinite) return;

    final p = _destinationPointFromRadialNm(
      latDeg: base.latitude,
      lonDeg: base.longitude,
      radialDeg: radial,
      distanceNm: distNm,
    );
    final latDms = _formatDms(p.latitude, isLat: true);
    final lonDms = _formatDms(p.longitude, isLat: false);

    setState(() {
      switch (id) {
        case 'hospital':
          hospitalLatController.text = latDms;
          hospitalLonController.text = lonDms;
          useHospitalWaypoint = true; // add braces
          break;
        case 'wpt1':
          waypoint1LatController.text = latDms;
          waypoint1LonController.text = lonDms;
          useWaypoint1 = true;
          break;
        case 'wpt2':
          waypoint2LatController.text = latDms;
          waypoint2LonController.text = lonDms;
          useWaypoint2 = true; // add braces
          break;
      }
      for (final wp in _waypoints) {
        if (wp.id == id) {
          wp.enabled = true;
          wp.lat.text = latDms;
          wp.lon.text = lonDms;
        }
      }
    });
    _validateAndDistance();
  }
  // ...existing code...

  // AI optimization settings
  OptimizationObjective _objective = OptimizationObjective.minFuel;
  double _timeWeightKgPerMin = 0.0; // hybrid: how many kg one minute is “worth”

  // Aircraft selection (default AW139). Add 'Bell 412' when you upload tables.
  String _selectedAircraft = 'AW139';
  static const List<String> kAircraftOptions = ['AW139', 'Bell 412'];

  // Wind provider selection
  WindProvider _windProvider = kWindyApiKey.isNotEmpty
      ? WindProvider.windy
      : WindProvider.openMeteo;
  static const Map<WindProvider, String> _windProviderNames = {
    WindProvider.windy: 'Windy',
    WindProvider.openMeteo: 'Open‑Meteo',
  };

  // Placeholder for Bell 412 speed-based fuel tables.
  // Structure expected: { altitudeFt: { oatC: { iasKts: burnKgPerHr, ... }, ... }, ... }
  // Fill this map by uploading CSV/JSON or pasting tables and I'll implement loader/interpolator.
  // ignore: unused_field
  final Map<int, Map<int, Map<int, double>>> _bh412SpeedBurnTables = {};

  double interpolateWind(double windSpeed) {
    // Example logic — adjust as needed
    return windSpeed * 0.85;
  }

  Map<int, Map<String, double>>? _aiWindsAloft;
  Map<int, Map<String, double>>? _departureWindsAloft;
  Map<int, Map<String, double>>? _destinationWindsAloft;

  // Store wind profile arrays fetched per key (e.g. 'origin','dest')
  final Map<String, List<Map<String, double>>> _fetchedWindLevelsByKey = {};

  String _mapEditTarget = 'wpt1';

  // Draggable mid-route waypoints (Hospital / WP1 / WP2)
  late List<WaypointItem> _waypoints;

  // Build arrow markers for a stored wind profile at a point (alt in ft)
  List<Marker> _buildWindArrowMarkers(
    String key,
    double lat,
    double lon, {
    double alt = 2000,
  }) {
    final levels = _fetchedWindLevelsByKey[key];
    if (levels == null) return [];
    final wind = _interpolateWind(alt, levels);
    final dirFrom = (wind['dirFrom'] ?? 0.0);
    final speed = (wind['speed'] ?? 0.0);
    final windToDeg = (dirFrom + 180.0) % 360.0;
    final angle = _degToRad(windToDeg);
    final size = (speed * 8.0 + 32.0).clamp(20.0, 96.0);

    return [
      Marker(
        point: LatLng(lat, lon),
        width: size,
        height: size,
        // builder -> child (your flutter_map needs child:)
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black54,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 4)],
          ),
          child: Transform.rotate(
            angle: angle,
            child: Icon(
              Icons.navigation,
              color: Colors.yellowAccent,
              size: size * 0.7,
            ),
          ),
        ),
      ),
    ];
  }

  // Build PNR marker list (typed)
  List<Marker> _buildPnrMarkers() {
    if (_pnrPoint == null || _pnrNm == null || _pnrNm! <= 0) {
      return const <Marker>[];
    }
    return <Marker>[
      Marker(
        point: _pnrPoint!,
        width: 36,
        height: 36,
        // builder -> child
        child: const Icon(Icons.pin_drop, color: Colors.amber, size: 32),
      ),
    ];
  }

  // Assign a distinct color per waypoint
  Color _sarColorFor(String wpId) {
    switch (wpId) {
      case 'hospital':
        return Colors.pinkAccent;
      case 'wpt1':
        return Colors.cyanAccent;
      case 'wpt2':
        return Colors.orangeAccent;
      default:
        return Colors.amberAccent;
    }
  }

  List<Polyline> _buildSarPolylines() {
    final lines = <Polyline>[];
    _sarPatternByWp.forEach((wpId, pts) {
      if (pts.length >= 2) {
        // Outline (below)
        lines.add(
          Polyline(
            points: pts,
            color: Colors.black.withValues(alpha: 0.40),
            strokeWidth: 6,
          ),
        );
        // Colored main line (above)
        lines.add(
          Polyline(
            points: pts,
            color: _sarColorFor(wpId).withValues(alpha: 0.95),
            strokeWidth: 3,
          ),
        );
      }
    });
    return lines;
  }

  List<Marker> _buildSarLabelMarkers() {
    final ms = <Marker>[];
    _sarPatternByWp.forEach((wpId, pts) {
      if (pts.isEmpty) return;
      final col = _sarColorFor(wpId);

      Widget chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: col, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: col, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      );

      // START at first point
      ms.add(
        Marker(
          point: pts.first,
          width: 140,
          height: 28,
          child: chip('START: ${wpId.toUpperCase()}'),
        ),
      );

      // END at last point (skip if same as start)
      final last = pts.last;
      if (last.latitude != pts.first.latitude ||
          last.longitude != pts.first.longitude) {
        ms.add(Marker(point: last, width: 120, height: 28, child: chip('END')));
      }
    });
    return ms;
  }

  // Replace your existing _sarArrowMarkers with this colored version
  List<Marker> _sarArrowMarkers() {
    const minSegNm = 0.2;
    final markers = <Marker>[];
    _sarPatternByWp.forEach((wpId, pts) {
      final col = _sarColorFor(wpId);
      for (int i = 0; i + 1 < pts.length; i++) {
        final a = pts[i];
        final b = pts[i + 1];
        final dNm = _gcDistanceNm(
          a.latitude,
          a.longitude,
          b.latitude,
          b.longitude,
        );
        if (dNm < minSegNm) continue;

        final mid = LatLng(
          (a.latitude + b.latitude) / 2.0,
          (a.longitude + b.longitude) / 2.0,
        );
        final brg = _initialBearingDeg(
          a.latitude,
          a.longitude,
          b.latitude,
          b.longitude,
        );
        final rad = _degToRad(brg);

        markers.add(
          Marker(
            point: mid,
            width: 18,
            height: 18,
            child: Transform.rotate(
              angle: rad,
              child: Icon(Icons.arrow_right_alt, size: 18, color: col),
            ),
          ),
        );
      }
    });
    return markers;
  }

  Map<String, double> _tailOutBack(
    double altFt,
    double trackDeg,
    List<Map<String, double>> baseLevels,
  ) {
    final wind = _interpolateWind(altFt, baseLevels);
    final outTail = _tailwindKts(wind['speed']!, wind['dirFrom']!, trackDeg);
    final backTail = _tailwindKts(
      wind['speed']!,
      wind['dirFrom']!,
      (trackDeg + 180) % 360,
    );
    return {'out': outTail, 'back': backTail};
  }

  // ignore: unused_element
  bool _mapEquals(
    Map<int, Map<String, double>> a,
    Map<int, Map<String, double>> b,
  ) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      // Compare tailwind and direction for each altitude
      if (a[key]?['tailwind'] != b[key]?['tailwind'] ||
          a[key]?['dir'] != b[key]?['dir']) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _ensureLocationPermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  double getOrInterpolateWind(int targetAlt, Map<int, double> windData) {
    if (windData.containsKey(targetAlt)) return windData[targetAlt]!;
    final keys = windData.keys.toList()..sort();
    for (int i = 0; i < keys.length - 1; i++) {
      if (keys[i] < targetAlt && keys[i + 1] > targetAlt) {
        final alt1 = keys[i], alt2 = keys[i + 1];
        final wind1 = windData[alt1]!, wind2 = windData[alt2]!;
        final ratio = (targetAlt - alt1) / (alt2 - alt1);
        return wind1 + (wind2 - wind1) * ratio;
      }
    }
    // If out of range, return closest
    return windData[keys.reduce(
      (a, b) => (a - targetAlt).abs() < (b - targetAlt).abs() ? a : b,
    )]!;
  }

  // Add helper in CruiseInputScreenState
  LatLng _safeMapCenter() {
    final lat = _parseCoord(originLatController.text, isLat: true);
    final lon = _parseCoord(originLonController.text, isLat: false);
    if (lat.isFinite && lon.isFinite) return LatLng(lat, lon);
    return const LatLng(34.8723, 33.6243); // fallback: LCA area
  }

  // Class-level wind interpolator used by _tailOutBack and AI helpers
  Map<String, double> _interpolateWind(
    double altFt,
    List<Map<String, double>> levels,
  ) {
    if (levels.isEmpty) return {'speed': 0, 'dirFrom': 0};
    levels.sort((a, b) => a['alt']!.compareTo(b['alt']!));
    if (altFt <= levels.first['alt']!) {
      return {
        'speed': levels.first['speed']!,
        'dirFrom': levels.first['dirFrom']!,
      };
    }
    if (altFt >= levels.last['alt']!) {
      return {
        'speed': levels.last['speed']!,
        'dirFrom': levels.last['dirFrom']!,
      };
    }
    for (int i = 0; i < levels.length - 1; i++) {
      final lo = levels[i];
      final hi = levels[i + 1];
      if (altFt >= lo['alt']! && altFt <= hi['alt']!) {
        final r = (altFt - lo['alt']!) / (hi['alt']! - lo['alt']!);
        final loUV = windToUV(lo['speed']!, lo['dirFrom']!);
        final hiUV = windToUV(hi['speed']!, hi['dirFrom']!);
        final u = loUV['u']! + r * (hiUV['u']! - loUV['u']!);
        final v = loUV['v']! + r * (hiUV['v']! - loUV['v']!);
        return uvToWind(u, v);
      }
    }
    return {'speed': 0, 'dirFrom': 0};
  }
  // _interpolateWind implementation moved to class scope above

  @override
  void initState() {
    super.initState();
    // load BH412 performance table (safe to call even if asset missing)
    loadBh412TablesFromAsset();

    _aircraftAnimController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 800),
        )..addListener(() {
          if (_aircraftAnimFrom != null && _aircraftAnimTo != null) {
            setState(() {
              _aircraftAnimT = _aircraftAnimController!.value;
            });
          }
        });

    // controller initialization
    cruiseSpeedController.text = cruiseSpeed.toStringAsFixed(0);
    missionDistanceController.text = missionDistance.toStringAsFixed(0);
    altitudeController.text = altitude.toStringAsFixed(0);
    temperatureController.text = temperature.toStringAsFixed(0);
    fuelController.text = fuelOnboard.toStringAsFixed(0);
    hoistTimeController.text = extraHoistMinutes.toStringAsFixed(0);

    // Initialize draggable waypoint list
    _waypoints = [
      WaypointItem(
        id: 'hospital',
        title: 'Hospital',
        lat: hospitalLatController,
        lon: hospitalLonController,
        enabled: useHospitalWaypoint,
      ),
      WaypointItem(
        id: 'wpt1',
        title: 'Waypoint 1',
        lat: waypoint1LatController,
        lon: waypoint1LonController,
        enabled: useWaypoint1,
      ),
      WaypointItem(
        id: 'wpt2',
        title: 'Waypoint 2',
        lat: waypoint2LatController,
        lon: waypoint2LonController,
        enabled: useWaypoint2,
      ),
    ];
  }

  @override
  void dispose() {
    cruiseSpeedController.dispose();
    missionDistanceController.dispose();
    altitudeController.dispose();
    temperatureController.dispose();
    fuelController.dispose();
    hoistTimeController.dispose();
    originLatController.dispose();
    originLonController.dispose();
    destLatController.dispose();
    destLonController.dispose();
    waypoint1LatController.dispose();
    waypoint1LonController.dispose();
    hospitalLatController.dispose();
    hospitalLonController.dispose();
    waypoint2LatController.dispose();
    waypoint2LonController.dispose();

    // Nav tool controllers
    _navRadialController.dispose();
    _navDistanceController.dispose();
    _navOutLatController.dispose();
    _navOutLonController.dispose();
    _navBaseLatController.dispose();
    _navBaseLonController.dispose();
    super.dispose();
    // Dispose SAR heading text controllers
    for (final c in _sarHeadingCtrls.values) {
      c.dispose();
    }
  }

  // ---------- Coordinate Handling ----------

  void _formatControllerToDms(TextEditingController c, {required bool isLat}) {
    if (!keepDmsFormat) return;
    final v = _parseCoord(c.text, isLat: isLat);
    if (!v.isFinite) return;
    final dms = _formatDms(v, isLat: isLat);
    if (c.text != dms) {
      setState(() {
        c.text = dms;
        c.selection = TextSelection.fromPosition(
          TextPosition(offset: c.text.length),
        );
      });
    }
  }

  void _validateAndDistance() {
    String? valErr(double v, bool isLat, String raw) {
      if (raw.trim().isEmpty) return null;
      if (!v.isFinite) return 'Invalid';
      final lim = isLat ? 90.0 : 180.0;
      if (v.abs() > lim) return 'Out of range';
      return null;
    }

    // ...existing code...
    final rawOLat = originLatController.text;
    final rawOLon = originLonController.text;
    final rawW1Lat = waypoint1LatController.text;
    final rawW1Lon = waypoint1LonController.text;
    final rawDLat = destLatController.text;
    final rawDLon = destLonController.text;

    final oLat = _parseCoord(rawOLat, isLat: true);
    final oLon = _parseCoord(rawOLon, isLat: false);
    final w1Lat = _parseCoord(rawW1Lat, isLat: true);
    final w1Lon = _parseCoord(rawW1Lon, isLat: false);
    final dLat = _parseCoord(rawDLat, isLat: true);
    final dLon = _parseCoord(rawDLon, isLat: false);

    final newOriginLatError = valErr(oLat, true, rawOLat);
    final newOriginLonError = valErr(oLon, false, rawOLon);
    final newWaypoint1LatError = useWaypoint1
        ? valErr(w1Lat, true, rawW1Lat)
        : null;
    final newWaypoint1LonError = useWaypoint1
        ? valErr(w1Lon, false, rawW1Lon)
        : null;
    final newDestLatError = valErr(dLat, true, rawDLat);
    final newDestLonError = valErr(dLon, false, rawDLon);

    final rawHLat = hospitalLatController.text;
    final rawHLon = hospitalLonController.text;
    final hLat = _parseCoord(rawHLat, isLat: true);
    final hLon = _parseCoord(rawHLon, isLat: false);
    final newHospitalLatError = useHospitalWaypoint
        ? valErr(hLat, true, rawHLat)
        : null;
    final newHospitalLonError = useHospitalWaypoint
        ? valErr(hLon, false, rawHLon)
        : null;

    bool changed =
        newOriginLatError != originLatError ||
        newOriginLonError != originLonError ||
        newWaypoint1LatError != waypoint1LatError ||
        newWaypoint1LonError != waypoint1LonError ||
        newDestLatError != destLatError ||
        newDestLonError != destLonError ||
        newHospitalLatError != hospitalLatError ||
        newHospitalLonError != hospitalLonError;

    // Auto compute missionDistance (one-way) when enabled
    if (autoDistanceFromLatLon) {
      final points = <LatLng>[];
      if (oLat.isFinite && oLon.isFinite) {
        points.add(LatLng(oLat, oLon));
      }
      // Use draggable mid-route waypoints in current order
      for (final wp in _waypoints) {
        if (!wp.enabled) {
          continue;
        }
        final wLat = _parseCoord(wp.lat.text, isLat: true);
        final wLon = _parseCoord(wp.lon.text, isLat: false);
        if (wLat.isFinite && wLon.isFinite) {
          final anchor = LatLng(wLat, wLon);
          points.add(anchor);
          _appendPatternIfAny(points, wp.id, anchor);
        }
      }
      if (dLat.isFinite && dLon.isFinite) {
        points.add(LatLng(dLat, dLon));
      }

      if (points.length >= 2) {
        double total = 0.0;
        for (int i = 0; i < points.length - 1; i++) {
          total += _gcDistanceNm(
            points[i].latitude,
            points[i].longitude,
            points[i + 1].latitude,
            points[i + 1].longitude,
          );
        }
        missionDistanceController.text = total.toStringAsFixed(0);
        missionDistance = total;
      }
    }

    if (changed) {
      setState(() {
        originLatError = newOriginLatError;
        originLonError = newOriginLonError;
        waypoint1LatError = newWaypoint1LatError;
        waypoint1LonError = newWaypoint1LonError;
        destLatError = newDestLatError;
        destLonError = newDestLonError;
        hospitalLatError = newHospitalLatError;
        hospitalLonError = newHospitalLonError;
      });
    }
    // end _validateAndDistance
  }

  // ...existing code...
  Widget buildWaypointPlanner() {
    return Card(
      color: kPanelColor,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Flight Plan Waypoints (drag to reorder)',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = _waypoints.removeAt(oldIndex);
                  _waypoints.insert(newIndex, item);
                  _validateAndDistance();
                });
              },
              children: [
                for (final wp in _waypoints)
                  ListTile(
                    key: ValueKey(wp.id),
                    leading: const Icon(
                      Icons.drag_indicator,
                      color: Colors.white70,
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            wp.title,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        Switch(
                          value: wp.enabled,
                          onChanged: (v) {
                            setState(() {
                              wp.enabled = v;
                              _syncWaypointFlagsFromList(); // keep legacy flags in sync
                            });
                            _validateAndDistance();
                          },
                        ),
                      ],
                    ),
                    // ...inside buildWaypointPlanner() -> ListTile(...),
                    subtitle: wp.enabled
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              coordField(
                                '${wp.title} Latitude',
                                wp.lat,
                                isLat: true,
                                errorText: null,
                              ),
                              coordField(
                                '${wp.title} Longitude',
                                wp.lon,
                                isLat: false,
                                errorText: null,
                              ),
                              // SAR pattern controls
                              Padding(
                                padding: const EdgeInsets.only(top: 6.0),
                                child: Row(
                                  children: [
                                    const Text(
                                      'SAR:',
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                    const SizedBox(width: 8),
                                    DropdownButton<SarPatternType>(
                                      value:
                                          _patternTypeByWp[wp.id] ??
                                          SarPatternType.parallel,
                                      dropdownColor: kPanelColor,
                                      items: const [
                                        DropdownMenuItem(
                                          value: SarPatternType.parallel,
                                          child: Text(
                                            'Parallel Track',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: SarPatternType.expandingSquare,
                                          child: Text(
                                            'Expanding Square',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: SarPatternType.sector,
                                          child: Text(
                                            'Sector',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                      onChanged: (v) => setState(() {
                                        if (v != null) {
                                          _patternTypeByWp[wp.id] = v;
                                        }
                                      }),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton(
                                      onPressed: () => _generateSarFor(wp.id),
                                      child: const Text('Add Pattern'),
                                    ),
                                    const SizedBox(width: 6),
                                    OutlinedButton(
                                      onPressed:
                                          _sarPatternByWp.containsKey(wp.id)
                                          ? () => _clearSarFor(wp.id)
                                          : null,
                                      child: const Text('Clear'),
                                    ),
                                  ],
                                ),
                              ),
                              // SAR parameter fields
                              Builder(
                                builder: (_) {
                                  final typ =
                                      _patternTypeByWp[wp.id] ??
                                      SarPatternType.parallel;
                                  final params = _ensureSarParams(wp.id, typ);
                                  // default route heading (optional quick fill)
                                  final oLat = _parseCoord(
                                    originLatController.text,
                                    isLat: true,
                                  );
                                  final oLon = _parseCoord(
                                    originLonController.text,
                                    isLat: false,
                                  );
                                  final dLat = _parseCoord(
                                    destLatController.text,
                                    isLat: true,
                                  );
                                  final dLon = _parseCoord(
                                    destLonController.text,
                                    isLat: false,
                                  );
                                  final rteHdg =
                                      (oLat.isFinite &&
                                          oLon.isFinite &&
                                          dLat.isFinite &&
                                          dLon.isFinite)
                                      ? _initialBearingDeg(
                                          oLat,
                                          oLon,
                                          dLat,
                                          dLon,
                                        )
                                      : 0.0;

                                  return Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        // Heading shown for all types (persistent controller)
                                        Builder(
                                          builder: (_) {
                                            final headingCtrl = _sarHeadingCtrls
                                                .putIfAbsent(
                                                  wp.id,
                                                  () => TextEditingController(
                                                    text:
                                                        params
                                                            .headingDeg
                                                            .isFinite
                                                        ? params.headingDeg
                                                              .toStringAsFixed(
                                                                0,
                                                              )
                                                        : '',
                                                  ),
                                                );
                                            return SizedBox(
                                              width: 100,
                                              child: TextField(
                                                controller: headingCtrl,
                                                keyboardType:
                                                    TextInputType.number,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'Heading°',
                                                      isDense: true,
                                                      border:
                                                          OutlineInputBorder(),
                                                    ),
                                                onChanged: (s) {
                                                  final v = _parseNumber(s);
                                                  setState(() {
                                                    params.headingDeg =
                                                        _normHdg(v);
                                                    _sarParamsByWp[wp.id] =
                                                        params;
                                                  });
                                                },
                                              ),
                                            );
                                          },
                                        ),
                                        TextButton(
                                          onPressed: () => setState(() {
                                            params.headingDeg = _normHdg(
                                              rteHdg,
                                            );
                                            _sarParamsByWp[wp.id] = params;
                                            _sarHeadingCtrls[wp.id]?.text =
                                                params.headingDeg
                                                    .toStringAsFixed(0);
                                          }),
                                          child: const Text('Use Route'),
                                        ),
                                        if (typ == SarPatternType.parallel) ...[
                                          _sarNumberField(
                                            label: 'Leg NM',
                                            value: params.legNm,
                                            onChanged: (v) => setState(() {
                                              params.legNm = v;
                                              _sarParamsByWp[wp.id] = params;
                                            }),
                                          ),
                                          _sarNumberField(
                                            label: 'Spacing',
                                            value: params.spacingNm,
                                            onChanged: (v) => setState(() {
                                              params.spacingNm = v;
                                              _sarParamsByWp[wp.id] = params;
                                            }),
                                          ),
                                          _sarIntField(
                                            label: 'Legs',
                                            value: params.legs,
                                            onChanged: (v) => setState(() {
                                              params.legs = v;
                                              _sarParamsByWp[wp.id] = params;
                                            }),
                                          ),
                                        ] else if (typ ==
                                            SarPatternType.expandingSquare) ...[
                                          _sarNumberField(
                                            label: 'Step NM',
                                            value: params.stepNm,
                                            onChanged: (v) => setState(() {
                                              params.stepNm = v;
                                              _sarParamsByWp[wp.id] = params;
                                            }),
                                          ),
                                          _sarIntField(
                                            label: 'Layers',
                                            value: params.layers,
                                            onChanged: (v) => setState(() {
                                              params.layers = v;
                                              _sarParamsByWp[wp.id] = params;
                                            }),
                                          ),
                                        ] else if (typ ==
                                            SarPatternType.sector) ...[
                                          _sarNumberField(
                                            label: 'Radius NM',
                                            value: params.radiusNm,
                                            onChanged: (v) => setState(() {
                                              params.radiusNm = v;
                                              _sarParamsByWp[wp.id] = params;
                                            }),
                                          ),
                                          _sarIntField(
                                            label: 'Sectors',
                                            value: params.sectors,
                                            onChanged: (v) => setState(() {
                                              params.sectors = v;
                                              _sarParamsByWp[wp.id] = params;
                                            }),
                                          ),
                                        ],
                                        // Regenerate with current params
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _generateSarFor(wp.id),
                                          icon: const Icon(Icons.refresh),
                                          label: const Text('Regenerate'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          )
                        : null,
                  ),
              ],
            ),
            // ...existing code...

            // ...existing code...
            const SizedBox(height: 6),
            const Text(
              'Origin is first and Destination last. Only enabled items are included.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ...existing code...
  Widget coordField(
    String label,
    TextEditingController controller, {
    required bool isLat,
    required String? errorText,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: controller,
        onChanged: (_) => _validateAndDistance(), // no timer
        onEditingComplete: () {
          _formatControllerToDms(controller, isLat: isLat);
          _validateAndDistance();
          FocusScope.of(context).nextFocus();
        },
        decoration: InputDecoration(
          labelText: label,
          errorText: errorText,
          hintText: isLat ? '34 59 09.8 N' : '033 39 14.5 E',
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: keepDmsFormat
              ? IconButton(
                  tooltip: 'Format DMS',
                  icon: const Icon(
                    Icons.my_location,
                    size: 18,
                    color: Colors.cyan,
                  ),
                  onPressed: () {
                    _formatControllerToDms(controller, isLat: isLat);
                    _validateAndDistance();
                  },
                )
              : null,
        ),
        style: const TextStyle(color: Colors.white),
        textInputAction: TextInputAction.next,
      ),
    );
  }

  double _sarDistanceOneWayNm() {
    double sum = 0.0;
    _sarPatternByWp.forEach((wpId, pts) {
      // Only count patterns for enabled waypoints
      final enabled = _waypoints.any((w) => w.id == wpId && w.enabled);
      if (!enabled || pts.length < 2) return;
      for (int i = 0; i + 1 < pts.length; i++) {
        sum += _gcDistanceNm(
          pts[i].latitude,
          pts[i].longitude,
          pts[i + 1].latitude,
          pts[i + 1].longitude,
        );
      }
    });
    return sum;
  }

  // Serialize current plan (origin/dest, waypoints, SAR params + generated points)
  Map<String, dynamic> _buildPlanJson() {
    double? dec(String s, {required bool isLat}) {
      final v = _parseCoord(s, isLat: isLat);
      return v.isFinite ? v : null;
    }

    SarPatternType typeFor(String id) =>
        _patternTypeByWp[id] ?? SarPatternType.parallel;

    Map<String, dynamic> paramsToJson(SarParams p) => {
      'headingDeg': p.headingDeg,
      'legNm': p.legNm,
      'spacingNm': p.spacingNm,
      'legs': p.legs,
      'stepNm': p.stepNm,
      'layers': p.layers,
      'radiusNm': p.radiusNm,
      'sectors': p.sectors,
    };

    List<List<double>> ptsToJson(List<LatLng> pts) =>
        pts.map((p) => [p.latitude, p.longitude]).toList();

    final order = _waypoints.map((w) => w.id).toList();
    final wps = _waypoints
        .map(
          (w) => {
            'id': w.id,
            'title': w.title,
            'enabled': w.enabled,
            'lat': dec(w.lat.text, isLat: true),
            'lon': dec(w.lon.text, isLat: false),
            'patternType': typeFor(w.id).name,
            'params': paramsToJson(
              _ensureSarParams(w.id, typeFor(w.id)),
            ), // <-- close paramsToJson(...)
            if (_sarPatternByWp[w.id] != null)
              'generatedPoints': ptsToJson(_sarPatternByWp[w.id]!),
          },
        )
        .toList();

    return {
      'version': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'includeSarInPnr': includeSarInPnr,
      'showSarLabels': showSarLabels,
      'origin': {
        'lat': dec(originLatController.text, isLat: true),
        'lon': dec(originLonController.text, isLat: false),
      },
      'destination': {
        'lat': dec(destLatController.text, isLat: true),
        'lon': dec(destLonController.text, isLat: false),
      },
      'waypointOrder': order,
      'waypoints': wps,
    };
  }

  SarPatternType _typeFromName(String? name) {
    switch (name) {
      case 'parallel':
        return SarPatternType.parallel;
      case 'expandingSquare':
        return SarPatternType.expandingSquare;
      case 'sector':
        return SarPatternType.sector;
      default:
        return SarPatternType.parallel;
    }
  }

  SarParams _paramsFromJson(Map<String, dynamic>? m) {
    if (m == null) return SarParams.defaultsFor(SarPatternType.parallel);
    double d(dynamic v) => _numToDouble(v);
    int i(dynamic v) => (v is int) ? v : d(v).round();
    return SarParams(
      headingDeg: d(m['headingDeg']),
      legNm: d(m['legNm']),
      spacingNm: d(m['spacingNm']),
      legs: i(m['legs']),
      stepNm: d(m['stepNm']),
      layers: i(m['layers']),
      radiusNm: d(m['radiusNm']),
      sectors: i(m['sectors']),
    );
  }

  Future<void> savePlanJson() async {
    final jsonMap = _buildPlanJson();
    final pretty = const JsonEncoder.withIndent('  ').convert(jsonMap);
    final saveLocation = await getSaveLocation(
      suggestedName: 'mission_plan.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (saveLocation == null) {
      await Clipboard.setData(ClipboardData(text: pretty));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Plan JSON copied to clipboard')),
        );
      }
      return;
    }
    final data = Uint8List.fromList(utf8.encode(pretty));
    final xfile = XFile.fromData(
      data,
      name: 'mission_plan.json',
      mimeType: 'application/json',
    );
    await xfile.saveTo(saveLocation.path);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved: ${saveLocation.path}')));
    }
  }

  Future<void> loadPlanJson() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final text = utf8.decode(bytes);
    final obj = jsonDecode(text) as Map<String, dynamic>;
    _applyPlanJson(obj);
  }

  void _applyPlanJson(Map<String, dynamic> j) {
    double? d(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    List<LatLng> ptsFromJson(List<dynamic>? arr) {
      if (arr == null) return const <LatLng>[];
      return arr
          .whereType<List>()
          .where((p) => p.length >= 2)
          .map((p) => LatLng(d(p[0]) ?? double.nan, d(p[1]) ?? double.nan))
          .where((p) => p.latitude.isFinite && p.longitude.isFinite)
          .toList();
    }

    setState(() {
      includeSarInPnr = (j['includeSarInPnr'] ?? includeSarInPnr) == true;
      showSarLabels = (j['showSarLabels'] ?? showSarLabels) == true;

      final o = j['origin'] as Map<String, dynamic>?;
      final de = j['destination'] as Map<String, dynamic>?;
      final oLat = d(o?['lat']), oLon = d(o?['lon']);
      final dLatV = d(de?['lat']), dLonV = d(de?['lon']);
      if (oLat != null && oLon != null) {
        originLatController.text = oLat.toStringAsFixed(6);
        originLonController.text = oLon.toStringAsFixed(6);
      }
      if (dLatV != null && dLonV != null) {
        destLatController.text = dLatV.toStringAsFixed(6);
        destLonController.text = dLonV.toStringAsFixed(6);
      }

      // Reorder waypoints by saved order
      final order = (j['waypointOrder'] as List?)?.whereType<String>().toList();
      if (order != null && order.isNotEmpty) {
        final map = {for (final w in _waypoints) w.id: w};
        final newList = <WaypointItem>[];
        for (final id in order) {
          final w = map[id];
          if (w != null) newList.add(w);
        }
        // include any missing (fallback)
        for (final w in _waypoints) {
          if (!newList.contains(w)) newList.add(w);
        }
        _waypoints = newList;
      }

      // Reset SAR stores
      _sarPatternByWp.clear();
      _patternTypeByWp.clear();
      _sarParamsByWp.clear();

      final wps = (j['waypoints'] as List?)?.whereType<Map>().toList() ?? [];
      for (final m in wps) {
        final id = m['id']?.toString() ?? '';
        final wp = _waypoints.firstWhere(
          (w) => w.id == id,
          orElse: () => _waypoints.first,
        );
        wp.enabled = (m['enabled'] == true);
        final lat = d(m['lat']), lon = d(m['lon']);
        if (lat != null && lon != null) {
          wp.lat.text = lat.toStringAsFixed(6);
          wp.lon.text = lon.toStringAsFixed(6);
        }
        final type = _typeFromName(m['patternType']?.toString());
        _patternTypeByWp[id] = type;
        final params = _paramsFromJson(m['params'] as Map<String, dynamic>?);
        _sarParamsByWp[id] = params;

        final pts = ptsFromJson(m['generatedPoints'] as List<dynamic>?);
        if (pts.isNotEmpty) {
          _sarPatternByWp[id] = pts;
        } else if (wp.enabled) {
          // regenerate if no stored geometry
          _generateSarFor(id);
        }
      }

      _syncWaypointFlagsFromList();
    });

    _validateAndDistance();
  }

  // Build ARGB color map for KML SAR styles
  Map<String, int> _sarArgbMap() {
    final m = <String, int>{};
    for (final id in _sarPatternByWp.keys) {
      final c = _sarColorFor(id);
      m[id] = c.toARGB32(); // ARGB 0xAARRGGBB
    }
    return m;
  }

  // ...existing code...

  // ---------- UI ----------
  // NEW: helper to manually apply AI suggestions when autoApplyAi = false
  void applyAiSuggestions() {
    setState(() {
      if (_aiSuggestedIas != null && _aiSuggestedIas!.isFinite) {
        cruiseSpeed = _aiSuggestedIas!;
        cruiseSpeedController.text = cruiseSpeed.toStringAsFixed(0);
      }
      if (_aiSuggestedAltitudeFt != null && _aiSuggestedAltitudeFt!.isFinite) {
        altitude = _aiSuggestedAltitudeFt!;
        altitudeController.text = altitude.toStringAsFixed(0);
      }
    });
  }

  Widget _buildSettingsDialog() {
    return AlertDialog(
      title: const Text('Settings'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            title: const Text('Auto-center map on aircraft'),
            value: _autoCenterEnabled,
            onChanged: (v) {
              setState(() => _autoCenterEnabled = v);
              Navigator.of(context).pop();
            },
          ),
          SwitchListTile(
            title: const Text('Heading Up (Map rotates with aircraft)'),
            value: _headingUp,
            onChanged: (v) {
              setState(() => _headingUp = v);
              Navigator.of(context).pop();
            },
          ),
          SwitchListTile(
            title: const Text('Simulate Aircraft (desktop/web)'),
            value: _simulateAircraft,
            onChanged: (v) {
              setState(() => _simulateAircraft = v);
              if (v) {
                _startSimulation();
              } else {
                _stopSimulation();
                _startGpsTracking();
              }
              Navigator.of(context).pop();
            },
          ),
          // Add more toggles here as you add features!
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AW139 Cruise Planner v4'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => _buildSettingsDialog(),
              );
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;

          final form = Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Row(
                      children: [
                        const Text(
                          'Aircraft: ',
                          style: TextStyle(color: Colors.white),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: _selectedAircraft,
                          dropdownColor: kPanelColor,
                          items: kAircraftOptions
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s,
                                  child: Text(
                                    s,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _selectedAircraft = v;
                              // Set reserve fuel default for selected aircraft
                              if (_selectedAircraft == 'Bell 412') {
                                reserveController.text = '390';
                                reserveFuel = 390;
                              } else {
                                reserveController.text = '184';
                                reserveFuel = 184;
                              }
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  buildInputField(
                    'Cruise Speed (knots)',
                    cruiseSpeedController,
                    readOnly: useWindsAloft && autoApplyAi,
                  ),
                  buildInputField(
                    'Mission Distance (NM)',
                    missionDistanceController,
                  ),
                  buildInputField(
                    'Altitude (ft)',
                    altitudeController,
                    readOnly: useWindsAloft && autoApplyAi,
                  ),
                  buildInputField('Temperature (°C)', temperatureController),

                  buildInputField(
                    "Fuel Onboard (${_selectedAircraft == 'Bell 412' ? 'lbs' : 'kg'})",
                    fuelController,
                  ),
                  buildInputField(
                    "Reserve Fuel (${_selectedAircraft == 'Bell 412' ? 'lbs' : 'kg'})",
                    reserveController,
                  ),
                  buildInputField('Hoist Time (min)', hoistTimeController),
                  const SizedBox(height: 16),
                  coordField(
                    'Origin Latitude',
                    originLatController,
                    isLat: true,
                    errorText: originLatError,
                  ),
                  coordField(
                    'Origin Longitude',
                    originLonController,
                    isLat: false,
                    errorText: originLonError,
                  ),
                  coordField(
                    'Destination Latitude',
                    destLatController,
                    isLat: true,
                    errorText: destLatError,
                  ),
                  coordField(
                    'Destination Longitude',
                    destLonController,
                    isLat: false,
                    errorText: destLonError,
                  ),
                  buildWaypointPlanner(),
                  // --- 4 toggles placed here ---
                  SwitchListTile(
                    title: const Text('Use device location for Origin'),
                    value: useDeviceLocation,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) async {
                      setState(() => useDeviceLocation = v);
                      if (v) {
                        final pos = await getCurrentPosition();
                        if (pos != null) {
                          originLatController.text =
                              '${pos.latitude.abs().toStringAsFixed(6)}${pos.latitude >= 0 ? 'N' : 'S'}';
                          originLonController.text =
                              '${pos.longitude.abs().toStringAsFixed(6)}${pos.longitude >= 0 ? 'E' : 'W'}';
                          _validateAndDistance();
                        }
                      }
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Auto distance from coordinates'),
                    value: autoDistanceFromLatLon,
                    onChanged: (v) =>
                        setState(() => autoDistanceFromLatLon = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Use Winds Aloft'),
                    value: useWindsAloft,
                    onChanged: (v) {
                      setState(() {
                        useWindsAloft = v;
                        if (v) {
                          standardWinds = false;
                        }
                      });
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Auto-center map on aircraft'),
                    value: _autoCenterEnabled,
                    onChanged: (v) => setState(() => _autoCenterEnabled = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Simulate Aircraft (desktop/web)'),
                    value: _simulateAircraft,
                    onChanged: (v) {
                      setState(() => _simulateAircraft = v);
                      if (v) {
                        _startSimulation();
                      } else {
                        _stopSimulation();
                        _startGpsTracking();
                      }
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Auto-center map on aircraft'),
                    value: _autoCenterEnabled,
                    onChanged: (v) => setState(() => _autoCenterEnabled = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Heading Up (Map rotates with aircraft)'),
                    value: _headingUp,
                    onChanged: (v) => setState(() => _headingUp = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Show Mission Map & Weather'),
                    value: showMap,
                    onChanged: (v) => setState(() => showMap = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Create waypoint from radial/distance'),
                    value: showNavTool,
                    onChanged: (v) => setState(() => showNavTool = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  // Wind provider selector (styled to match other controls)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Row(
                      children: [
                        const Text(
                          'Wind Provider: ',
                          style: TextStyle(color: Colors.white),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<WindProvider>(
                          value: _windProvider,
                          dropdownColor: kPanelColor,
                          items: _windProviderNames.entries
                              .map(
                                (entry) => DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(
                                    entry.value,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _windProvider = v);
                          },
                        ),
                        const SizedBox(width: 8),
                        if (_windProvider == WindProvider.windy &&
                            kWindyApiKey.isEmpty)
                          const Text(
                            '(set kWindyApiKey in code)',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                      ],
                    ),
                  ),
                  // AI objective selector
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AI Objective',
                          style: TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 6),
                        ToggleButtons(
                          isSelected: [
                            _objective == OptimizationObjective.minFuel,
                            _objective == OptimizationObjective.minTime,
                            _objective == OptimizationObjective.hybrid,
                          ],
                          onPressed: (i) {
                            setState(() {
                              switch (i) {
                                case 0:
                                  _objective = OptimizationObjective.minFuel;
                                  break;
                                case 1:
                                  _objective = OptimizationObjective.minTime;
                                  break;
                                case 2:
                                  _objective = OptimizationObjective.hybrid;
                                  break;
                              }
                            });
                            // Optional: auto-recalculate when objective changes
                            if (useWindsAloft &&
                                !standardWinds &&
                                !_calculating) {
                              setState(() => _calculating = true);
                              unawaited(
                                calculateCruise().whenComplete(() {
                                  if (!mounted) return;
                                  setState(() => _calculating = false);
                                }),
                              );
                            }
                          },
                          borderRadius: const BorderRadius.all(
                            Radius.circular(6),
                          ),
                          selectedColor: Colors.black,
                          fillColor: Colors.cyanAccent,
                          color: Colors.white70,
                          children: const [
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text('Min Fuel'),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text('Min Time'),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text('Hybrid'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_objective == OptimizationObjective.hybrid)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Time weight: ${_timeWeightKgPerMin.toStringAsFixed(2)} kg/min',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          Slider(
                            value: _timeWeightKgPerMin,
                            min: 0.0,
                            max: 2.0, // 0–2 kg per minute (0–120 kg/h)
                            divisions: 40,
                            label:
                                '${_timeWeightKgPerMin.toStringAsFixed(2)} kg/min',
                            onChanged: (v) {
                              setState(() => _timeWeightKgPerMin = v);
                            },
                          ),
                        ],
                      ),
                    ),

                  // ...after the AI objective selector (and optional slider)...
                  if (showMap)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.map),
                        label: const Text('View Mission Map'),
                        onPressed: () {
                          showDialog<void>(
                            context: context,
                            builder: (dialogContext) {
                              // --- MapWidget (build once, outside widget tree) ---
                              Widget mapWidget = FlutterMap(
                                mapController: _mapController,
                                options: MapOptions(
                                  initialCenter: _safeMapCenter(),
                                  initialZoom: 8,
                                  onTap: (tapPos, latlng) {
                                    final latDms = _formatDms(
                                      latlng.latitude,
                                      isLat: true,
                                    );
                                    final lonDms = _formatDms(
                                      latlng.longitude,
                                      isLat: false,
                                    );
                                    setState(() {
                                      switch (_mapEditTarget) {
                                        case 'origin':
                                          originLatController.text = latDms;
                                          originLonController.text = lonDms;
                                          break;
                                        case 'dest':
                                          destLatController.text = latDms;
                                          destLonController.text = lonDms;
                                          break;
                                        case 'hospital':
                                          hospitalLatController.text = latDms;
                                          hospitalLonController.text = lonDms;
                                          for (final wp in _waypoints) {
                                            if (wp.id == 'hospital') {
                                              wp.enabled = true;
                                            }
                                          }
                                          useHospitalWaypoint = true;
                                          break;
                                        case 'wpt1':
                                          waypoint1LatController.text = latDms;
                                          waypoint1LonController.text = lonDms;
                                          for (final wp in _waypoints) {
                                            if (wp.id == 'wpt1') {
                                              wp.enabled = true;
                                            }
                                          }
                                          useWaypoint1 = true;
                                          break;
                                        case 'wpt2':
                                          waypoint2LatController.text = latDms;
                                          waypoint2LonController.text = lonDms;
                                          for (final wp in _waypoints) {
                                            if (wp.id == 'wpt2') {
                                              wp.enabled = true;
                                            }
                                          }
                                          useWaypoint2 = true;
                                          break;
                                      }
                                      _validateAndDistance();
                                    });
                                  },
                                ),
                                children: [
                                  TileLayer(
                                    urlTemplate:
                                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                    userAgentPackageName:
                                        'com.example.aw139_cruise',
                                  ),
                                  Opacity(
                                    opacity: 0.7,
                                    child: TileLayer(
                                      urlTemplate:
                                          'https://tile.openweathermap.org/map/clouds_new/{z}/{x}/{y}.png?appid=$kOpenWeatherApiKey',
                                    ),
                                  ),
                                  Opacity(
                                    opacity: 0.6,
                                    child: TileLayer(
                                      urlTemplate:
                                          'https://tile.openweathermap.org/map/precipitation_new/{z}/{x}/{y}.png?appid=$kOpenWeatherApiKey',
                                    ),
                                  ),
                                  Opacity(
                                    opacity: 0.8,
                                    child: TileLayer(
                                      urlTemplate:
                                          'https://tile.openweathermap.org/map/wind_new/{z}/{x}/{y}.png?appid=$kOpenWeatherApiKey',
                                    ),
                                  ),
                                  // SAR polylines per waypoint (colored)
                                  PolylineLayer(
                                    polylines: _buildSarPolylines(),
                                  ),
                                  // Main route polyline (with SAR pattern expansion)
                                  PolylineLayer(
                                    polylines: [
                                      Polyline(
                                        points: () {
                                          final pts = <LatLng>[];
                                          final oLat = _parseCoord(
                                            originLatController.text,
                                            isLat: true,
                                          );
                                          final oLon = _parseCoord(
                                            originLonController.text,
                                            isLat: false,
                                          );
                                          final dLat = _parseCoord(
                                            destLatController.text,
                                            isLat: true,
                                          );
                                          final dLon = _parseCoord(
                                            destLonController.text,
                                            isLat: false,
                                          );
                                          if (oLat.isFinite && oLon.isFinite) {
                                            pts.add(LatLng(oLat, oLon));
                                          }
                                          for (final wp in _waypoints) {
                                            if (!wp.enabled) continue;
                                            final wLat = _parseCoord(
                                              wp.lat.text,
                                              isLat: true,
                                            );
                                            final wLon = _parseCoord(
                                              wp.lon.text,
                                              isLat: false,
                                            );
                                            if (wLat.isFinite &&
                                                wLon.isFinite) {
                                              final anchor = LatLng(wLat, wLon);
                                              pts.add(anchor);
                                              _appendPatternIfAny(
                                                pts,
                                                wp.id,
                                                anchor,
                                              );
                                            }
                                          }
                                          if (dLat.isFinite && dLon.isFinite) {
                                            pts.add(LatLng(dLat, dLon));
                                          }
                                          return pts;
                                        }(),
                                        color: Colors.blue,
                                        strokeWidth: 4,
                                      ),
                                    ],
                                  ),
                                  // SAR arrows
                                  MarkerLayer(markers: _sarArrowMarkers()),
                                  // SAR labels
                                  MarkerLayer(
                                    markers: showSarLabels
                                        ? _buildSarLabelMarkers()
                                        : const <Marker>[],
                                  ),
                                  // Origin/waypoints/destination pins
                                  MarkerLayer(
                                    markers: () {
                                      final ms = <Marker>[];
                                      final oLat = _parseCoord(
                                        originLatController.text,
                                        isLat: true,
                                      );
                                      final oLon = _parseCoord(
                                        originLonController.text,
                                        isLat: false,
                                      );
                                      final dLat = _parseCoord(
                                        destLatController.text,
                                        isLat: true,
                                      );
                                      final dLon = _parseCoord(
                                        destLonController.text,
                                        isLat: false,
                                      );
                                      if (oLat.isFinite && oLon.isFinite) {
                                        ms.add(
                                          Marker(
                                            point: LatLng(oLat, oLon),
                                            width: 30,
                                            height: 30,
                                            child: const Icon(
                                              Icons.location_on,
                                              color: Colors.green,
                                            ),
                                          ),
                                        );
                                      }
                                      for (final wp in _waypoints) {
                                        if (!wp.enabled) continue;
                                        final wLat = _parseCoord(
                                          wp.lat.text,
                                          isLat: true,
                                        );
                                        final wLon = _parseCoord(
                                          wp.lon.text,
                                          isLat: false,
                                        );
                                        if (!wLat.isFinite || !wLon.isFinite) {
                                          continue;
                                        }
                                        ms.add(
                                          Marker(
                                            point: LatLng(wLat, wLon),
                                            width: 28,
                                            height: 28,
                                            child: wp.id == 'hospital'
                                                ? const Icon(
                                                    Icons.local_hospital,
                                                    color: Colors.pink,
                                                  )
                                                : const Icon(
                                                    Icons.location_searching,
                                                    color: Colors.cyan,
                                                  ),
                                          ),
                                        );
                                      }
                                      if (dLat.isFinite && dLon.isFinite) {
                                        ms.add(
                                          Marker(
                                            point: LatLng(dLat, dLon),
                                            width: 30,
                                            height: 30,
                                            child: const Icon(
                                              Icons.flag,
                                              color: Colors.red,
                                            ),
                                          ),
                                        );
                                      }
                                      return ms;
                                    }(),
                                  ),
                                  // Wind arrows at origin/dest
                                  MarkerLayer(
                                    markers: () {
                                      final ms = <Marker>[];
                                      final oLat = _parseCoord(
                                        originLatController.text,
                                        isLat: true,
                                      );
                                      final oLon = _parseCoord(
                                        originLonController.text,
                                        isLat: false,
                                      );
                                      final dLat = _parseCoord(
                                        destLatController.text,
                                        isLat: true,
                                      );
                                      final dLon = _parseCoord(
                                        destLonController.text,
                                        isLat: false,
                                      );
                                      if (oLat.isFinite && oLon.isFinite) {
                                        ms.addAll(
                                          _buildWindArrowMarkers(
                                            'origin',
                                            oLat,
                                            oLon,
                                            alt: altitude,
                                          ),
                                        );
                                      }
                                      if (dLat.isFinite && dLon.isFinite) {
                                        ms.addAll(
                                          _buildWindArrowMarkers(
                                            'dest',
                                            dLat,
                                            dLon,
                                            alt: altitude,
                                          ),
                                        );
                                      }
                                      return ms;
                                    }(),
                                  ),
                                  // PNR pin
                                  MarkerLayer(markers: _buildPnrMarkers()),
                                  // Aircraft icon (live or simulated)
                                  MarkerLayer(
                                    markers: [
                                      if (_aircraftPosition != null)
                                        Marker(
                                          point:
                                              _aircraftAnimFrom != null &&
                                                  _aircraftAnimTo != null
                                              ? LatLng(
                                                  _aircraftAnimFrom!.latitude +
                                                      (_aircraftAnimTo!
                                                                  .latitude -
                                                              _aircraftAnimFrom!
                                                                  .latitude) *
                                                          _aircraftAnimT,
                                                  _aircraftAnimFrom!.longitude +
                                                      (_aircraftAnimTo!
                                                                  .longitude -
                                                              _aircraftAnimFrom!
                                                                  .longitude) *
                                                          _aircraftAnimT,
                                                )
                                              : _aircraftPosition!,
                                          width: 40,
                                          height: 40,
                                          child: Transform.rotate(
                                            angle: _degToRad(_aircraftHeading),
                                            child: const Icon(
                                              Icons.airplanemode_active,
                                              color: Colors.amber,
                                              size: 36,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              );
                              if (_headingUp && _aircraftHeading.isFinite) {
                                mapWidget = Transform.rotate(
                                  angle: -_degToRad(_aircraftHeading),
                                  child: mapWidget,
                                );
                              }

                              return Dialog(
                                insetPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                child: SizedBox(
                                  width: 900,
                                  height: 640,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      children: [
                                        // Edit bar
                                        Container(
                                          color: kPanelColor,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              const Text(
                                                'Edit target:',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              DropdownButton<String>(
                                                value: _mapEditTarget,
                                                dropdownColor: kPanelColor,
                                                items: const [
                                                  DropdownMenuItem(
                                                    value: 'origin',
                                                    child: Text(
                                                      'Origin',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 'hospital',
                                                    child: Text(
                                                      'Hospital',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 'wpt1',
                                                    child: Text(
                                                      'Waypoint 1',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 'wpt2',
                                                    child: Text(
                                                      'Waypoint 2',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 'dest',
                                                    child: Text(
                                                      'Destination',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                                onChanged: (v) => setState(
                                                  () => _mapEditTarget =
                                                      v ?? 'wpt1',
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              const Text(
                                                'Tip: Tap map to place/move selection',
                                                style: TextStyle(
                                                  color: Colors.white70,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Checkbox(
                                                    value: showSarLabels,
                                                    onChanged: (v) => setState(
                                                      () => showSarLabels =
                                                          v ?? true,
                                                    ),
                                                    materialTapTargetSize:
                                                        MaterialTapTargetSize
                                                            .shrinkWrap,
                                                  ),
                                                  const Text(
                                                    'Labels',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Checkbox(
                                                    value: includeSarInPnr,
                                                    onChanged: (v) => setState(
                                                      () => includeSarInPnr =
                                                          v ?? true,
                                                    ),
                                                    materialTapTargetSize:
                                                        MaterialTapTargetSize
                                                            .shrinkWrap,
                                                  ),
                                                  const Text(
                                                    'PNR includes SAR',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const Spacer(),
                                              TextButton(
                                                onPressed: () => Navigator.of(
                                                  dialogContext,
                                                ).pop(),
                                                child: const Text('Close'),
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Map + overlays
                                        Expanded(
                                          child: Stack(
                                            children: [
                                              mapWidget,

                                              // SAR legend (top-right)
                                              Positioned(
                                                right: 8,
                                                top: 8,
                                                child: Builder(
                                                  builder: (_) {
                                                    if (_sarPatternByWp
                                                        .isEmpty) {
                                                      return const SizedBox.shrink();
                                                    }
                                                    final ids = _sarPatternByWp
                                                        .keys
                                                        .toList();
                                                    return Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 10,
                                                            vertical: 6,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      child: Wrap(
                                                        spacing: 10,
                                                        runSpacing: 6,
                                                        children: ids.map((id) {
                                                          return Row(
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              Container(
                                                                width: 10,
                                                                height: 10,
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      _sarColorFor(
                                                                        id,
                                                                      ),
                                                                  shape: BoxShape
                                                                      .circle,
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                width: 6,
                                                              ),
                                                              Text(
                                                                id.toUpperCase(),
                                                                style: const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                ),
                                                              ),
                                                            ],
                                                          );
                                                        }).toList(),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),

                                              // Live total distance + track overlay
                                              Positioned(
                                                left: 8,
                                                bottom: 8,
                                                child: Builder(
                                                  builder: (_) {
                                                    final pts = <LatLng>[];
                                                    final oLat = _parseCoord(
                                                      originLatController.text,
                                                      isLat: true,
                                                    );
                                                    final oLon = _parseCoord(
                                                      originLonController.text,
                                                      isLat: false,
                                                    );
                                                    final dLat = _parseCoord(
                                                      destLatController.text,
                                                      isLat: true,
                                                    );
                                                    final dLon = _parseCoord(
                                                      destLonController.text,
                                                      isLat: false,
                                                    );
                                                    if (oLat.isFinite &&
                                                        oLon.isFinite) {
                                                      pts.add(
                                                        LatLng(oLat, oLon),
                                                      );
                                                    }
                                                    for (final wp
                                                        in _waypoints) {
                                                      if (!wp.enabled) continue;
                                                      final wLat = _parseCoord(
                                                        wp.lat.text,
                                                        isLat: true,
                                                      );
                                                      final wLon = _parseCoord(
                                                        wp.lon.text,
                                                        isLat: false,
                                                      );
                                                      if (wLat.isFinite &&
                                                          wLon.isFinite) {
                                                        final anchor = LatLng(
                                                          wLat,
                                                          wLon,
                                                        );
                                                        pts.add(anchor);
                                                        _appendPatternIfAny(
                                                          pts,
                                                          wp.id,
                                                          anchor,
                                                        );
                                                      }
                                                    }
                                                    if (dLat.isFinite &&
                                                        dLon.isFinite) {
                                                      pts.add(
                                                        LatLng(dLat, dLon),
                                                      );
                                                    }
                                                    double total = 0.0;
                                                    if (pts.length >= 2) {
                                                      for (
                                                        int i = 0;
                                                        i < pts.length - 1;
                                                        i++
                                                      ) {
                                                        total += _gcDistanceNm(
                                                          pts[i].latitude,
                                                          pts[i].longitude,
                                                          pts[i + 1].latitude,
                                                          pts[i + 1].longitude,
                                                        );
                                                      }
                                                    }
                                                    final track =
                                                        (pts.length >= 2)
                                                        ? _initialBearingDeg(
                                                            pts.first.latitude,
                                                            pts.first.longitude,
                                                            pts.last.latitude,
                                                            pts.last.longitude,
                                                          ).toStringAsFixed(0)
                                                        : '--';
                                                    final pnrVal = _pnrNm;
                                                    final showPnr =
                                                        pnrVal != null &&
                                                        pnrVal > 0;
                                                    final pnrText = showPnr
                                                        ? '   PNR: ${pnrVal.toStringAsFixed(0)} NM'
                                                        : '';
                                                    return Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 10,
                                                            vertical: 6,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        'Route: ${total.toStringAsFixed(0)} NM   Track: $track°$pnrText',
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  // Toggle to open the radial/distance → waypoint tool
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Visibility(
                        visible: showNavTool,
                        maintainState: true,
                        child: Card(
                          color: kPanelColor,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'From known fix + radial/distance',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: DropdownButton<int>(
                                        value: _selectedFixIndex,
                                        isExpanded: true,
                                        dropdownColor: kPanelColor,
                                        items: [
                                          for (
                                            int i = 0;
                                            i < kNavFixes.length;
                                            i++
                                          )
                                            DropdownMenuItem(
                                              value: i,
                                              child: Text(
                                                kNavFixes[i].name,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          const DropdownMenuItem(
                                            value: -1,
                                            child: Text(
                                              'Custom lat/lon…',
                                              style: TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ],
                                        onChanged: (v) => setState(
                                          () => _selectedFixIndex = v ?? 0,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 90,
                                      child: TextField(
                                        controller: _navRadialController,
                                        decoration: const InputDecoration(
                                          labelText: 'Radial',
                                          hintText: '0-360',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        keyboardType: TextInputType.number,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 120,
                                      child: TextField(
                                        controller: _navDistanceController,
                                        decoration: const InputDecoration(
                                          labelText: 'Distance (NM)',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        keyboardType: TextInputType.number,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      onPressed: _computeNavFixPoint,
                                      icon: const Icon(Icons.calculate),
                                      label: const Text('Compute'),
                                    ),
                                  ],
                                ),
                                (_selectedFixIndex == _customBaseIndex)
                                    ? Padding(
                                        padding: const EdgeInsets.only(
                                          top: 8.0,
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: TextField(
                                                controller:
                                                    _navBaseLatController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Base Latitude',
                                                  hintText:
                                                      'e.g. 34 52 20 N or 34.8722',
                                                  isDense: true,
                                                  border: OutlineInputBorder(),
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: TextField(
                                                controller:
                                                    _navBaseLonController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Base Longitude',
                                                  hintText:
                                                      'e.g. 033 37 28 E or 33.6244',
                                                  isDense: true,
                                                  border: OutlineInputBorder(),
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        readOnly: true,
                                        controller: _navOutLatController,
                                        decoration: const InputDecoration(
                                          labelText: 'Latitude (DMS)',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        readOnly: true,
                                        controller: _navOutLonController,
                                        decoration: const InputDecoration(
                                          labelText: 'Longitude (DMS)',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.copy),
                                      label: const Text('Copy Lat'),
                                      onPressed: () => Clipboard.setData(
                                        ClipboardData(
                                          text: _navOutLatController.text,
                                        ),
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.copy),
                                      label: const Text('Copy Lon'),
                                      onPressed: () => Clipboard.setData(
                                        ClipboardData(
                                          text: _navOutLonController.text,
                                        ),
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.call_made),
                                      label: const Text('Send to Hospital'),
                                      onPressed: () =>
                                          _applyNavResultTo('hospital'),
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.call_made),
                                      label: const Text('Send to WP1'),
                                      onPressed: () =>
                                          _applyNavResultTo('wpt1'),
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.call_made),
                                      label: const Text('Send to WP2'),
                                      onPressed: () =>
                                          _applyNavResultTo('wpt2'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      (useWindsAloft &&
                              !standardWinds &&
                              (_aiSuggestedIas != null ||
                                  _aiSuggestedAltitudeFt != null ||
                                  _aiTailwindKts != null))
                          ? Card(
                              color: Colors.blueGrey.shade800,
                              margin: const EdgeInsets.symmetric(vertical: 8),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'AI Flight Optimization',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.cyanAccent,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    if (_aiSuggestedIas != null)
                                      Text(
                                        'Suggested IAS: ${_aiSuggestedIas?.toStringAsFixed(0) ?? '--'} kt',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    if (_aiSuggestedAltitudeFt != null)
                                      Text(
                                        'Suggested Altitude: ${_aiSuggestedAltitudeFt?.toStringAsFixed(0) ?? '--'} ft',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    // show per‑leg suggested altitudes when available (prevents unused-field warnings)
                                    if (_aiSuggestedAltitudeOutFt != null)
                                      Text(
                                        'Suggested Out Altitude: ${_aiSuggestedAltitudeOutFt?.toStringAsFixed(0) ?? '--'} ft',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                    if (_aiSuggestedAltitudeBackFt != null)
                                      Text(
                                        'Suggested Back Altitude: ${_aiSuggestedAltitudeBackFt?.toStringAsFixed(0) ?? '--'} ft',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                    if (_aiTailwindOutKts != null &&
                                        _aiTailwindBackKts != null)
                                      Builder(
                                        builder: (_) {
                                          final out = _aiTailwindOutKts!;
                                          final back = _aiTailwindBackKts!;
                                          final avg = (out + back) / 2.0;
                                          return Text(
                                            '${_formatTailOrHead(out)} (Out) / ${_formatTailOrHead(back)} (Back)  (Avg ${avg.abs().toStringAsFixed(0)} kt)',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                            ),
                                          );
                                        },
                                      ),
                                    const SizedBox(height: 16),
                                    // ...existing code...
                                    // ...existing code...
                                    if (!autoApplyAi)
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton.icon(
                                          onPressed:
                                              (_aiSuggestedIas == null &&
                                                  _aiSuggestedAltitudeFt ==
                                                      null)
                                              ? null
                                              : applyAiSuggestions,
                                          icon: const Icon(
                                            Icons.check_circle,
                                            color: Colors.cyanAccent,
                                            size: 18,
                                          ),
                                          label: const Text(
                                            'Apply Suggestions',
                                            style: TextStyle(
                                              color: Colors.cyanAccent,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ],
                  ),

                  buildEquipmentToggles(
                    context,
                    searchlight,
                    radar,
                    flir,
                    hoist,
                    selectAllOptional,
                    (v) => setState(() => searchlight = v),
                    (v) => setState(() => radar = v),
                    (v) => setState(() => flir = v),
                    (v) => setState(() => hoist = v),
                    (v) {
                      setState(() {
                        selectAllOptional = v;
                        searchlight = radar = flir = hoist = v;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _calculating
                                  ? null
                                  : () async {
                                      setState(() => _calculating = true);
                                      try {
                                        await calculateCruise(); // default roundTrip = true
                                      } finally {
                                        if (mounted) {
                                          setState(() => _calculating = false);
                                        }
                                      }
                                    },
                              child: _calculating
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                  : const Text('Calculate'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _calculating
                                  ? null
                                  : () async {
                                      setState(() => _calculating = true);
                                      try {
                                        await calculateCruise(
                                          roundTrip: false,
                                        ); // single-trip
                                      } finally {
                                        if (mounted) {
                                          setState(() => _calculating = false);
                                        }
                                      }
                                    },
                              child: _calculating
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                  : const Text('Single-Trip'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  // ...existing code...
                  // ...existing code...
                  ElevatedButton.icon(
                    icon: const Icon(Icons.air),
                    label: const Text('Show Winds Aloft'),
                    onPressed: () async {
                      // parse coords
                      final originLat = _parseCoord(
                        originLatController.text,
                        isLat: true,
                      );
                      final originLon = _parseCoord(
                        originLonController.text,
                        isLat: false,
                      );
                      final destLat = _parseCoord(
                        destLatController.text,
                        isLat: true,
                      );
                      final destLon = _parseCoord(
                        destLonController.text,
                        isLat: false,
                      );

                      if (!(originLat.isFinite && originLon.isFinite)) {
                        // nothing to fetch
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Enter valid origin coordinates first',
                            ),
                          ),
                        );
                        return;
                      }

                      final trackDeg =
                          (originLat.isFinite &&
                              originLon.isFinite &&
                              destLat.isFinite &&
                              destLon.isFinite)
                          ? _initialBearingDeg(
                              originLat,
                              originLon,
                              destLat,
                              destLon,
                            )
                          : 0.0;

                      // Fetch origin winds (and destination if valid) and store copies for the dialog
                      try {
                        await fetchAiAltitudeSuggestion(
                          lat: originLat,
                          lon: originLon,
                          trackDeg: trackDeg,
                          storeKey: 'origin',
                        );
                        _departureWindsAloft = _aiWindsAloft;
                        if (destLat.isFinite && destLon.isFinite) {
                          await fetchAiAltitudeSuggestion(
                            lat: destLat,
                            lon: destLon,
                            trackDeg: trackDeg,
                            storeKey: 'dest',
                          );
                          _destinationWindsAloft = _aiWindsAloft;
                        }
                      } catch (e) {
                        if (kDebugMode) debugPrint('ShowWinds fetch error: $e');
                      }
                      // Safe to use context after awaits
                      if (!context.mounted) return;
                      // show dialog exactly like before (reuses buildProfileView already used in file)

                      // show dialog exactly like before (reuses buildProfileView already used in file)
                      showDialog<void>(
                        context: context,
                        builder: (BuildContext dialogContext) {
                          Widget buildProfileView(
                            String title,
                            Map<int, Map<String, dynamic>>? profile,
                          ) {
                            if (profile == null || profile.isEmpty) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text('No winds aloft data available'),
                                ],
                              );
                            }
                            final entries = profile.entries.toList()
                              ..sort((a, b) => a.key.compareTo(b.key));
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                for (final e in entries)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 2,
                                    ),
                                    child: Text(
                                      '${e.key} ft (${e.value['pressure'] ?? '--'} hPa): raw ${(_numToDouble(e.value['rawSpeedMps']) * 1.94384449).toStringAsFixed(1)} kt @ ${_numToDouble(e.value['dir']).toStringAsFixed(0)}° — ${_formatTailOrHead(_numToDouble(e.value['tailwind']))}',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Note: Anchors above are the raw API levels. Interpolated display altitudes are shown below.',
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 6,
                                  children:
                                      (entries.isNotEmpty
                                              ? entries
                                                    .map((e) => e.key)
                                                    .toList()
                                              : <int>[2000, 4000, 6000])
                                          .map((da) {
                                            final tailMap = {
                                              for (final kv in profile.entries)
                                                kv.key: _numToDouble(
                                                  kv.value['tailwind'],
                                                ),
                                            };
                                            final val = getOrInterpolateWind(
                                              da,
                                              tailMap,
                                            );
                                            return Chip(
                                              backgroundColor: kPanelColor,
                                              label: Text(
                                                '$da ft: ${val.toStringAsFixed(0)} kt',
                                              ),
                                            );
                                          })
                                          .toList(),
                                ),
                              ],
                            );
                          }

                          return Dialog(
                            insetPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            child: SizedBox(
                              width: 1000,
                              height: 640,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Winds Aloft',
                                        style: Theme.of(
                                          dialogContext,
                                        ).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 8),
                                      buildProfileView(
                                        'Departure Winds Aloft',
                                        _departureWindsAloft,
                                      ),
                                      const SizedBox(height: 12),
                                      buildProfileView(
                                        'Destination Winds Aloft',
                                        _destinationWindsAloft,
                                      ),
                                      const SizedBox(height: 12),
                                      const Text(
                                        'Surface = 10m wind. Press Close when done.',
                                      ),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            TextButton.icon(
                                              icon: const Icon(Icons.print),
                                              label: const Text('Print'),
                                              onPressed: () {
                                                Map<int, double>? toTailwindMap(
                                                  Map<int, Map<String, double>>?
                                                  src,
                                                ) {
                                                  if (src == null) return null;
                                                  return src.map(
                                                    (alt, m) => MapEntry(
                                                      alt,
                                                      (m['tailwind'] ?? 0.0),
                                                    ),
                                                  );
                                                }

                                                CruiseReportExporter.previewWindsOnly(
                                                  departure: toTailwindMap(
                                                    _departureWindsAloft,
                                                  ),
                                                  destination: toTailwindMap(
                                                    _destinationWindsAloft,
                                                  ),
                                                );
                                              },
                                            ),
                                            const SizedBox(width: 8),
                                            TextButton(
                                              onPressed: () => Navigator.of(
                                                dialogContext,
                                              ).pop(),
                                              child: const Text('Close'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),

                  // ...existing code...
                  // ...existing code...
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _lastReport == null
                              ? null
                              : () {
                                  CruiseReportExporter.preview(_lastReport!);
                                },
                          icon: const Icon(Icons.print),
                          label: const Text('PDF / Print'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _lastReport == null
                              ? null
                              : () {
                                  CruiseReportExporter.share(
                                    context,
                                    _lastReport!,
                                  );
                                },
                          icon: const Icon(Icons.share),
                          label: const Text('Share'),
                        ),
                      ),
                      const SizedBox(width: 8),

                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(
                              context,
                            ); // cache before awaits

                            // route with SAR expansion
                            final pts = <LatLng>[];
                            final oLat = _parseCoord(
                              originLatController.text,
                              isLat: true,
                            );
                            final oLon = _parseCoord(
                              originLonController.text,
                              isLat: false,
                            );
                            final dLat = _parseCoord(
                              destLatController.text,
                              isLat: true,
                            );
                            final dLon = _parseCoord(
                              destLonController.text,
                              isLat: false,
                            );
                            if (oLat.isFinite && oLon.isFinite) {
                              pts.add(LatLng(oLat, oLon));
                            }
                            for (final wp in _waypoints) {
                              if (!wp.enabled) continue;
                              final wLat = _parseCoord(
                                wp.lat.text,
                                isLat: true,
                              );
                              final wLon = _parseCoord(
                                wp.lon.text,
                                isLat: false,
                              );
                              if (wLat.isFinite && wLon.isFinite) {
                                final anchor = LatLng(wLat, wLon);
                                pts.add(anchor);
                                _appendPatternIfAny(pts, wp.id, anchor);
                              }
                            }
                            if (dLat.isFinite && dLon.isFinite) {
                              pts.add(LatLng(dLat, dLon));
                            }
                            if (pts.length < 2) {
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('Enter valid route first'),
                                ),
                              );
                              return;
                            }

                            // Build KML with a separate SAR folder
                            final kml = RouteExportKml.buildKmlWithSar(
                              pts,
                              name: 'AW139 Mission',
                              sarPatterns: _sarPatternByWp,
                              sarColorArgbById: _sarArgbMap(),
                            );

                            final saveLocation = await getSaveLocation(
                              suggestedName: 'route.kml',
                              acceptedTypeGroups: const [
                                XTypeGroup(label: 'KML', extensions: ['kml']),
                              ],
                            );
                            if (saveLocation == null) {
                              await Clipboard.setData(ClipboardData(text: kml));
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('KML copied to clipboard'),
                                ),
                              );
                              return;
                            }

                            final data = Uint8List.fromList(utf8.encode(kml));
                            final xfile = XFile.fromData(
                              data,
                              name: 'route.kml',
                              mimeType: 'application/vnd.google-earth.kml+xml',
                            );
                            await xfile.saveTo(saveLocation.path);
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('Saved: ${saveLocation.path}'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.route),
                          label: const Text('Export KML'),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: savePlanJson,
                          icon: const Icon(Icons.save),
                          label: const Text('Save Plan (JSON)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: loadPlanJson,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Load Plan (JSON)'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );

          // ...existing code...
          // local snapshot values for charts (avoid IIFE inside children)
          final isBell412 = _selectedAircraft == 'Bell 412';
          final chartTorque = _lastRequiredTorque ?? 0;

          // raw snapshots are in kg (internals)
          final chartBurnRaw = _lastAdjustedFuelBurn ?? 0; // kg/hr
          final chartFuelRemRaw = _lastFuelRemaining ?? 0; // kg

          // convert to display units for charts
          final chartBurn = isBell412 ? kgToLbs(chartBurnRaw) : chartBurnRaw;
          final chartFuelRem = isBell412
              ? kgToLbs(chartFuelRemRaw)
              : chartFuelRemRaw;

          // color thresholds in display units
          final fuelRedThresh = isBell412 ? kgToLbs(184) : 184.0;
          final fuelOrangeThresh = isBell412 ? kgToLbs(456) : 456.0;

          // ...existing code...
          final chartsPanel = Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
            child: (_lastRequiredTorque == null)
                ? const Text('Press Calculate to show charts')
                : SingleChildScrollView(
                    child: Column(
                      children: [
                        // Torque
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title: 'Torque %',
                            value: chartTorque,
                            color: Colors.orange,
                            maxY: 120,
                            unit: '%',
                            height: 320,
                          ),
                        ),
                        // Fuel Burn
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title:
                                'Fuel Burn\n(${isBell412 ? 'lbs/hr' : 'kg/hr'})',
                            value: chartBurn,
                            color: Colors.yellow,
                            maxY:
                                (chartBurn <= 0
                                        ? 100
                                        : (chartBurn / 100).ceil() * 100)
                                    .toDouble(),
                            unit: isBell412 ? 'lbs/hr' : 'kg/hr',
                            height: 320,
                          ),
                        ),
                        // Fuel Remaining
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title:
                                'Fuel\nRemaining (${isBell412 ? 'lbs' : 'kg'})',
                            value: chartFuelRem,
                            color: chartFuelRem <= fuelRedThresh
                                ? Colors.red
                                : (chartFuelRem <= fuelOrangeThresh
                                      ? Colors.orange
                                      : Colors.green),
                            maxY:
                                (chartFuelRem <= 0
                                        ? 100
                                        : (chartFuelRem / 100).ceil() * 100)
                                    .toDouble(),
                            unit: isBell412 ? 'lbs' : 'kg',
                            height: 320,
                          ),
                        ),
                      ],
                    ),
                  ),
          );
          // ...existing code...

          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: form),
                const VerticalDivider(width: 1),
                SizedBox(width: 420, child: chartsPanel),
              ],
            );
          }

          return SingleChildScrollView(
            child: Column(
              children: [form, const Divider(height: 1), chartsPanel],
            ),
          );
        },
      ),
    );
  }

  Map<String, double> windToUV(double speedMps, double dirFromDeg) {
    final rad = _degToRad(dirFromDeg);
    final u = -speedMps * math.sin(rad);
    final v = -speedMps * math.cos(rad);
    return {'u': u, 'v': v};
  }

  Map<String, double> uvToWind(double u, double v) {
    final speed = math.sqrt(u * u + v * v);
    final dirFromRad = math.atan2(-u, -v);
    final dirFromDeg = (_radToDeg(dirFromRad) + 360) % 360;
    return {'speed': speed, 'dirFrom': dirFromDeg};
  }

  int _aw139MinPerfAlt() {
    final keys = fuelBurnTables.keys.toList()..sort();
    return keys.isEmpty ? 0 : keys.first;
  }

  int _aw139MaxPerfAlt() {
    final keys = fuelBurnTables.keys.toList()..sort();
    return keys.isEmpty
        ? 6000
        : keys.last; // auto‑extends when you add 8000/10000
  }

  // Helper: lookup / interpolate Bell‑412 burn from loaded bh412Tables
  // Bilinear in (altitude, OAT) and linear in IAS. Tables are lbs/hr.
  double? _bh412GetBurn(int altitudeFt, int oatC, double iasKts) {
    if (bh412Tables.isEmpty) return null;

    // Bracket altitude
    final altKeys = bh412Tables.keys.toList()..sort();
    int a0 = altKeys.first, a1 = altKeys.last;
    if (altitudeFt <= altKeys.first) {
      a0 = altKeys.first;
      a1 = a0;
    } else if (altitudeFt >= altKeys.last) {
      a0 = altKeys.last;
      a1 = a0;
    } else {
      for (int i = 0; i < altKeys.length - 1; i++) {
        if (altitudeFt >= altKeys[i] && altitudeFt <= altKeys[i + 1]) {
          a0 = altKeys[i];
          a1 = altKeys[i + 1];
          break;
        }
      }
    }

    double interpIas(Map<int, double> row, double ias) {
      if (row.isEmpty) return double.nan;
      final sKeys = row.keys.toList()..sort();
      int s0 = sKeys.first, s1 = sKeys.last;
      if (ias <= sKeys.first) {
        s0 = sKeys.first;
        s1 = s0;
      } else if (ias >= sKeys.last) {
        s0 = sKeys.last;
        s1 = s0;
      } else {
        for (int i = 0; i < sKeys.length - 1; i++) {
          if (ias >= sKeys[i] && ias <= sKeys[i + 1]) {
            s0 = sKeys[i];
            s1 = sKeys[i + 1];
            break;
          }
        }
      }
      final v0 = (row[s0] ?? 0).toDouble();
      final v1 = (row[s1] ?? v0).toDouble();
      if (s0 == s1) return v0;
      final r = (ias - s0) / (s1 - s0);
      return v0 + (v1 - v0) * r;
    }

    double burnAtAlt(int alt) {
      final tempMap = bh412Tables[alt];
      if (tempMap == null || tempMap.isEmpty) return double.nan;

      // Bracket OAT
      final tKeys = tempMap.keys.toList()..sort();
      int t0 = tKeys.first, t1 = tKeys.last;
      if (oatC <= tKeys.first) {
        t0 = tKeys.first;
        t1 = t0;
      } else if (oatC >= tKeys.last) {
        t0 = tKeys.last;
        t1 = t0;
      } else {
        for (int i = 0; i < tKeys.length - 1; i++) {
          if (oatC >= tKeys[i] && oatC <= tKeys[i + 1]) {
            t0 = tKeys[i];
            t1 = tKeys[i + 1];
            break;
          }
        }
      }

      final row0 = Map<int, double>.from(tempMap[t0] ?? const <int, double>{});
      final row1 = Map<int, double>.from(tempMap[t1] ?? const <int, double>{});
      final b0 = interpIas(row0, iasKts);
      final b1 = interpIas(row1, iasKts);
      if (t0 == t1 || !b0.isFinite || !b1.isFinite) return b0;
      final rt = (oatC - t0) / (t1 - t0);
      return b0 + (b1 - b0) * rt;
    }

    final ba0 = burnAtAlt(a0);
    final ba1 = burnAtAlt(a1);
    if (a0 == a1 || !ba0.isFinite || !ba1.isFinite) {
      return ba0.isFinite ? ba0 : ba1;
    }

    final ra = (altitudeFt - a0) / (a1 - a0);
    return ba0 + (ba1 - ba0) * ra;
  }

  // ---------- IAS Suggestion ----------
  Map<String, double>? suggestBestIas({
    required int altFt,
    required int oatC,
    required double tailwindOutKts,
    required double tailwindBackKts,
    required double distanceNmOneWay,
    required OptimizationObjective objective,
    required double timeWeightKgPerMin,
  }) {
    // Use Bell-412 speed set when the user has selected that aircraft and we have tables.
    final List<int> candidates =
        (_selectedAircraft == 'Bell 412' && bh412Tables.isNotEmpty)
        ? <int>[100, 105, 110, 115, 120, 125]
        : <int>[120, 125, 130, 135, 140, 145, 150, 155, 160];
    double? bestFuel;
    Map<String, double>? best;
    for (final ias in candidates) {
      double? burnPerHr;
      if (_selectedAircraft == 'Bell 412' && bh412Tables.isNotEmpty) {
        burnPerHr = _bh412GetBurn(altFt, oatC, ias.toDouble());
        if (burnPerHr == null) continue;
      } else {
        final tq = getTorqueForIAS(altFt, oatC, ias.toDouble());
        burnPerHr = interpolateFuelBurn(tq, altFt, oatC);
      }
      final gsOut = (ias + tailwindOutKts).clamp(30, 220);
      final gsBack = (ias + tailwindBackKts).clamp(30, 220);
      final timeOut = distanceNmOneWay / gsOut;
      final timeBack = distanceNmOneWay / gsBack;
      final totalHrs = (timeOut + timeBack).clamp(0.01, 24.0);
      final fuel = burnPerHr * totalHrs;
      if (bestFuel == null || fuel < bestFuel) {
        bestFuel = fuel;
        best = {'ias': ias.toDouble(), 'fuel': fuel, 'time': totalHrs};
      }
    }
    return best;
  }

  // Load CSV (assets/performance_tables/bell_412.csv) into bh412Tables.
  // Expected CSV columns: altitude,oat,ias,burn
  Future<void> loadBh412TablesFromAsset() async {
    try {
      final s = await rootBundle.loadString(
        'assets/performance_tables/bell_412.csv',
      );
      final lines = s
          .split(RegExp(r'[\r\n]+'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      for (final ln in lines) {
        if (ln.startsWith('#')) continue;
        if (ln.toLowerCase().startsWith('altitude')) continue;
        final cols = ln.split(',').map((c) => c.trim()).toList();
        if (cols.length < 4) continue;
        final alt = int.tryParse(cols[0]);
        final oat = int.tryParse(cols[1]);
        final ias = int.tryParse(cols[2]);
        final burn = double.tryParse(cols[3]);
        if (alt == null || oat == null || ias == null || burn == null) continue;
        bh412Tables.putIfAbsent(alt, () => {});
        bh412Tables[alt]!.putIfAbsent(oat, () => {});
        bh412Tables[alt]![oat]![ias] = burn;
      }
      // ignore: avoid_print
      print('BH412: loaded ${bh412Tables.length} altitude rows');
    } catch (e) {
      // ignore: avoid_print
      print('BH412 load error: $e');
    }
  }

  // ...existing code...
  Future<void> fetchAiAltitudeSuggestion({
    required double lat,
    required double lon,
    required double trackDeg,
    String? storeKey, // optional key to keep the fetched profile
  }) async {
    try {
      Map<String, dynamic>? raw;
      // desired levels: surface + pressure levels (strings for Windy, ints for others)
      final desiredLevels = ['sfc', '950', '925', '900', '850', '800', '700'];

      if (_windProvider == WindProvider.windy && kWindyApiKey.isNotEmpty) {
        final windyLevels = desiredLevels.where((l) => l != 'sfc').join(',');
        final windyUri = Uri.parse(
          'https://api.windy.com/api/point-forecast/v2'
          '?lat=$lat&lon=$lon&model=gfs&levels=$windyLevels&parameters=wind',
        );
        final windyRes = await http.get(
          windyUri,
          headers: {'x-windy-key': kWindyApiKey, 'Accept': 'application/json'},
        );
        if (windyRes.statusCode == 200) {
          final wd = jsonDecode(windyRes.body) as Map<String, dynamic>;
          raw = {'provider': 'windy', 'data': wd};
          if (kDebugMode) debugPrint('RAW_WINDY: $raw');
        } else {
          // ignore: avoid_print
          print(
            'WINDY_FAIL status=${windyRes.statusCode}; falling back to Open‑Meteo',
          );
        }
      }

      if (raw == null) {
        // Open‑Meteo fallback
        final omParams = StringBuffer()
          ..write('&forecast_days=1')
          ..write('&hourly=')
          ..write('windspeed_10m,winddirection_10m');
        for (final lvl in desiredLevels) {
          if (lvl == 'sfc') continue;
          omParams.write(',wind_speed_${lvl}hPa,wind_direction_${lvl}hPa');
        }
        final uri = Uri.parse(
          'https://api.open-meteo.com/v1/forecast'
          '?latitude=$lat&longitude=$lon'
          '${omParams.toString()}',
        );
        final res = await http.get(uri);
        if (res.statusCode != 200) return;
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        raw = {'provider': 'openMeteo', 'data': data};
        if (kDebugMode) debugPrint('RAW_OPENMETEO: $raw');
      }

      // normalize -> level alt(ft) -> {tailwind, dir, pressure, rawSpeedMps}
      final Map<int, Map<String, double>> profile = {};

      if (raw['provider'] == 'windy') {
        final wd = raw['data'] as Map<String, dynamic>;
        final levels = (wd['levels'] is Map)
            ? wd['levels'] as Map<String, dynamic>
            : <String, dynamic>{};

        final available = levels.keys.toList();
        available.sort((a, b) {
          if (a == 'sfc') return -1;
          if (b == 'sfc') return 1;
          final ai = int.tryParse(a) ?? 0;
          final bi = int.tryParse(b) ?? 0;
          return ai.compareTo(bi);
        });

        for (final lvl in available) {
          final entry = levels[lvl] as Map<String, dynamic>?;
          if (entry == null) continue;
          Map<String, dynamic>? windMap = entry['wind'] is Map
              ? entry['wind'] as Map<String, dynamic>
              : null;
          double sp = 0.0, dir = 0.0;
          if (windMap != null) {
            sp = _numToDouble(
              windMap['speed'] ?? windMap['wind_speed'] ?? windMap['ws'],
            );
            dir = _numToDouble(
              windMap['direction'] ??
                  windMap['dir'] ??
                  windMap['wind_direction'],
            );
          } else {
            sp = _numToDouble(
              entry['speed'] ?? entry['wind_speed'] ?? entry['windSpeed'],
            );
            dir = _numToDouble(
              entry['direction'] ?? entry['dir'] ?? entry['wind_direction'],
            );
          }
          if (sp == 0 && dir == 0) continue;

          final pressure = (lvl == 'sfc') ? 0 : int.tryParse(lvl) ?? 0;
          final altFt = (pressure == 0)
              ? 0
              : pressureHpaToFeet(pressure.toDouble()).round();
          profile[altFt] = {
            'tailwind': _tailwindKts(sp, dir, trackDeg),
            'dir': dir,
            'pressure': pressure.toDouble(),
            'rawSpeedMps': sp,
          };
        }
      } else {
        final data = raw['data'] as Map<String, dynamic>;
        final h = (data['hourly'] ?? {}) as Map<String, dynamic>;

        final sSp = _numToDouble(
          h['windspeed_10m'] != null
              ? (h['windspeed_10m']?[0])
              : (h['wind_speed_10m']?[0]),
        );
        final sDr = _numToDouble(
          h['winddirection_10m'] != null
              ? (h['winddirection_10m']?[0])
              : (h['wind_direction_10m']?[0]),
        );
        if (sSp != 0 || sDr != 0) {
          profile[0] = {
            'tailwind': _tailwindKts(sSp, sDr, trackDeg),
            'dir': sDr,
            'pressure': 0.0,
            'rawSpeedMps': sSp,
          };
        }

        final presentLevels = <int>{};
        for (final k in h.keys) {
          final m = RegExp(r'wind_speed_(\d+)hPa').firstMatch(k);
          if (m != null) {
            final p = int.tryParse(m.group(1) ?? '');
            if (p != null) presentLevels.add(p);
          }
        }
        final levelsToUse = <String>[];
        if (presentLevels.isNotEmpty) {
          final sorted = presentLevels.toList()..sort();
          for (final p in sorted) {
            levelsToUse.add(p.toString());
          }
        } else {
          levelsToUse.addAll(desiredLevels.where((l) => l != 'sfc'));
        }

        for (final lvl in levelsToUse) {
          final keySp = 'wind_speed_${lvl}hPa';
          final keyDr = 'wind_direction_${lvl}hPa';
          final spArr = h[keySp];
          final drArr = h[keyDr];
          final spRaw = (spArr is List && spArr.isNotEmpty)
              ? _numToDouble(spArr[0])
              : _numToDouble(spArr);
          final sp = spRaw / 3.6; // km/h -> m/s
          final dr = (drArr is List && drArr.isNotEmpty)
              ? _numToDouble(drArr[0])
              : _numToDouble(drArr);

          if (sp == 0 && dr == 0) continue;
          final pressure = int.tryParse(lvl) ?? 0;
          final altFt = pressure == 0
              ? 0
              : pressureHpaToFeet(pressure.toDouble()).round();
          profile[altFt] = {
            'tailwind': _tailwindKts(sp, dr, trackDeg),
            'dir': dr,
            'pressure': pressure.toDouble(),
            'rawSpeedMps': sp,
          };
        }
      }

      if (profile.isEmpty) return;

      _aiWindsAloft = profile;

      if (storeKey != null) {
        final baseLevels = profile.entries.map((e) {
          return {
            'alt': e.key.toDouble(),
            'speed': (e.value['rawSpeedMps'] ?? 0),
            'dirFrom': (e.value['dir'] ?? 0),
          };
        }).toList();
        _fetchedWindLevelsByKey[storeKey] = baseLevels;
      }

      // anchors and candidate altitudes
      final anchors = profile.keys.map((k) => k.toDouble()).toList()..sort();
      final candSet = <int>{};
      for (final a in anchors) {
        final ai = a.toInt();
        candSet.add(ai - 2000);
        candSet.add(ai - 1000);
        candSet.add(ai);
        candSet.add(ai + 1000);
        candSet.add(ai + 2000);
      }
      final minA = anchors.first.toInt() - 2000;
      final maxA = anchors.last.toInt() + 2000;
      for (int a = (minA ~/ 500) * 500; a <= maxA; a += 500) {
        candSet.add(a);
      }
      final candidateAltitudes =
          candSet
              .map((v) => v.clamp(500, 20000))
              .toSet()
              .map((v) => v.toDouble())
              .toList()
            ..sort();

      // Clamp by performance table range (AW139 vs 412)
      final aw139AltKeys = fuelBurnTables.keys.toList()..sort();
      final aw139MinAlt = aw139AltKeys.isEmpty ? 0 : aw139AltKeys.first;
      final aw139MaxAlt = aw139AltKeys.isEmpty ? 6000 : aw139AltKeys.last;
      final b412AltKeys = bh412Tables.keys.toList()..sort();
      final b412MinAlt = b412AltKeys.isEmpty ? aw139MinAlt : b412AltKeys.first;
      final b412MaxAlt = b412AltKeys.isEmpty ? aw139MaxAlt : b412AltKeys.last;
      final perfMinAlt = _selectedAircraft == 'Bell 412'
          ? b412MinAlt
          : aw139MinAlt;
      final perfMaxAlt = _selectedAircraft == 'Bell 412'
          ? b412MaxAlt
          : aw139MaxAlt;

      final filteredCandidateAltitudes =
          candidateAltitudes
              .where((a) => a >= perfMinAlt && a <= perfMaxAlt)
              .toList()
            ..sort();

      final evalAltitudes = filteredCandidateAltitudes.isEmpty
          ? candidateAltitudes
          : filteredCandidateAltitudes;

      if (kDebugMode) {
        debugPrint(
          'AI_ALT_CLAMP: type=$_selectedAircraft perfRange=$perfMinAlt-$perfMaxAlt '
          'evalCount=${evalAltitudes.length}',
        );
      }

      final baseLevels =
          _aiWindsAloft?.entries.map((e) {
            return {
              'alt': e.key.toDouble(),
              'speed': _numToDouble(e.value['rawSpeedMps']),
              'dirFrom': _numToDouble(e.value['dir']),
            };
          }).toList() ??
          [];

      double? bestSingleAlt;
      double? bestSingleFuel; // stores "cost"
      double? bestSingleIas;
      double? bestSingleOut;
      double? bestSingleBack;

      double? bestOutAlt;
      double? bestOutFuel; // cost
      double? bestOutIas;

      double? bestBackAlt;
      double? bestBackFuel; // cost
      double? bestBackIas;

      const candidateIas = [
        110,
        115,
        120,
        125,
        130,
        135,
        140,
        145,
        150,
        155,
        160,
        165,
      ];

      for (final alt in evalAltitudes) {
        final tails = _tailOutBack(alt, trackDeg, baseLevels);
        final outTail = tails['out']!;
        final backTail = tails['back']!;

        // Single-alt optimize IAS
        final opt = suggestBestIas(
          altFt: alt.toInt(),
          oatC: (temperature).toInt(),
          tailwindOutKts: outTail,
          tailwindBackKts: backTail,
          distanceNmOneWay: missionDistance,
          objective: _objective,
          timeWeightKgPerMin: _timeWeightKgPerMin,
        );
        if (opt != null) {
          final fuelKg = opt['fuel']!;
          final timeHrs = opt['time']!;
          final timeMin = timeHrs * 60.0;
          final singleCost = switch (_objective) {
            OptimizationObjective.minFuel => fuelKg,
            OptimizationObjective.minTime => timeHrs,
            OptimizationObjective.hybrid =>
              fuelKg + _timeWeightKgPerMin * timeMin,
          };
          if (bestSingleFuel == null || singleCost < bestSingleFuel) {
            bestSingleFuel = singleCost;
            bestSingleAlt = alt;
            bestSingleIas = opt['ias'];
            bestSingleOut = outTail;
            bestSingleBack = backTail;
          }
        }

        // Out leg per IAS
        double? bestFuelForThisOut; // "cost"
        double? bestIasForThisOut;
        for (final ias in candidateIas) {
          double burnPerHr;
          if (_selectedAircraft == 'Bell 412' && bh412Tables.isNotEmpty) {
            final bLbs =
                _bh412GetBurn(
                  alt.toInt(),
                  temperature.toInt(),
                  ias.toDouble(),
                ) ??
                0.0;
            burnPerHr = lbsToKg(bLbs);
          } else {
            final tq = getTorqueForIAS(
              alt.toInt(),
              temperature.toInt(),
              ias.toDouble(),
            );
            burnPerHr = interpolateFuelBurn(
              tq,
              alt.toInt(),
              temperature.toInt(),
            );
          }
          final gsOut = (ias + outTail).clamp(30.0, 220.0);
          final timeOut = missionDistance / gsOut;
          final fuelOut = burnPerHr * timeOut; // kg
          final costOut = switch (_objective) {
            OptimizationObjective.minFuel => fuelOut,
            OptimizationObjective.minTime => timeOut,
            OptimizationObjective.hybrid =>
              fuelOut + _timeWeightKgPerMin * (timeOut * 60.0),
          };
          if (bestFuelForThisOut == null || costOut < bestFuelForThisOut) {
            bestFuelForThisOut = costOut;
            bestIasForThisOut = ias.toDouble();
          }
        }
        if (bestFuelForThisOut != null) {
          if (bestOutFuel == null || bestFuelForThisOut < bestOutFuel) {
            bestOutFuel = bestFuelForThisOut;
            bestOutAlt = alt;
            bestOutIas = bestIasForThisOut;
          }
        }

        // Back leg per IAS
        double? bestFuelForThisBack; // "cost"
        double? bestIasForThisBack;
        for (final ias in candidateIas) {
          double burnPerHr;
          if (_selectedAircraft == 'Bell 412' && bh412Tables.isNotEmpty) {
            final bLbs =
                _bh412GetBurn(
                  alt.toInt(),
                  temperature.toInt(),
                  ias.toDouble(),
                ) ??
                0.0;
            burnPerHr = lbsToKg(bLbs);
          } else {
            final tq = getTorqueForIAS(
              alt.toInt(),
              temperature.toInt(),
              ias.toDouble(),
            );
            burnPerHr = interpolateFuelBurn(
              tq,
              alt.toInt(),
              temperature.toInt(),
            );
          }
          final gsBack = (ias + backTail).clamp(30.0, 220.0);
          final timeBack = missionDistance / gsBack;
          final fuelBack = burnPerHr * timeBack; // kg
          final costBack = switch (_objective) {
            OptimizationObjective.minFuel => fuelBack,
            OptimizationObjective.minTime => timeBack,
            OptimizationObjective.hybrid =>
              fuelBack + _timeWeightKgPerMin * (timeBack * 60.0),
          };
          if (bestFuelForThisBack == null || costBack < bestFuelForThisBack) {
            bestFuelForThisBack = costBack;
            bestIasForThisBack = ias.toDouble();
          }
        }
        if (bestFuelForThisBack != null) {
          if (bestBackFuel == null || bestFuelForThisBack < bestBackFuel) {
            bestBackFuel = bestFuelForThisBack;
            bestBackAlt = alt;
            bestBackIas = bestIasForThisBack;
          }
        }
      } // end alt loop

      // Compare single vs separate (costs)
      double? combinedSeparateFuel =
          (bestOutFuel != null && bestBackFuel != null)
          ? (bestOutFuel + bestBackFuel)
          : null;

      double? chosenOutTail;
      double? chosenBackTail;
      double? chosenSingleAlt = bestSingleAlt;
      double? chosenSingleOut = bestSingleOut;
      double? chosenSingleBack = bestSingleBack;

      final useSeparate =
          combinedSeparateFuel != null &&
          bestSingleFuel != null &&
          combinedSeparateFuel < bestSingleFuel;

      if (useSeparate) {
        if (bestOutAlt != null) {
          chosenOutTail = _tailOutBack(bestOutAlt, trackDeg, baseLevels)['out'];
        }
        if (bestBackAlt != null) {
          chosenBackTail = _tailOutBack(
            bestBackAlt,
            trackDeg,
            baseLevels,
          )['back'];
        }
      } else {
        chosenOutTail = chosenSingleOut;
        chosenBackTail = chosenSingleBack;
      }

      if (mounted) {
        setState(() {
          _aiSuggestedAltitudeFt = chosenSingleAlt;
          _aiSuggestedAltitudeOutFt = bestOutAlt;
          _aiSuggestedAltitudeBackFt = bestBackAlt;
          _aiSuggestedIas = bestSingleIas ?? bestOutIas ?? bestBackIas;
          _aiTailwindOutKts = chosenOutTail;
          _aiTailwindBackKts = chosenBackTail;
          _aiTailwindKts = (chosenOutTail != null && chosenBackTail != null)
              ? (chosenOutTail + chosenBackTail) / 2.0
              : null;
        });
      }

      // ignore: avoid_print
      print(
        'AI_CHOICE: obj=$_objective singleAlt=$chosenSingleAlt singleCost=$bestSingleFuel '
        'outAlt=$bestOutAlt outCost=$bestOutFuel backAlt=$bestBackAlt backCost=$bestBackFuel '
        'combinedSeparateCost=$combinedSeparateFuel k=${_timeWeightKgPerMin.toStringAsFixed(2)} kg/min',
      );
    } catch (e) {
      // ignore: avoid_print
      print('fetchAiAltitudeSuggestion error: $e');
    }
  }
  // ...existing code...

  Future<Position?> getCurrentPosition() async {
    try {
      final ok = await _ensureLocationPermission();
      if (!ok) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> calculateCruise({bool roundTrip = true}) async {
    // Parse inputs
    cruiseSpeed = _parseNumber(cruiseSpeedController.text);
    // ensure missionDistance reads from the input field unless auto-calculated later
    missionDistance = _parseNumber(missionDistanceController.text);
    altitude = _parseNumber(altitudeController.text);
    if (_selectedAircraft == 'AW139') {
      final minA = _aw139MinPerfAlt().toDouble();
      final maxA = _aw139MaxPerfAlt().toDouble();
      if (altitude > maxA) {
        altitude = maxA;
        altitudeController.text = altitude.toStringAsFixed(0);
      } else if (altitude < minA) {
        altitude = minA;
        altitudeController.text = altitude.toStringAsFixed(0);
      }
    }
    temperature = _parseNumber(temperatureController.text);
    fuelOnboard = _parseNumber(fuelController.text);
    // if Bell 412 selected, user enters lbs -> convert to kg for internal calcs
    if (_selectedAircraft == 'Bell 412') {
      fuelOnboard = lbsToKg(fuelOnboard);
    }
    // PNR: parse reserve fuel (display units -> kg internal)
    reserveFuel = _parseNumber(reserveController.text);
    double reserveKg = reserveFuel;
    if (_selectedAircraft == 'Bell 412') {
      reserveKg = lbsToKg(reserveFuel);
    }
    extraHoistMinutes = _parseNumber(hoistTimeController.text);

    // Input validation
    if (!cruiseSpeed.isFinite || cruiseSpeed <= 0) {
      cruiseSpeed = 1;
    }
    if (!missionDistance.isFinite || missionDistance <= 0) {
      missionDistance = 1; // prevent zero-distance calculations
      missionDistanceController.text = missionDistance.toStringAsFixed(0);
    }
    if (!fuelOnboard.isFinite || fuelOnboard < 0) {
      fuelOnboard = 0;
    }
    if (!extraHoistMinutes.isFinite || extraHoistMinutes < 0) {
      extraHoistMinutes = 0;
    }

    // Reset AI suggestions
    _aiSuggestedAltitudeFt = null;
    _aiTailwindKts = null;
    _aiTailwindOutKts = null;
    _aiTailwindBackKts = null;
    _aiSuggestedIas = null;

    final cf = getCorrectionFactor(
      searchlight: searchlight,
      radar: radar,
      flir: flir,
      hoist: hoist,
    );

    // Parse coordinates
    final originLat = _parseCoord(originLatController.text, isLat: true);
    final originLon = _parseCoord(originLonController.text, isLat: false);
    final destLat = _parseCoord(destLatController.text, isLat: true);
    final destLon = _parseCoord(destLonController.text, isLat: false);

    // Auto compute missionDistance (one-way) when enabled
    if (autoDistanceFromLatLon) {
      final points = <LatLng>[];
      if (originLat.isFinite && originLon.isFinite) {
        points.add(LatLng(originLat, originLon));
      }
      // Use draggable mid-route waypoints in current order
      for (final wp in _waypoints) {
        if (!wp.enabled) {
          continue;
        }
        final wLat = _parseCoord(wp.lat.text, isLat: true);
        final wLon = _parseCoord(wp.lon.text, isLat: false);
        if (wLat.isFinite && wLon.isFinite) {
          final anchor = LatLng(wLat, wLon);
          points.add(anchor);
          _appendPatternIfAny(points, wp.id, anchor);
        }
      }
      if (destLat.isFinite && destLon.isFinite) {
        points.add(LatLng(destLat, destLon));
      }

      if (points.length >= 2) {
        double total = 0.0;
        for (int i = 0; i < points.length - 1; i++) {
          total += _gcDistanceNm(
            points[i].latitude,
            points[i].longitude,
            points[i + 1].latitude,
            points[i + 1].longitude,
          );
        }
        missionDistanceController.text = total.toStringAsFixed(0);
        missionDistance = total;
      }
    }
    // ...existing code...
    // ...existing code...
    // Base performance (may change if AI auto-applies)
    var perf = calculateCruisePerformance(
      distance: missionDistance,
      cruiseSpeed: cruiseSpeed,
      altitude: altitude.toInt(),
      temperature: temperature.toInt(),
      roundTrip: roundTrip,
      cf: cf,
    );

    double tailwindOut = 0.0;
    double tailwindBack = 0.0;

    // Normalize displayed coords (decimal)
    if (originLat.isFinite) {
      originLatController.text = originLat.toStringAsFixed(6);
    }
    if (originLon.isFinite) {
      originLonController.text = originLon.toStringAsFixed(6);
    }
    if (destLat.isFinite) {
      destLatController.text = destLat.toStringAsFixed(6);
    }
    if (destLon.isFinite) {
      destLonController.text = destLon.toStringAsFixed(6);
    }

    // Fetch winds & AI suggestions
    if (useWindsAloft && !standardWinds) {
      if (originLat.isFinite &&
          originLon.isFinite &&
          destLat.isFinite &&
          destLon.isFinite &&
          (destLat != 0 || destLon != 0)) {
        final trackDeg = _initialBearingDeg(
          originLat,
          originLon,
          destLat,
          destLon,
        );
        await fetchAiAltitudeSuggestion(
          lat: originLat,
          lon: originLon,
          trackDeg: trackDeg,
        );
        // keep a copy for the dialog / map markers so "Show Winds Aloft" can display it
        _departureWindsAloft = _aiWindsAloft;

        // optionally also fetch and store destination winds so dialog shows both
        if (destLat.isFinite && destLon.isFinite) {
          await fetchAiAltitudeSuggestion(
            lat: destLat,
            lon: destLon,
            trackDeg: trackDeg,
          );
          _destinationWindsAloft = _aiWindsAloft;
        }

        if (_aiTailwindOutKts != null) {
          tailwindOut = _aiTailwindOutKts!;
        }
        if (_aiTailwindBackKts != null) {
          tailwindBack = _aiTailwindBackKts!;
        }

        // Auto apply (only if data present)
        if (autoApplyAi) {
          bool changed = false;
          if (_aiSuggestedIas != null && _aiSuggestedIas!.isFinite) {
            cruiseSpeed = _aiSuggestedIas!;
            cruiseSpeedController.text = cruiseSpeed.toStringAsFixed(0);
            changed = true;
          }
          if (_aiSuggestedAltitudeFt != null &&
              _aiSuggestedAltitudeFt!.isFinite) {
            altitude = _aiSuggestedAltitudeFt!;
            altitudeController.text = altitude.toStringAsFixed(0);
            changed = true;
          }
          if (changed) {
            perf = calculateCruisePerformance(
              distance: missionDistance,
              cruiseSpeed: cruiseSpeed,
              altitude: altitude.toInt(),
              temperature: temperature.toInt(),
              roundTrip: roundTrip,
              cf: cf,
            );
            setState(() {}); // reflect controller changes
          }
        }
      }
    }

    // After winds/AI logic (and after any AI auto-apply that may change
    // cruiseSpeed/altitude), override Bell 412 burn from the table:
    if (_selectedAircraft == 'Bell 412' && bh412Tables.isNotEmpty) {
      final burnLbsHr =
          _bh412GetBurn(altitude.toInt(), temperature.toInt(), cruiseSpeed) ??
          0.0;
      final burnKgHr = lbsToKg(burnLbsHr); // keep internals in kg/hr
      perf['fuelBurnPerHour'] = burnKgHr;
      if (kDebugMode) {
        debugPrint(
          'B412 burn override: '
          '${burnLbsHr.toStringAsFixed(0)} lbs/hr '
          '(${burnKgHr.toStringAsFixed(0)} kg/hr)',
        );
      }
    }

    // Final calculations
    final d = missionDistance;
    final gsOut = (cruiseSpeed + tailwindOut).clamp(1.0, double.infinity);
    final gsBack = (cruiseSpeed + tailwindBack).clamp(1.0, double.infinity);
    final cruiseDuration = roundTrip ? (d / gsOut + d / gsBack) : (d / gsOut);

    final adjustedFuelBurn = perf['fuelBurnPerHour']!;
    final endurance = fuelOnboard / adjustedFuelBurn;
    final estimatedRange = cruiseSpeed * endurance;

    // SAR breakdown (always use 70 knots IAS for SAR fuel/time)
    final sarDistanceNm = _sarDistanceOneWayNm();
    final sarIas = 70.0;
    final sarAltitude = 500; // Always use 500 ft for SAR search patterns
    final sarBurnKgPerHr =
        (_selectedAircraft == 'Bell 412' && bh412Tables.isNotEmpty)
        ? lbsToKg(
            _bh412GetBurn(sarAltitude, temperature.toInt(), sarIas) ?? 0.0,
          )
        : interpolateFuelBurn(
            getTorqueForIAS(sarAltitude, temperature.toInt(), sarIas),
            sarAltitude,
            temperature.toInt(),
          );
    final sarTimeOutHrs = sarDistanceNm / sarIas;
    final sarTimeBackHrs = roundTrip ? (sarDistanceNm / sarIas) : 0.0;
    final sarTimeHours = sarTimeOutHrs + sarTimeBackHrs;
    final sarFuelKg = sarBurnKgPerHr * sarTimeHours;
    // Hoist / hover
    final hoistBlocks = (extraHoistMinutes / 5.0).ceil();
    final hoistMinutesRounded = hoistBlocks * 5.0;
    final hoistHours = hoistMinutesRounded / 60.0;
    final hoistFuel = hoistHours * 450;

    final fuelForMission = adjustedFuelBurn * cruiseDuration;
    final fuelRemainingAfterMission = fuelOnboard - fuelForMission - hoistFuel;
    final postMissionLowFuel = fuelRemainingAfterMission < 180;
    final missionDuration = cruiseDuration + hoistHours;

    // Build timeline (kg)
    final outHours = d / gsOut;
    final backHours = roundTrip ? (d / gsBack) : 0.0;
    final fuelTimelineKg = _buildFuelTimeline(
      initialFuelKg: fuelOnboard,
      cruiseBurnKgPerHr: adjustedFuelBurn,
      outHours: outHours,
      backHours: backHours,
      hoistHours: hoistHours,
      intervalMin: 20,
    );

    // PNR: compute distance and map point
    {
      final routePts = <LatLng>[];
      if (originLat.isFinite && originLon.isFinite) {
        routePts.add(LatLng(originLat, originLon));
      }
      for (final wp in _waypoints) {
        if (!wp.enabled) continue;
        final wLat = _parseCoord(wp.lat.text, isLat: true);
        final wLon = _parseCoord(wp.lon.text, isLat: false);
        if (!wLat.isFinite || !wLon.isFinite) continue;
        final anchor = LatLng(wLat, wLon);
        routePts.add(anchor);
        if (includeSarInPnr) {
          _appendPatternIfAny(routePts, wp.id, anchor);
        }
      }
      if (destLat.isFinite && destLon.isFinite) {
        routePts.add(LatLng(destLat, destLon));
      }

      final pnrNmRaw = _computePnrNm(
        fuelOnboardKg: fuelOnboard,
        reserveKg: reserveKg,
        hoistMinutes: extraHoistMinutes,
        burnKgPerHr: adjustedFuelBurn,
        gsOutKts: gsOut,
        gsBackKts: gsBack,
      );
      final pnrNm = d > 0 ? pnrNmRaw.clamp(0.0, d) : 0.0;
      LatLng? pnrPoint;
      if (routePts.length >= 2 && pnrNm > 0) {
        pnrPoint = _pointAlongRoute(routePts, pnrNm);
      }

      setState(() {
        _lastRequiredTorque = perf['recommendedTorque']!;
        _lastAdjustedFuelBurn = adjustedFuelBurn;
        _lastFuelRemaining = fuelRemainingAfterMission;
        _pnrNm = pnrNm;
        _pnrPoint = pnrPoint;
      });
    }
    if (!mounted) return;
    showCruiseResultsDialog(
      context: context,
      endurance: endurance,
      estimatedRange: estimatedRange,
      missionDistance: missionDistance,
      missionDuration: missionDuration,
      fuelRemaining: fuelRemainingAfterMission,
      lowFuelWarning: postMissionLowFuel,
      requiredTorque: perf['recommendedTorque']!,
      cruiseSpeed: cruiseSpeed,
      altitude: altitude,
      temperature: temperature,
      adjustedFuelBurn: adjustedFuelBurn,
      hoistMinutesRounded: hoistMinutesRounded,
      hoistFuel: hoistFuel,
      fuelRequired: fuelForMission + hoistFuel,
      fuelTimelineKg: fuelTimelineKg,
      aiAltitudeFt: _aiSuggestedAltitudeFt,
      aiTailwindKts: _aiTailwindKts,
      aiTailwindOutKts: _aiTailwindOutKts,
      aiTailwindBackKts: _aiTailwindBackKts,
      aiSuggestedIas: _aiSuggestedIas,
      isBell412: _selectedAircraft == 'Bell 412',
      originLat: originLat.isFinite ? originLat : null,
      originLon: originLon.isFinite ? originLon : null,
      destLat: destLat.isFinite ? destLat : null,
      destLon: destLon.isFinite ? destLon : null,
      roundTrip: roundTrip,
      sarDistanceNm: sarDistanceNm,
      sarTimeHours: sarTimeHours,
      sarFuelKg: sarFuelKg,
    );
    // Winds Aloft for PDF/export
    final windData =
        _aiWindsAloft ??
        {
          2000: {'tailwind': _aiTailwindKts ?? 0, 'dir': 0},
          4000: {'tailwind': 0, 'dir': 0},
          6000: {'tailwind': 0, 'dir': 0},
        };

    // Build a simple Map<int,double> of tailwinds to pass to getOrInterpolateWind
    final tailwinds = <int, double>{};
    windData.forEach((k, v) {
      tailwinds[k] = _numToDouble(v['tailwind']);
    });

    // Store data for PDF export
    _lastReport = CruiseReportData(
      endurance: endurance,
      estimatedRange: estimatedRange,
      missionDistance: missionDistance,
      missionDuration: missionDuration,
      fuelRemaining: fuelRemainingAfterMission,
      lowFuel: postMissionLowFuel,
      requiredTorque: perf['recommendedTorque']!,
      cruiseSpeed: cruiseSpeed,
      altitude: altitude,
      temperature: temperature,
      fuelBurnPerHour: adjustedFuelBurn,
      hoistMinutes: hoistMinutesRounded,
      hoistFuel: hoistFuel,
      originDmsLat: originLat.isFinite
          ? _formatDms(originLat, isLat: true)
          : null,
      originDmsLon: originLon.isFinite
          ? _formatDms(originLon, isLat: false)
          : null,
      destDmsLat: destLat.isFinite ? _formatDms(destLat, isLat: true) : null,
      destDmsLon: destLon.isFinite ? _formatDms(destLon, isLat: false) : null,
      aiAlt: _aiSuggestedAltitudeFt,
      aiIas: _aiSuggestedIas,
      aiTailOut: _aiTailwindOutKts,
      aiTailBack: _aiTailwindBackKts,
      windsAloft: {
        2000: getOrInterpolateWind(2000, tailwinds),
        4000: getOrInterpolateWind(4000, tailwinds),
        6000: getOrInterpolateWind(6000, tailwinds),
      },
      fuelRemainingTimelineKg: fuelTimelineKg,
      isBell412: _selectedAircraft == 'Bell 412', // <-- add this
    );
  } // end calculateCruise
} // end CruiseInputScreenState
