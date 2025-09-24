import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // <-- add this
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

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

Widget buildInputField(String label, TextEditingController controller) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      keyboardType: TextInputType.number,
      style: const TextStyle(color: Colors.white),
    ),
  );
}

// make buildMiniBarChart a TOP-LEVEL function (not inside any other function/class)
Widget buildMiniBarChart({
  required String title,
  required double value,
  required Color color,
  required double maxY,
  required String unit,
  double height = 320, // taller charts
}) {
  final safeMaxY = (maxY.isFinite && maxY > 0) ? maxY : 100.0;
  final displayValue = (value.isFinite ? value : 0)
      .clamp(0, safeMaxY)
      .roundToDouble();
  final interval = _niceInterval(safeMaxY, targetTicks: 10); // more labels

  return SizedBox(
    height: height,
    width: double.infinity,
    child: IgnorePointer(
      ignoring: kIsWeb, // set to false if you want hover/tap tooltips
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
              topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 36, // space for 2 lines
                  getTitlesWidget: (v, m) => SizedBox(
                    height: 32,
                    child: Text(
                      title,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.visible,
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
          swapAnimationDuration: Duration.zero,
          swapAnimationCurve: Curves.linear,
        ),
      ),
    ),
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
// ...existing code...
// ...inside class _CruiseInputScreenState, right after } // closes calculateCruise()

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
  double? aiAltitudeFt, // NEW
  double? aiTailwindKts, // NEW
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

                Text('Endurance: ${endurance.toStringAsFixed(2)} hrs'),
                Text(
                  'Estimated Range: ${estimatedRange.toStringAsFixed(0)} NM',
                ),
                Text(
                  'Mission Distance (RT): ${missionDistance.toStringAsFixed(0)} NM',
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
                Text(
                  'Fuel Burn Rate: ${adjustedFuelBurn.toStringAsFixed(1)} kg/hr',
                ),
                if (aiAltitudeFt != null && aiTailwindKts != null)
                  Text(
                    'AI: Suggested altitude ~${aiAltitudeFt!.toStringAsFixed(0)} ft '
                    '(${aiTailwindKts!.toStringAsFixed(0)} kt tailwind)',
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
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: buildMiniBarChart(
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
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: buildMiniBarChart(
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
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: buildMiniBarChart(
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

// ...existing code...

// ...existing code...

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
  // repeated row for missing value
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
  // Find closest altitude
  final altKeys = fuelBurnTables.keys.toList()..sort();
  int closestAlt = altKeys.reduce(
    (a, b) => (a - altitude).abs() < (b - altitude).abs() ? a : b,
  );

  // Find closest temperature
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
  // Find closest altitude
  final altKeys = speedTables.keys.toList()..sort();
  int closestAlt = altKeys.reduce(
    (a, b) => (a - altitude).abs() < (b - altitude).abs() ? a : b,
  );

  // Find closest temperature
  final tempTable = speedTables[closestAlt]!;
  final tempKeys = tempTable.keys.toList()..sort();
  int closestTemp = tempKeys.reduce(
    (a, b) => (a - oat).abs() < (b - oat).abs() ? a : b,
  );

  final table = tempTable[closestTemp]!;
  final tqKeys = table.keys.toList()..sort();

  // Debug output
  print('DEBUG: Altitude=$altitude, Temp=$oat, IAS=$ias');
  print('DEBUG: Table=$table');

  // Find the two torque keys whose speeds bracket the requested IAS
  for (int i = 0; i < tqKeys.length - 1; i++) {
    double lowerIAS = table[tqKeys[i]]!;
    double upperIAS = table[tqKeys[i + 1]]!;
    if (ias >= lowerIAS && ias <= upperIAS) {
      double ratio = (ias - lowerIAS) / (upperIAS - lowerIAS);
      return tqKeys[i] + ratio * (tqKeys[i + 1] - tqKeys[i]);
    }
  }
  // If IAS is below/above range, return closest torque value
  if (ias < table[tqKeys.first]!) return tqKeys.first.toDouble();
  if (ias > table[tqKeys.last]!) return tqKeys.last.toDouble();
  // If not found, return closest torque
  int closestTorque = tqKeys.reduce(
    (a, b) => (table[a]! - ias).abs() < (table[b]! - ias).abs() ? a : b,
  );
  return closestTorque.toDouble();
}

// --- Correction factor logic ---
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

// --- Main calculation logic ---
Map<String, double> calculateCruisePerformance({
  required double distance,
  required double cruiseSpeed,
  required int altitude,
  required int temperature,
  required bool roundTrip,
  required double cf, // equipment correction factor
}) {
  // Get base torque from chart for IAS, altitude, temperature
  double baseTorqueReference = getTorqueForIAS(
    altitude,
    temperature,
    cruiseSpeed,
  );
  // Add equipment penalty as a percentage
  const double maxCf = 1.1; // sum of all equipment correction factors
  double requiredTorque = baseTorqueReference * (1 + (cf / maxCf) * 0.11);
  print(
    'DEBUG: baseTorqueReference=$baseTorqueReference, cf=$cf, requiredTorque=$requiredTorque',
  );

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

// --- Equipment toggles widget ---
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
  // ...existing code...
}

// --- Replace your _CruiseInputScreenState toggles and calculation ---
class CruiseInputScreen extends StatefulWidget {
  const CruiseInputScreen({super.key});
  @override
  _CruiseInputScreenState createState() => _CruiseInputScreenState();
}

class _CruiseInputScreenState extends State<CruiseInputScreen> {
  double cruiseSpeed = 130;
  double missionDistance = 100;
  double altitude = 2000;
  double temperature = 20;
  double weight = 6400;
  double fuelOnboard = 1200;
  double extraHoistMinutes = 0;
  double? _lastRequiredTorque, _lastAdjustedFuelBurn, _lastFuelRemaining;

  final cruiseSpeedController = TextEditingController();
  final missionDistanceController = TextEditingController();
  final altitudeController = TextEditingController();
  final temperatureController = TextEditingController();
  final weightController = TextEditingController();
  final fuelController = TextEditingController();
  final hoistTimeController = TextEditingController();

  bool selectAllOptional = false;
  bool searchlight = false;
  bool radar = false;
  bool flir = false;
  bool hoist = false;
  // Winds Aloft toggles and inputs
  bool useWindsAloft = false; // master on/off
  bool standardWinds = true; // if true, assume 0 kt winds
  bool useDeviceLocation = true; // origin from GPS; else manual
  final originLatController = TextEditingController();
  final originLonController = TextEditingController();
  final destLatController = TextEditingController();
  final destLonController = TextEditingController();

  // AI suggestion outputs
  double? _aiSuggestedAltitudeFt; // among 2000/4000/6000
  double? _aiTailwindKts; // tailwind at suggested altitude

  @override
  void initState() {
    super.initState();
    // Existing initializations
    cruiseSpeedController.text = cruiseSpeed.toString();
    missionDistanceController.text = missionDistance.toString();
    altitudeController.text = altitude.toString();
    temperatureController.text = temperature.toString();
    weightController.text = weight.toString();
    fuelController.text = fuelOnboard.toString();
    hoistTimeController.text = extraHoistMinutes.toString();

    // Winds aloft controllers
    originLatController.text = '';
    originLonController.text = '';
    destLatController.text = '';
    destLonController.text = '';
  }

  @override
  Widget build(BuildContext context) {
    // Replace this with your actual UI layout.
    return Scaffold(
      appBar: AppBar(title: const Text('AW139 Cruise Planner v4')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;

          // Left panel: form
          final form = Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildInputField(
                    'Cruise Speed (knots)',
                    cruiseSpeedController,
                  ),
                  buildInputField(
                    'Mission Distance (NM)',
                    missionDistanceController,
                  ),
                  buildInputField('Altitude (ft)', altitudeController),
                  buildInputField('Temperature (°C)', temperatureController),
                  buildInputField('Fuel Onboard (kg)', fuelController),
                  buildInputField('Hoist Time (min)', hoistTimeController),
                  const SizedBox(height: 16),
                  // Winds Aloft controls
                  SwitchListTile(
                    title: const Text('Use Winds Aloft'),
                    value: useWindsAloft,
                    onChanged: (v) => setState(() => useWindsAloft = v),
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (useWindsAloft) ...[
                    SwitchListTile(
                      title: const Text('Standard Winds (0 kt)'),
                      value: standardWinds,
                      onChanged: (v) => setState(() => standardWinds = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile(
                      title: const Text('Use device location for Origin'),
                      value: useDeviceLocation,
                      onChanged: (v) => setState(() => useDeviceLocation = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (!useDeviceLocation) ...[
                      buildInputField('Origin Latitude', originLatController),
                      buildInputField('Origin Longitude', originLonController),
                    ],
                    buildInputField(
                      'Destination Latitude (optional)',
                      destLatController,
                    ),
                    buildInputField(
                      'Destination Longitude (optional)',
                      destLonController,
                    ),
                  ],
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
                    onPressed: () async {
                      await calculateCruise();
                    },
                    child: const Text('Calculate'),
                  ),
                ],
              ),
            ),
          );

          // Right panel: charts (visible after Calculate)
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
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: buildMiniBarChart(
                            title: 'Torque %',
                            value: _lastRequiredTorque!,
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
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: buildMiniBarChart(
                            title: 'Fuel Burn\n(kg/hr)',
                            value: _lastAdjustedFuelBurn!,
                            color: Colors.yellow,
                            maxY:
                                ((_lastAdjustedFuelBurn! <= 0
                                        ? 100
                                        : (_lastAdjustedFuelBurn! / 100)
                                                  .ceil() *
                                              100))
                                    .toDouble(),
                            unit: 'kg/hr',
                            height: 320,
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: buildMiniBarChart(
                            title: 'Fuel\nRemaining (kg)',
                            value: _lastFuelRemaining!,
                            color: _lastFuelRemaining! <= 184
                                ? Colors.red
                                : (_lastFuelRemaining! <= 456
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

          // Narrow: stack form then charts
          return SingleChildScrollView(
            child: Column(
              children: [form, const Divider(height: 1), chartsPanel],
            ),
          );
        },
      ),
    );
  }

  Future<void> calculateCruise() async {
    cruiseSpeed = _parseNumber(cruiseSpeedController.text);
    missionDistance = _parseNumber(missionDistanceController.text);
    altitude = _parseNumber(altitudeController.text);
    temperature = _parseNumber(temperatureController.text);
    weight = _parseNumber(weightController.text);
    fuelOnboard = _parseNumber(fuelController.text);
    extraHoistMinutes = _parseNumber(hoistTimeController.text);

    if (!cruiseSpeed.isFinite || cruiseSpeed <= 0) cruiseSpeed = 1;
    if (!missionDistance.isFinite || missionDistance < 0) missionDistance = 0;
    if (!fuelOnboard.isFinite || fuelOnboard < 0) fuelOnboard = 0;
    if (!extraHoistMinutes.isFinite || extraHoistMinutes < 0)
      extraHoistMinutes = 0;

    // Equipment correction
    final cf = getCorrectionFactor(
      searchlight: searchlight,
      radar: radar,
      flir: flir,
      hoist: hoist,
    );
    final perf = calculateCruisePerformance(
      distance: missionDistance,
      cruiseSpeed: cruiseSpeed,
      altitude: altitude.toInt(),
      temperature: temperature.toInt(),
      roundTrip: true,
      cf: cf,
    );
    // Winds aloft (optional)
    double tailwind = 0.0; // + tailwind, - headwind
    _aiSuggestedAltitudeFt = null;
    _aiTailwindKts = null;

    if (useWindsAloft && !standardWinds) {
      double? lat, lon;
      if (useDeviceLocation) {
        final pos = await _getCurrentPosition();
        if (pos != null) {
          lat = pos.latitude;
          lon = pos.longitude;
        }
      }
      lat ??= _parseNumber(originLatController.text);
      lon ??= _parseNumber(originLonController.text);

      final destLat = _parseNumber(destLatController.text);
      final destLon = _parseNumber(destLonController.text);

      if (lat.isFinite &&
          lon.isFinite &&
          destLat.isFinite &&
          destLon.isFinite &&
          (destLat != 0 || destLon != 0)) {
        final trackDeg = _initialBearingDeg(lat, lon, destLat, destLon);
        await _fetchAiAltitudeSuggestion(
          lat: lat,
          lon: lon,
          trackDeg: trackDeg,
        );
        if (_aiTailwindKts != null) tailwind = _aiTailwindKts!;
      }
    }

    // Round-trip timing (one-way d, then back)
    final d = missionDistance;
    final gsOut = (cruiseSpeed + tailwind).clamp(1.0, double.infinity);
    final gsBack = (cruiseSpeed - tailwind).clamp(1.0, double.infinity);
    final cruiseDuration = d / gsOut + d / gsBack;

    final adjustedFuelBurn = perf['fuelBurnPerHour']!;
    final endurance = fuelOnboard / adjustedFuelBurn;
    final estimatedRange = cruiseSpeed * endurance;

    // Hoist fuel (5-min blocks)
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
      aiAltitudeFt: _aiSuggestedAltitudeFt, // NEW
      aiTailwindKts: _aiTailwindKts, // NEW
    );
  }
  // ...inside class _CruiseInputScreenState, paste AFTER calculateCruise() and BEFORE buildMissionChart()

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

  Future<Position?> _getCurrentPosition() async {
    try {
      if (!await _ensureLocationPermission()) return null;
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (_) {
      return null;
    }
  }

  // Fetch winds aloft and suggest best among 2000/4000/6000 ft (nearest levels)
  Future<void> _fetchAiAltitudeSuggestion({
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

      final sp925 = (h['wind_speed_925hPa']?[0] ?? 0).toDouble(); // ~2500 ft
      final dr925 = (h['wind_direction_925hPa']?[0] ?? 0).toDouble();
      final sp850 = (h['wind_speed_850hPa']?[0] ?? 0).toDouble(); // ~5000 ft
      final dr850 = (h['wind_direction_850hPa']?[0] ?? 0).toDouble();
      final sp700 = (h['wind_speed_700hPa']?[0] ?? 0).toDouble(); // ~10000 ft
      final dr700 = (h['wind_direction_700hPa']?[0] ?? 0).toDouble();

      final tail925 = _tailwindKts(sp925, dr925, trackDeg);
      final tail850 = _tailwindKts(sp850, dr850, trackDeg);
      final tail700 = _tailwindKts(sp700, dr700, trackDeg);

      // Map to 2000/4000/6000 ft by nearest pressure level
      final candidates = <double, double>{
        2000: tail925, // near 2500
        4000: tail850, // near 5000
        6000: tail850, // near 5000
      };

      final best = candidates.entries.reduce(
        (a, b) => a.value >= b.value ? a : b,
      );
      setState(() {
        _aiSuggestedAltitudeFt = best.key;
        _aiTailwindKts = best.value;
      });
    } catch (_) {
      // ignore network errors
    }
  }

  // Keep these as methods on the State class (outside calculateCruise)
  Widget buildMissionChart({
    required double requiredTorque,
    required double fuelBurn,
    required double fuelRemaining,
  }) {
    double maxChartY = [
      requiredTorque,
      fuelBurn,
      fuelRemaining,
      200.0,
    ].reduce((a, b) => a > b ? a : b);
    maxChartY = (maxChartY / 100).ceil() * 100;

    return SizedBox(
      height: 200,
      width: double.infinity,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxChartY,
          minX: 1,
          maxX: 5,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 100,
          ),
          titlesData: FlTitlesData(
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 100,
                getTitlesWidget: (value, meta) => Text(
                  value.toInt().toString(),
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                getTitlesWidget: (value, meta) => Text(
                  value.toInt().toString(),
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [FlSpot(1, requiredTorque), FlSpot(5, requiredTorque)],
              isCurved: false,
              color: Colors.orange,
              barWidth: 4,
              dotData: FlDotData(show: false),
            ),
            LineChartBarData(
              spots: [
                FlSpot(1, fuelBurn.roundToDouble()),
                FlSpot(5, fuelBurn.roundToDouble()),
              ],
              isCurved: false,
              color: Colors.yellow,
              barWidth: 4,
              dotData: FlDotData(show: false),
            ),
            LineChartBarData(
              spots: [
                FlSpot(1, fuelRemaining.roundToDouble()),
                FlSpot(5, fuelRemaining.roundToDouble()),
              ],
              isCurved: false,
              color: Colors.green,
              barWidth: 4,
              dotData: FlDotData(show: false),
            ),
          ],
          lineTouchData: LineTouchData(enabled: false),
        ),
      ),
    );
  }
}

// ...existing code...
// ...existing code...

void main() {
  runApp(
    MaterialApp(
      home: CruiseInputScreen(),
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
    ),
  );
}
