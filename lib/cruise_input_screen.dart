import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:aw139_cruise/export/cruise_report_export.dart'; // <-- add this line
import 'package:flutter/foundation.dart' show kIsWeb; // <-- add this
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:async';

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
  ).allMatches(s).map((m) => double.parse(m.group(0)!)).toList();

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

// ...existing code...

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
  double? aiAltitudeFt,
  double? aiTailwindKts,
  double? aiTailwindOutKts,
  double? aiTailwindBackKts,
  double? aiSuggestedIas,
  double? originLat,
  double? originLon,
  double? destLat,
  double? destLon,
}) {
  final int fuelRemRounded = fuelRemaining.round();

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
                Text(
                  'Round Trip Distance: ${(missionDistance * 2).toStringAsFixed(0)} NM',
                ),
                Text(
                  'Mission Duration: ${missionDuration.toStringAsFixed(2)} hrs',
                ),
                Text(
                  'Hoist Time (rounded): ${hoistMinutesRounded.toStringAsFixed(0)} min',
                ),
                Text('Hoist Fuel: ${hoistFuel.toStringAsFixed(0)} kg'),

                Text(
                  'Fuel Remaining: $fuelRemRounded kg',
                  style: TextStyle(
                    color: fuelRemRounded <= 184
                        ? Colors.red
                        : (fuelRemRounded <= 456
                              ? Colors.orange
                              : Colors.white),
                    fontWeight: fuelRemRounded <= 456
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
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

                // AI suggestions
                if (aiAltitudeFt != null && aiTailwindKts != null)
                  Text(
                    'AI: Suggested altitude ~${aiAltitudeFt.toStringAsFixed(0)} ft '
                    '(${aiTailwindKts.toStringAsFixed(0)} kt avg tailwind)',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                if (aiTailwindOutKts != null && aiTailwindBackKts != null)
                  Text(
                    'AI winds: Out ${aiTailwindOutKts.toStringAsFixed(0)} kt | '
                    'Back ${aiTailwindBackKts.toStringAsFixed(0)} kt',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                if (aiSuggestedIas != null)
                  Text(
                    'AI: Suggested cruise ≈ ${aiSuggestedIas.toStringAsFixed(0)} kts',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
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

                const SizedBox(height: 12),
                const Divider(thickness: 1, color: Colors.grey),
                const SizedBox(height: 8),

                // Charts row (horizontal scroll if narrow)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                            title: 'Fuel Burn\n(kg/hr)',
                            value: adjustedFuelBurn,
                            color: Colors.yellow,
                            maxY:
                                ((adjustedFuelBurn <= 0
                                        ? 100
                                        : (adjustedFuelBurn / 100).ceil() *
                                              100))
                                    .toDouble(),
                            unit: 'kg/hr',
                            height: 240,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
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
                            title: 'Fuel\nRemaining (kg)',
                            value: fuelRemaining,
                            color: fuelRemRounded <= 184
                                ? Colors.red
                                : (fuelRemRounded <= 456
                                      ? Colors.orange
                                      : Colors.green),
                            maxY: 500,
                            unit: 'kg',
                            height: 240,
                          ),
                        ),
                      ),
                    ],
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
  CruiseReportData? _lastReport;

  // AI suggestions
  double? _aiSuggestedAltitudeFt;
  double? _aiTailwindKts;
  double? _aiTailwindOutKts;
  double? _aiTailwindBackKts;
  double? _aiSuggestedIas;

  double interpolateWind(double windSpeed) {
    // Example logic — adjust as needed
    return windSpeed * 0.85;
  }

  Map<int, Map<String, double>>? _aiWindsAloft;
  Map<int, Map<String, double>>? _departureWindsAloft;
  Map<int, Map<String, double>>? _destinationWindsAloft;

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

  @override
  void initState() {
    super.initState();
    cruiseSpeedController.text = cruiseSpeed.toStringAsFixed(0);
    missionDistanceController.text = missionDistance.toStringAsFixed(0);
    altitudeController.text = altitude.toStringAsFixed(0);
    temperatureController.text = temperature.toStringAsFixed(0);
    fuelController.text = fuelOnboard.toStringAsFixed(0);
    hoistTimeController.text = extraHoistMinutes.toStringAsFixed(0);
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
                  buildInputField('Fuel Onboard (kg)', fuelController),
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
                                width: 600,
                                height: 400,
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
                                    Opacity(
                                      opacity: 0.4,
                                      child: TileLayer(
                                        urlTemplate:
                                            'https://tile.openweathermap.org/map/clouds_new/{z}/{x}/{y}.png?appid=YOUR_API_KEY',
                                      ),
                                    ),
                                    Opacity(
                                      opacity: 0.5,
                                      child: TileLayer(
                                        urlTemplate:
                                            'https://tile.openweathermap.org/map/precipitation_new/{z}/{x}/{y}.png?appid=YOUR_API_KEY',
                                      ),
                                    ),
                                    Opacity(
                                      opacity: 0.7,
                                      child: TileLayer(
                                        urlTemplate:
                                            'https://tile.openweathermap.org/map/wind_new/{z}/{x}/{y}.png?appid=YOUR_API_KEY',
                                      ),
                                    ),
                                    PolylineLayer(
                                      polylines: [
                                        Polyline(
                                          points: [
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
                    onChanged: (v) => setState(() {
                      useWaypoint1 = v;
                      _validateAndDistance();
                    }),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
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
                                'Suggested IAS: ${_aiSuggestedIas!.toStringAsFixed(0)} kt',
                                style: const TextStyle(color: Colors.white),
                              ),
                            if (_aiSuggestedAltitudeFt != null)
                              Text(
                                'Suggested Altitude: ${_aiSuggestedAltitudeFt!.toStringAsFixed(0)} ft',
                                style: const TextStyle(color: Colors.white),
                              ),
                            if (_aiTailwindOutKts != null &&
                                _aiTailwindBackKts != null)
                              Builder(
                                builder: (_) {
                                  final out = _aiTailwindOutKts!;
                                  final back = _aiTailwindBackKts!;
                                  final avg = (out + back) / 2.0;
                                  return Text(
                                    'Tailwind (Out / Back): '
                                    '${out.toStringAsFixed(0)} / '
                                    '${back.toStringAsFixed(0)} kt  '
                                    '(Avg ${avg.toStringAsFixed(0)} kt)',
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
                  ElevatedButton(
                    onPressed: _calculating
                        ? null
                        : () async {
                            setState(() => _calculating = true);
                            try {
                              await calculateCruise();
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
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          )
                        : const Text('Calculate'),
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.air),
                    label: const Text('Show Winds Aloft'),
                    onPressed: () async {
                      // Fetch wind aloft for both locations (reuse your _fetchAiAltitudeSuggestion)
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

                      if (originLat.isFinite && originLon.isFinite) {
                        await fetchAiAltitudeSuggestion(
                          lat: originLat,
                          lon: originLon,
                          trackDeg: 0,
                        );
                        _departureWindsAloft =
                            _aiWindsAloft; // Save departure winds
                      }
                      if (destLat.isFinite && destLon.isFinite) {
                        await fetchAiAltitudeSuggestion(
                          lat: destLat,
                          lon: destLon,
                          trackDeg: 0,
                        );
                        _destinationWindsAloft =
                            _aiWindsAloft; // Save destination winds
                      }

                      showDialog(
                        // ignore: use_build_context_synchronously
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Winds Aloft'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Departure Winds Aloft:'),
                              // Departure Winds Aloft
                              if (_departureWindsAloft != null &&
                                  _departureWindsAloft!.isNotEmpty)
                                ..._departureWindsAloft!.entries.map(
                                  (e) => Text(
                                    'Altitude: ${e.key} ft, Tailwind: ${e.value['tailwind']?.toStringAsFixed(0) ?? '--'} kt '
                                    ' (Dir: ${e.value['dir']?.toStringAsFixed(0) ?? '--'}°)',
                                  ),
                                ),
                              if (_departureWindsAloft == null ||
                                  _departureWindsAloft!.isEmpty)
                                Text('No winds aloft data available'),
                              const SizedBox(height: 12),
                              Text('Destination Winds Aloft:'),
                              if (_destinationWindsAloft != null &&
                                  _destinationWindsAloft!.isNotEmpty)
                                ..._destinationWindsAloft!.entries.map(
                                  (e) => Text(
                                    'Altitude: ${e.key} ft, Tailwind: ${e.value['tailwind']?.toStringAsFixed(0) ?? '--'} kt '
                                    '(Dir: ${e.value['dir']?.toStringAsFixed(0) ?? '--'}°)',
                                  ),
                                ),
                              if (_destinationWindsAloft == null ||
                                  _destinationWindsAloft!.isEmpty)
                                Text('No winds aloft data available'),
                              if (_departureWindsAloft != null &&
                                  _destinationWindsAloft != null &&
                                  !_mapEquals(
                                    _departureWindsAloft!,
                                    _destinationWindsAloft!,
                                  ))
                                const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Text(
                                    '⚠️ Winds aloft differ between departure and destination!',
                                    style: TextStyle(color: Colors.orange),
                                  ),
                                ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _lastReport == null
                              ? null
                              : () =>
                                    CruiseReportExporter.preview(_lastReport!),
                          icon: const Icon(Icons.print),
                          label: const Text('PDF / Print'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _lastReport == null
                              ? null
                              : () => CruiseReportExporter.share(_lastReport!),
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
          // local snapshot values for charts (avoid IIFE inside children)
          final chartTorque = _lastRequiredTorque ?? 0;
          final chartBurn = _lastAdjustedFuelBurn ?? 0;
          final chartFuelRem = _lastFuelRemaining ?? 0;

          final chartsPanel = Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
            child: (_lastRequiredTorque == null)
                ? const Text('Press Calculate to show charts')
                : SingleChildScrollView(
                    child: Column(
                      children: [
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
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title: 'Fuel Burn\n(kg/hr)',
                            value: chartBurn,
                            color: Colors.yellow,
                            maxY:
                                ((chartBurn <= 0
                                        ? 100
                                        : (chartBurn / 100).ceil() * 100))
                                    .toDouble(),
                            unit: 'kg/hr',
                            height: 320,
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade700),
                          ),
                          child: swapAnimationCurvebuildMiniBarChart(
                            title: 'Fuel\nRemaining (kg)',
                            value: chartFuelRem,
                            color: chartFuelRem <= 184
                                ? Colors.red
                                : (chartFuelRem <= 456
                                      ? Colors.orange
                                      : Colors.green),
                            maxY: 500,
                            unit: 'kg',
                            height: 320,
                          ),
                        ),
                      ],
                    ),
                  ),
          );

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

  // _interpolateWind implementation moved to class scope above

  // ---------- IAS Suggestion ----------
  Map<String, double>? suggestBestIas({
    required int altFt,
    required int oatC,
    required double tailwindOutKts,
    required double tailwindBackKts,
    required double distanceNmOneWay,
  }) {
    const candidates = [120, 125, 130, 135, 140, 145, 150, 155, 160];
    double? bestFuel;
    Map<String, double>? best;
    for (final ias in candidates) {
      final tq = getTorqueForIAS(altFt, oatC, ias.toDouble());
      final burnPerHr = interpolateFuelBurn(tq, altFt, oatC);
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

  Future<void> fetchAiAltitudeSuggestion({
    required double lat,
    required double lon,
    required double trackDeg,
  }) async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon'
      '&hourly=wind_speed_925hPa,wind_direction_925hPa,'
      'wind_speed_850hPa,wind_direction_850hPa,'
      'wind_speed_700hPa,wind_direction_700hPa'
      '&forecast_days=1',
    );
    try {
      final res = await http.get(uri);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final h = data['hourly'] as Map<String, dynamic>;

      final sp925 = (h['wind_speed_925hPa']?[0] ?? 0).toDouble();
      final dr925 = (h['wind_direction_925hPa']?[0] ?? 0).toDouble();
      final sp850 = (h['wind_speed_850hPa']?[0] ?? 0).toDouble();
      final dr850 = (h['wind_direction_850hPa']?[0] ?? 0).toDouble();
      final sp700 = (h['wind_speed_700hPa']?[0] ?? 0).toDouble();
      final dr700 = (h['wind_direction_700hPa']?[0] ?? 0).toDouble();

      // Paste here (after parsing wind data)
      final tailwind2000 = _tailwindKts(sp925, dr925, trackDeg);
      final tailwind4000 = _tailwindKts(sp850, dr850, trackDeg);
      final tailwind6000 = _tailwindKts(sp700, dr700, trackDeg);

      _aiWindsAloft = {
        2000: {'tailwind': tailwind2000, 'dir': dr925},
        4000: {'tailwind': tailwind4000, 'dir': dr850},
        6000: {'tailwind': tailwind6000, 'dir': dr700},
      };

      // Base anchor levels (ft)
      final baseLevels = <Map<String, double>>[
        {'alt': 2000, 'speed': sp925, 'dirFrom': dr925},
        {'alt': 4000, 'speed': sp850, 'dirFrom': dr850},
        {'alt': 6000, 'speed': sp700, 'dirFrom': dr700},
      ];

      final candidateAltitudes = <double>[2000, 3000, 4000, 5000, 6000];

      double? bestAlt;
      double? bestFuel;
      double? bestIas;
      double? bestOut;
      double? bestBack;

      for (final alt in candidateAltitudes) {
        final tails = _tailOutBack(alt, trackDeg, baseLevels);
        final outTail = tails['out']!;
        final backTail = tails['back']!;

        final opt = suggestBestIas(
          altFt: alt.toInt(),
          oatC: temperature.toInt(),
          tailwindOutKts: outTail,
          tailwindBackKts: backTail,
          distanceNmOneWay: missionDistance,
        );
        if (opt == null) continue;
        final fuel = opt['fuel']!;
        if (bestFuel == null || fuel < bestFuel) {
          bestFuel = fuel;
          bestAlt = alt;
          bestIas = opt['ias'];
          bestOut = outTail;
          bestBack = backTail;
        }
      }

      if (mounted) {
        setState(() {
          _aiSuggestedAltitudeFt = bestAlt;
          _aiSuggestedIas = bestIas;
          _aiTailwindOutKts = bestOut;
          _aiTailwindBackKts = bestBack;
          _aiTailwindKts = bestOut != null && bestBack != null
              ? (bestOut + bestBack) / 2
              : null;
        });
      }
    } catch (_) {
      // ignore
    }
  }

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

  Future<void> calculateCruise() async {
    // Parse inputs
    cruiseSpeed = _parseNumber(cruiseSpeedController.text);
    altitude = _parseNumber(altitudeController.text);
    temperature = _parseNumber(temperatureController.text);
    fuelOnboard = _parseNumber(fuelController.text);
    extraHoistMinutes = _parseNumber(hoistTimeController.text);

    // Input validation
    if (!cruiseSpeed.isFinite || cruiseSpeed <= 0) {
      cruiseSpeed = 1;
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
    // ...existing code...
    final originLat = _parseCoord(originLatController.text, isLat: true);
    final originLon = _parseCoord(originLonController.text, isLat: false);
    final w1Lat = _parseCoord(waypoint1LatController.text, isLat: true);
    final w1Lon = _parseCoord(waypoint1LonController.text, isLat: false);
    final destLat = _parseCoord(destLatController.text, isLat: true);
    final destLon = _parseCoord(destLonController.text, isLat: false);
    final hLat = _parseCoord(hospitalLatController.text, isLat: true);
    final hLon = _parseCoord(hospitalLonController.text, isLat: false);

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
    }

    missionDistance = totalDistance;
    missionDistanceController.text = totalDistance.toStringAsFixed(0);
    // ...existing code...
    // Base performance (may change if AI auto-applies)
    var perf = calculateCruisePerformance(
      distance: missionDistance,
      cruiseSpeed: cruiseSpeed,
      altitude: altitude.toInt(),
      temperature: temperature.toInt(),
      roundTrip: true,
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
              roundTrip: true,
              cf: cf,
            );
            setState(() {}); // reflect controller changes
          }
        }
      }
    }

    // Final calculations
    final d = missionDistance;
    final gsOut = (cruiseSpeed + tailwindOut).clamp(1.0, double.infinity);
    final gsBack = (cruiseSpeed + tailwindBack).clamp(1.0, double.infinity);
    final cruiseDuration = d / gsOut + d / gsBack;

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
      aiAltitudeFt: _aiSuggestedAltitudeFt,
      aiTailwindKts: _aiTailwindKts,
      aiTailwindOutKts: _aiTailwindOutKts,
      aiTailwindBackKts: _aiTailwindBackKts,
      aiSuggestedIas: _aiSuggestedIas,
      originLat: originLat.isFinite ? originLat : null,
      originLon: originLon.isFinite ? originLon : null,
      destLat: destLat.isFinite ? destLat : null,
      destLon: destLon.isFinite ? destLon : null,
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
      tailwinds[k] = (v['tailwind'] ?? 0).toDouble();
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
