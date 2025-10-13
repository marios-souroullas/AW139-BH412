import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:aw139_cruise/export/cruise_report_export.dart'; // <-- add this line
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, debugPrint;
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:async';

// Windy API key (keep private). Replace YOUR_REAL_WINDY_KEY with your key.
const String kWindyApiKey = 'a4wqVgw3RBBPbjA0PjMtmD1I9PK0ndAX';

enum WindProvider { openMeteo, windy }

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
                if (lowFuelWarning)
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

// Single, clean widget + state (remove any other duplicate class blocks above)
class CruiseInputScreen extends StatefulWidget {
  const CruiseInputScreen({super.key});
  @override
  State<CruiseInputScreen> createState() => CruiseInputScreenState();
}

class CruiseInputScreenState extends State<CruiseInputScreen> {
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

  // Flags for optional waypoints
  bool useWaypoint1 = false;
  bool useHospitalWaypoint = false;
  bool useWaypoint2 = false;
  // (removed duplicate small build — full build method appears later)

  // Coordinate validation errors for the extra waypoints
  String? waypoint1LatError,
      waypoint1LonError,
      hospitalLatError,
      hospitalLonError;
  String? waypoint2LatError, waypoint2LonError;

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

  // Coordinate validation errors
  String? originLatError, originLonError, destLatError, destLonError;
  // ignore: unused_field
  CruiseReportData? _lastReport;

  // AI suggestions
  double? _aiSuggestedAltitudeFt;
  double? _aiSuggestedAltitudeOutFt;
  double? _aiSuggestedAltitudeBackFt;
  double? _aiTailwindKts;
  double? _aiTailwindOutKts;
  double? _aiTailwindBackKts;
  double? _aiSuggestedIas;

  // Aircraft selection (default AW139). Add 'Bell 412' when you upload tables.
  String _selectedAircraft = 'AW139';
  static const List<String> kAircraftOptions = ['AW139', 'Bell 412'];

  // Wind provider selection
  WindProvider _windProvider = kWindyApiKey.isNotEmpty
      ? WindProvider.windy
      : WindProvider.openMeteo;
  static const Map<WindProvider, String> _windProviderNames = {
    WindProvider.windy: 'Windy (requires key)',
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
    // Wind "to" is from + 180
    final windToDeg = (dirFrom + 180.0) % 360.0;
    final angle = _degToRad(windToDeg);
    // make arrows larger & high-contrast for easy visibility
    final size = (speed * 8.0 + 32.0).clamp(20.0, 96.0);

    // DEBUG: print when building arrow markers
    // ignore: avoid_print
    print(
      'WIND_ARROW build key=$key lat=${lat.toStringAsFixed(6)} lon=${lon.toStringAsFixed(6)} alt=$alt speed=${speed.toStringAsFixed(2)} dirFrom=${dirFrom.toStringAsFixed(1)} windTo=$windToDeg size=$size',
    );

    return [
      Marker(
        point: LatLng(lat, lon),
        width: size,
        height: size,
        child: Container(
          alignment: Alignment.center,
          // dark circular backdrop so the yellow arrow is visible on any tile
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

  // ...existing code...
  @override
  void initState() {
    super.initState();
    // load BH412 performance table (safe to call even if asset missing)
    loadBh412TablesFromAsset();

    // existing controller initialisation
    cruiseSpeedController.text = cruiseSpeed.toStringAsFixed(0);
    missionDistanceController.text = missionDistance.toStringAsFixed(0);
    altitudeController.text = altitude.toStringAsFixed(0);
    temperatureController.text = temperature.toStringAsFixed(0);
    fuelController.text = fuelOnboard.toStringAsFixed(0);
    hoistTimeController.text = extraHoistMinutes.toStringAsFixed(0);
  }
  // ...existing code...

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
    super.dispose();
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
      if (useHospitalWaypoint && hLat.isFinite && hLon.isFinite) {
        points.add(LatLng(hLat, hLon));
      }
      if (useWaypoint1 && w1Lat.isFinite && w1Lon.isFinite) {
        points.add(LatLng(w1Lat, w1Lon));
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
    // ...existing code...
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AW139 Cruise Planner v4')),
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
                            setState(() => _selectedAircraft = v);
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
                  buildInputField('Hoist Time (min)', hoistTimeController),

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
                  SwitchListTile(
                    title: const Text('Show Mission Map & Weather'),
                    value: showMap,
                    onChanged: (v) => setState(() => showMap = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  // ...existing code...
                  if (showMap)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.map),
                        label: const Text('View Map'),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (_) => Dialog(
                              child: SizedBox(
                                width: 900, // increased width
                                height: 640, // increased height
                                child: FlutterMap(
                                  options: MapOptions(
                                    initialCenter: LatLng(
                                      _parseCoord(
                                        originLatController.text,
                                        isLat: true,
                                      ),
                                      _parseCoord(
                                        originLonController.text,
                                        isLat: false,
                                      ),
                                    ),
                                    initialZoom: 8,
                                  ),
                                  children: <Widget>[
                                    TileLayer(
                                      urlTemplate:
                                          'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                                      subdomains: const ['a', 'b', 'c'],
                                    ),
                                    // Uses kOpenWeatherApiKey constant defined at top of file
                                    Opacity(
                                      opacity: 0.7,
                                      child: TileLayer(
                                        urlTemplate:
                                            'https://tile.openweathermap.org/map/clouds_new/{z}/{x}/{y}.png?appid=$kOpenWeatherApiKey',
                                      ),
                                    ),
                                    Opacity(
                                      opacity: 0.9,
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
                                    PolylineLayer(
                                      polylines: [
                                        Polyline(
                                          points: [
                                            // Origin
                                            if (_parseCoord(
                                                  originLatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  originLonController.text,
                                                  isLat: false,
                                                ).isFinite)
                                              LatLng(
                                                _parseCoord(
                                                  originLatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  originLonController.text,
                                                  isLat: false,
                                                ),
                                              ),
                                            // Hospital (optional)
                                            if (useHospitalWaypoint &&
                                                hospitalLatController
                                                    .text
                                                    .isNotEmpty &&
                                                hospitalLonController
                                                    .text
                                                    .isNotEmpty &&
                                                _parseCoord(
                                                  hospitalLatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  hospitalLonController.text,
                                                  isLat: false,
                                                ).isFinite)
                                              LatLng(
                                                _parseCoord(
                                                  hospitalLatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  hospitalLonController.text,
                                                  isLat: false,
                                                ),
                                              ),
                                            // Waypoint 1 (optional)
                                            if (useWaypoint1 &&
                                                waypoint1LatController
                                                    .text
                                                    .isNotEmpty &&
                                                waypoint1LonController
                                                    .text
                                                    .isNotEmpty &&
                                                _parseCoord(
                                                  waypoint1LatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  waypoint1LonController.text,
                                                  isLat: false,
                                                ).isFinite)
                                              LatLng(
                                                _parseCoord(
                                                  waypoint1LatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  waypoint1LonController.text,
                                                  isLat: false,
                                                ),
                                              ),
                                            // Waypoint 2 (optional)
                                            if (useWaypoint2 &&
                                                waypoint2LatController
                                                    .text
                                                    .isNotEmpty &&
                                                waypoint2LonController
                                                    .text
                                                    .isNotEmpty &&
                                                _parseCoord(
                                                  waypoint2LatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  waypoint2LonController.text,
                                                  isLat: false,
                                                ).isFinite)
                                              LatLng(
                                                _parseCoord(
                                                  waypoint2LatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  waypoint2LonController.text,
                                                  isLat: false,
                                                ),
                                              ),
                                            // Destination
                                            if (_parseCoord(
                                                  destLatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  destLonController.text,
                                                  isLat: false,
                                                ).isFinite)
                                              LatLng(
                                                _parseCoord(
                                                  destLatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  destLonController.text,
                                                  isLat: false,
                                                ),
                                              ),
                                          ],
                                          color: Colors.blue,
                                          strokeWidth: 4,
                                        ),
                                      ],
                                    ),

                                    // Markers for each point (same order)
                                    MarkerLayer(
                                      markers: [
                                        if (_parseCoord(
                                              originLatController.text,
                                              isLat: true,
                                            ).isFinite &&
                                            _parseCoord(
                                              originLonController.text,
                                              isLat: false,
                                            ).isFinite)
                                          Marker(
                                            point: LatLng(
                                              _parseCoord(
                                                originLatController.text,
                                                isLat: true,
                                              ),
                                              _parseCoord(
                                                originLonController.text,
                                                isLat: false,
                                              ),
                                            ),
                                            width: 30,
                                            height: 30,
                                            child: const Icon(
                                              Icons.location_on,
                                              color: Colors.green,
                                            ),
                                          ),
                                        if (useHospitalWaypoint &&
                                            hospitalLatController
                                                .text
                                                .isNotEmpty &&
                                            hospitalLonController
                                                .text
                                                .isNotEmpty &&
                                            _parseCoord(
                                              hospitalLatController.text,
                                              isLat: true,
                                            ).isFinite &&
                                            _parseCoord(
                                              hospitalLonController.text,
                                              isLat: false,
                                            ).isFinite)
                                          Marker(
                                            point: LatLng(
                                              _parseCoord(
                                                hospitalLatController.text,
                                                isLat: true,
                                              ),
                                              _parseCoord(
                                                hospitalLonController.text,
                                                isLat: false,
                                              ),
                                            ),
                                            width: 30,
                                            height: 30,
                                            child: const Icon(
                                              Icons.local_hospital,
                                              color: Colors.pink,
                                            ),
                                          ),
                                        if (useWaypoint1 &&
                                            waypoint1LatController
                                                .text
                                                .isNotEmpty &&
                                            waypoint1LonController
                                                .text
                                                .isNotEmpty &&
                                            _parseCoord(
                                              waypoint1LatController.text,
                                              isLat: true,
                                            ).isFinite &&
                                            _parseCoord(
                                              waypoint1LonController.text,
                                              isLat: false,
                                            ).isFinite)
                                          Marker(
                                            point: LatLng(
                                              _parseCoord(
                                                waypoint1LatController.text,
                                                isLat: true,
                                              ),
                                              _parseCoord(
                                                waypoint1LonController.text,
                                                isLat: false,
                                              ),
                                            ),
                                            width: 28,
                                            height: 28,
                                            child: const Icon(
                                              Icons.location_searching,
                                              color: Colors.cyan,
                                            ),
                                          ),
                                        if (useWaypoint2 &&
                                            waypoint2LatController
                                                .text
                                                .isNotEmpty &&
                                            waypoint2LonController
                                                .text
                                                .isNotEmpty &&
                                            _parseCoord(
                                              waypoint2LatController.text,
                                              isLat: true,
                                            ).isFinite &&
                                            _parseCoord(
                                              waypoint2LonController.text,
                                              isLat: false,
                                            ).isFinite)
                                          Marker(
                                            point: LatLng(
                                              _parseCoord(
                                                waypoint2LatController.text,
                                                isLat: true,
                                              ),
                                              _parseCoord(
                                                waypoint2LonController.text,
                                                isLat: false,
                                              ),
                                            ),
                                            width: 28,
                                            height: 28,
                                            child: const Icon(
                                              Icons.location_searching,
                                              color: Colors.cyanAccent,
                                            ),
                                          ),
                                        if (_parseCoord(
                                              destLatController.text,
                                              isLat: true,
                                            ).isFinite &&
                                            _parseCoord(
                                              destLonController.text,
                                              isLat: false,
                                            ).isFinite)
                                          Marker(
                                            point: LatLng(
                                              _parseCoord(
                                                destLatController.text,
                                                isLat: true,
                                              ),
                                              _parseCoord(
                                                destLonController.text,
                                                isLat: false,
                                              ),
                                            ),
                                            width: 30,
                                            height: 30,
                                            child: const Icon(
                                              Icons.flag,
                                              color: Colors.red,
                                            ),
                                          ),
                                        // Wind arrows (spread markers built from stored profiles)
                                        ...(_parseCoord(
                                                  hospitalLatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  hospitalLonController.text,
                                                  isLat: false,
                                                ).isFinite
                                            ? _buildWindArrowMarkers(
                                                'hospital',
                                                _parseCoord(
                                                  hospitalLatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  hospitalLonController.text,
                                                  isLat: false,
                                                ),
                                              )
                                            : []),
                                        // waypoint1
                                        ...(_parseCoord(
                                                  waypoint1LatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  waypoint1LonController.text,
                                                  isLat: false,
                                                ).isFinite
                                            ? _buildWindArrowMarkers(
                                                'wpt1',
                                                _parseCoord(
                                                  waypoint1LatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  waypoint1LonController.text,
                                                  isLat: false,
                                                ),
                                              )
                                            : []),
                                        // waypoint2
                                        ...(_parseCoord(
                                                  waypoint2LatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  waypoint2LonController.text,
                                                  isLat: false,
                                                ).isFinite
                                            ? _buildWindArrowMarkers(
                                                'wpt2',
                                                _parseCoord(
                                                  waypoint2LatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  waypoint2LonController.text,
                                                  isLat: false,
                                                ),
                                              )
                                            : []),
                                        ...(_parseCoord(
                                                  waypoint1LatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  waypoint1LonController.text,
                                                  isLat: false,
                                                ).isFinite
                                            ? _buildWindArrowMarkers(
                                                'origin',
                                                _parseCoord(
                                                  waypoint1LatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  waypoint1LonController.text,
                                                  isLat: false,
                                                ),
                                              )
                                            : []),
                                        ...(_parseCoord(
                                                  waypoint2LatController.text,
                                                  isLat: true,
                                                ).isFinite &&
                                                _parseCoord(
                                                  waypoint2LonController.text,
                                                  isLat: false,
                                                ).isFinite
                                            ? _buildWindArrowMarkers(
                                                'origin',
                                                _parseCoord(
                                                  waypoint2LatController.text,
                                                  isLat: true,
                                                ),
                                                _parseCoord(
                                                  waypoint2LonController.text,
                                                  isLat: false,
                                                ),
                                              )
                                            : []),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  // ...existing code...
                  // ...continue with your form...
                  // ...continue with your form...

                  // --- End toggles ---
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

                  // Hospital waypoint toggle + its fields
                  SwitchListTile(
                    title: const Text('Add Hospital Waypoint'),
                    value: useHospitalWaypoint,
                    onChanged: (v) => setState(() {
                      useHospitalWaypoint = v;
                      _validateAndDistance();
                    }),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (useHospitalWaypoint) ...[
                    coordField(
                      'Hospital Latitude',
                      hospitalLatController,
                      isLat: true,
                      errorText: hospitalLatError,
                    ),
                    coordField(
                      'Hospital Longitude',
                      hospitalLonController,
                      isLat: false,
                      errorText: hospitalLonError,
                    ),
                  ],

                  // Waypoint 1 toggle + its fields
                  SwitchListTile(
                    title: const Text('Waypoint 1'),
                    value: useWaypoint1,
                    onChanged: (v) {
                      // update visibility first, then validate
                      setState(() => useWaypoint1 = v);
                      // quick console trace
                      // ignore: avoid_print
                      print('DEBUG: useWaypoint1 = $useWaypoint1');
                      _validateAndDistance();
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  // debug readout (remove after testing)
                  Text(
                    'DEBUG: useWaypoint1 = $useWaypoint1',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (useWaypoint1) ...[
                    coordField(
                      'Waypoint 1 Latitude',
                      waypoint1LatController,
                      isLat: true,
                      errorText: waypoint1LatError,
                    ),
                    coordField(
                      'Waypoint 1 Longitude',
                      waypoint1LonController,
                      isLat: false,
                      errorText: waypoint1LonError,
                    ),
                  ],

                  // Waypoint 2 toggle + its fields
                  SwitchListTile(
                    title: const Text('Waypoint 2'),
                    value: useWaypoint2,
                    onChanged: (v) => setState(() {
                      useWaypoint2 = v;
                      _validateAndDistance();
                    }),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (useWaypoint2) ...[
                    coordField(
                      'Waypoint 2 Latitude',
                      waypoint2LatController,
                      isLat: true,
                      errorText: waypoint2LatError,
                    ),
                    coordField(
                      'Waypoint 2 Longitude',
                      waypoint2LonController,
                      isLat: false,
                      errorText: waypoint2LonError,
                    ),
                  ],
                  const SizedBox(height: 16),

                  const SizedBox(height: 16),
                  if (useWindsAloft &&
                      !standardWinds &&
                      (_aiSuggestedIas != null ||
                          _aiSuggestedAltitudeFt != null ||
                          _aiTailwindKts != null))
                    Card(
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
                                style: const TextStyle(color: Colors.white),
                              ),
                            if (_aiSuggestedAltitudeFt != null)
                              Text(
                                'Suggested Altitude: ${_aiSuggestedAltitudeFt?.toStringAsFixed(0) ?? '--'} ft',
                                style: const TextStyle(color: Colors.white),
                              ),
                            // show per‑leg suggested altitudes when available (prevents unused-field warnings)
                            if (_aiSuggestedAltitudeOutFt != null)
                              Text(
                                'Suggested Out Altitude: ${_aiSuggestedAltitudeOutFt?.toStringAsFixed(0) ?? '--'} ft',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            if (_aiSuggestedAltitudeBackFt != null)
                              Text(
                                'Suggested Back Altitude: ${_aiSuggestedAltitudeBackFt?.toStringAsFixed(0) ?? '--'} ft',
                                style: const TextStyle(color: Colors.white70),
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
                            if (!autoApplyAi)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed:
                                      (_aiSuggestedIas == null &&
                                          _aiSuggestedAltitudeFt == null)
                                      ? null
                                      : applyAiSuggestions,
                                  icon: const Icon(
                                    Icons.check_circle,
                                    color: Colors.cyanAccent,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Apply Suggestions',
                                    style: TextStyle(color: Colors.cyanAccent),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
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
                                      const SizedBox(height: 12),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                          onPressed: () =>
                                              Navigator.of(dialogContext).pop(),
                                          child: const Text('Close'),
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
                                  CruiseReportExporter.share(_lastReport!);
                                },
                          icon: const Icon(Icons.share),
                          label: const Text('Share'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
          // ...existing code...
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
        // Open‑Meteo fallback (request surface + the pressure levels we care about)
        final omParams = StringBuffer()
          ..write('&forecast_days=1')
          ..write('&hourly=')
          // surface winds (10m)
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

      // normalize generically into level -> (speed m/s, dirFrom)
      final Map<int, Map<String, double>> profile = {};

      if (raw['provider'] == 'windy') {
        final wd = raw['data'] as Map<String, dynamic>;
        final levels = (wd['levels'] is Map)
            ? wd['levels'] as Map<String, dynamic>
            : <String, dynamic>{};
        if (levels.isEmpty) {
          if (kDebugMode) {
            debugPrint('WINDY: no levels key found in response: ${wd.keys}');
          }
        }

        // Use whatever level keys Windy returned (robust to 'sfc', numeric strings, or other names)
        final available = levels.keys.toList();
        // Try to sort numerically when possible, keeping 'sfc' first
        available.sort((a, b) {
          if (a == 'sfc') return -1;
          if (b == 'sfc') return 1;
          final ai = int.tryParse(a) ?? 0;
          final bi = int.tryParse(b) ?? 0;
          return ai.compareTo(bi);
        });

        for (final lvl in available) {
          try {
            final entry = levels[lvl] as Map<String, dynamic>?;
            if (entry == null) continue;

            // Wind may be nested under 'wind' or present as top-level fields; try common names.
            Map<String, dynamic>? windMap = entry['wind'] is Map
                ? entry['wind'] as Map<String, dynamic>
                : null;
            double sp = 0.0;
            double dir = 0.0;
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
              // fallback to common top-level keys
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
          } catch (e) {
            if (kDebugMode) debugPrint('WINDY parse error for level $lvl: $e');
            continue;
          }
        }
      } else {
        final data = raw['data'] as Map<String, dynamic>;
        final h = (data['hourly'] ?? {}) as Map<String, dynamic>;

        // surface first (handle either naming: windspeed_10m or wind_speed_10m)
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

        // Discover which pressure-level keys the API actually returned (robust to missing levels)
        final presentLevels = <int>{};
        for (final k in h.keys) {
          final m = RegExp(r'wind_speed_(\d+)hPa').firstMatch(k);
          if (m != null) {
            final p = int.tryParse(m.group(1) ?? '');
            if (p != null) presentLevels.add(p);
          }
        }

        // Build ordered list of levels to use: prefer discovered presentLevels, else fallback to desiredLevels
        final levelsToUse = <String>[];
        if (presentLevels.isNotEmpty) {
          final sorted = presentLevels.toList()..sort();
          for (final p in sorted) {
            levelsToUse.add(p.toString());
          }
        } else {
          // no discovered levels — fall back to configured desiredLevels (this keeps prior behaviour)
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
          // Open-Meteo returns km/h, convert to m/s for all wind_speed_*hPa keys
          final sp = spRaw / 3.6;
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
      // ...existing code...

      if (profile.isEmpty) return;

      // store normalized profile
      _aiWindsAloft = profile;

      // optional persist per-storeKey
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

      // Use profile keys (altitudes in ft) as anchors for candidate generation
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

      // Evaluate candidates using existing logic (reuse _aiWindsAloft -> baseLevels)
      final baseLevels =
          _aiWindsAloft?.entries.map((e) {
            return {
              'alt': e.key.toDouble(),
              'speed': _numToDouble(e.value['rawSpeedMps']),
              'dirFrom': _numToDouble(e.value['dir']),
            };
          }).toList() ??
          [];

      // existing evaluation loop follows (keeps prior logic unchanged)
      double? bestSingleAlt;
      double? bestSingleFuel;
      double? bestSingleIas;
      double? bestSingleOut;
      double? bestSingleBack;

      double? bestOutAlt;
      double? bestOutFuel;
      double? bestOutIas;
      double? bestBackAlt;
      double? bestBackFuel;
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

      for (final alt in candidateAltitudes) {
        final tails = _tailOutBack(alt, trackDeg, baseLevels);
        final outTail = tails['out']!;
        final backTail = tails['back']!;

        final opt = suggestBestIas(
          altFt: alt.toInt(),
          oatC: (temperature).toInt(),
          tailwindOutKts: outTail,
          tailwindBackKts: backTail,
          distanceNmOneWay: missionDistance,
        );
        if (opt != null) {
          final fuel = opt['fuel']!;
          if (bestSingleFuel == null || fuel < bestSingleFuel) {
            bestSingleFuel = fuel;
            bestSingleAlt = alt;
            bestSingleIas = opt['ias'];
            bestSingleOut = outTail;
            bestSingleBack = backTail;
          }
        }

        double? bestFuelForThisOut;
        double? bestIasForThisOut;
        for (final ias in candidateIas) {
          final tq = getTorqueForIAS(
            alt.toInt(),
            temperature.toInt(),
            ias.toDouble(),
          );
          final burnPerHr = interpolateFuelBurn(
            tq,
            alt.toInt(),
            temperature.toInt(),
          );
          final gsOut = (ias + outTail).clamp(30.0, 220.0);
          final timeOut = missionDistance / gsOut;
          final fuelOut = burnPerHr * timeOut;
          if (bestFuelForThisOut == null || fuelOut < bestFuelForThisOut) {
            bestFuelForThisOut = fuelOut;
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

        double? bestFuelForThisBack;
        double? bestIasForThisBack;
        for (final ias in candidateIas) {
          final tq = getTorqueForIAS(
            alt.toInt(),
            temperature.toInt(),
            ias.toDouble(),
          );
          final burnPerHr = interpolateFuelBurn(
            tq,
            alt.toInt(),
            temperature.toInt(),
          );
          final gsBack = (ias + backTail).clamp(30.0, 220.0);
          final timeBack = missionDistance / gsBack;
          final fuelBack = burnPerHr * timeBack;
          if (bestFuelForThisBack == null || fuelBack < bestFuelForThisBack) {
            bestFuelForThisBack = fuelBack;
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
      }

      double? combinedSeparateFuel =
          (bestOutFuel != null && bestBackFuel != null)
          ? (bestOutFuel + bestBackFuel)
          : null;

      double? chosenOutTail;
      double? chosenBackTail;
      double? chosenSingleAlt = bestSingleAlt;
      double? chosenSingleOut = bestSingleOut;
      double? chosenSingleBack = bestSingleBack;

      if (combinedSeparateFuel != null &&
          bestSingleFuel != null &&
          combinedSeparateFuel < bestSingleFuel) {
        if (bestOutAlt != null) {
          chosenOutTail = _tailOutBack(bestOutAlt, trackDeg, baseLevels)['out'];
        }
      }
      if (bestBackAlt != null) {
        chosenBackTail = _tailOutBack(
          bestBackAlt,
          trackDeg,
          baseLevels,
        )['back'];
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
        'AI_CHOICE: singleAlt=$chosenSingleAlt singleFuel=$bestSingleFuel outAlt=$bestOutAlt outFuel=$bestOutFuel backAlt=$bestBackAlt backFuel=$bestBackFuel combinedSeparateFuel=$combinedSeparateFuel',
      );
    } catch (e) {
      // ignore network / parse errors silently
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
    temperature = _parseNumber(temperatureController.text);
    fuelOnboard = _parseNumber(fuelController.text);
    // if Bell 412 selected, user enters lbs -> convert to kg for internal calcs
    if (_selectedAircraft == 'Bell 412') {
      fuelOnboard = lbsToKg(fuelOnboard);
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
    final w1Lat = _parseCoord(waypoint1LatController.text, isLat: true);
    final w1Lon = _parseCoord(waypoint1LonController.text, isLat: false);
    final destLat = _parseCoord(destLatController.text, isLat: true);
    final destLon = _parseCoord(destLonController.text, isLat: false);
    final hLat = _parseCoord(hospitalLatController.text, isLat: true);
    final hLon = _parseCoord(hospitalLonController.text, isLat: false);

    if (autoDistanceFromLatLon) {
      // Build ordered sequence: Origin -> Hospital (if used) -> Waypoint1 (if used) -> Destination
      double totalDistance = 0.0;
      final seq = <LatLng>[];
      if (originLat.isFinite && originLon.isFinite) {
        seq.add(LatLng(originLat, originLon));
      }
      if (useHospitalWaypoint && hLat.isFinite && hLon.isFinite) {
        seq.add(LatLng(hLat, hLon));
      }
      if (useWaypoint1 && w1Lat.isFinite && w1Lon.isFinite) {
        seq.add(LatLng(w1Lat, w1Lon));
      }
      if (destLat.isFinite && destLon.isFinite) {
        seq.add(LatLng(destLat, destLon));
      }

      if (seq.length >= 2) {
        for (int i = 0; i < seq.length - 1; i++) {
          totalDistance += _gcDistanceNm(
            seq[i].latitude,
            seq[i].longitude,
            seq[i + 1].latitude,
            seq[i + 1].longitude,
          );
        }
        missionDistance = totalDistance;
        missionDistanceController.text = totalDistance.toStringAsFixed(0);
      }
      // if seq < 2 we leave missionDistance as parsed from the input field
    }
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
    if (destLat.isFinite) destLatController.text = destLat.toStringAsFixed(6);
    if (destLon.isFinite) destLonController.text = destLon.toStringAsFixed(6);

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

        if (_aiTailwindOutKts != null) tailwindOut = _aiTailwindOutKts!;
        if (_aiTailwindBackKts != null) tailwindBack = _aiTailwindBackKts!;

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

    // Hoist / hover
    final hoistBlocks = (extraHoistMinutes / 5.0).ceil();
    final hoistMinutesRounded = hoistBlocks * 5.0;
    final hoistHours = hoistMinutesRounded / 60.0;
    final hoistFuel = hoistHours * 450;

    final fuelForMission = adjustedFuelBurn * cruiseDuration;
    final fuelRemainingAfterMission = fuelOnboard - fuelForMission - hoistFuel;
    final postMissionLowFuel = fuelRemainingAfterMission < 180;
    final missionDuration = cruiseDuration + hoistHours;

    setState(() {
      _lastRequiredTorque = perf['recommendedTorque']!;
      _lastAdjustedFuelBurn = adjustedFuelBurn;
      _lastFuelRemaining = fuelRemainingAfterMission;
    });

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
    );
  } // end calculateCruise
} // end CruiseInputScreenState
