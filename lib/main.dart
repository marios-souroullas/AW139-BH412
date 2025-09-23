import 'package:flutter/material.dart';

// Your OEI data model
class OEICruiseData {
  final double altitude;
  final double temperature;
  final double speed;
  final double torque;
  final double fuelBurn;

  OEICruiseData(this.altitude, this.temperature, this.speed, this.torque, this.fuelBurn);
}

// Sample OEI data
final List<OEICruiseData> oeiCruiseTable = [
  OEICruiseData(0, -20, 120, 125, 620),
  OEICruiseData(0, 20, 115, 130, 640),
  OEICruiseData(2000, 20, 115, 132, 660),
  OEICruiseData(4000, 20, 110, 135, 680),
  OEICruiseData(6000, 40, 105, 138, 700),
];

// App entrypoint
void main() => runApp(const AW139CruiseApp());

class AW139CruiseApp extends StatelessWidget {
  const AW139CruiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AW139 Cruise Planner v4',
      theme: ThemeData.dark(),
      home: const CruiseInputScreen(), // ✅ This launches your custom screen
      debugShowCheckedModeBanner: false,
    );
  }
}

class CruiseInputScreen extends StatefulWidget {
  const CruiseInputScreen({super.key});

  @override
  _CruiseInputScreenState createState() => _CruiseInputScreenState();
}

class _CruiseInputScreenState extends State<CruiseInputScreen> {
  double adjustedFuelBurn = 0.0;
  double cruiseSpeed = 130;
  double missionDistance = 100;
  double altitude = 2000;
  double temperature = 20;
  double weight = 6000;
  double fuelOnboard = 1200;
  double extraHoistMinutes = 0;

  final cruiseSpeedController = TextEditingController();
  final missionDistanceController = TextEditingController();
  final altitudeController = TextEditingController();
  final temperatureController = TextEditingController();
  final weightController = TextEditingController();
  final fuelController = TextEditingController();
  final hoistTimeController = TextEditingController();

  bool selectAllOptional = false;
  bool searchlight = false;
  bool radarTelephonic = false;
  bool flir = false;
  bool goodrichHoist = false;
  bool hoistingMission = false;
  bool emergencyModeEnabled = false;

  List<Map<String, dynamic>> missionTimeline = [];

  @override
  void dispose() {
    cruiseSpeedController.dispose();
    missionDistanceController.dispose();
    altitudeController.dispose();
    temperatureController.dispose();
    weightController.dispose();
    fuelController.dispose();
    hoistTimeController.dispose();
    super.dispose();
  }

  OEICruiseData getOEICruiseData(double altitude, double temperature) {
    return oeiCruiseTable.reduce((a, b) {
      double aScore = (a.altitude - altitude).abs() + (a.temperature - temperature).abs();
      double bScore = (b.altitude - altitude).abs() + (b.temperature - temperature).abs();
      return aScore < bScore ? a : b;
    });
  }

    Widget buildInputField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget buildToggle(String label, bool value, void Function(bool) onChanged, IconData icon) {
    return FilterChip(
      avatar: Icon(icon, color: Colors.greenAccent),
      label: Text(label),
      selected: value,
      onSelected: onChanged,
      selectedColor: Colors.orange,
      backgroundColor: Colors.grey[800],
      labelStyle: const TextStyle(color: Colors.greenAccent),
    );
  }

  double estimateFuelBurn(double torque) {
    const Map<int, double> table = {
      50: 370,
      60: 410,
      70: 450,
      80: 490,
      90: 530,
      100: 570,
    };
    final keys = table.keys.toList()..sort();
    for (int i = 0; i < keys.length - 1; i++) {
      final double lower = keys[i].toDouble();
      final double upper = keys[i + 1].toDouble();
      if (torque >= lower && torque <= upper) {
        final ratio = (torque - lower) / (upper - lower);
        return table[lower.toInt()]! +
            ratio * (table[upper.toInt()]! - table[lower.toInt()]!);
      }
    }
    return table[keys.last]!;
  }

  void calculateCruise() {
    // 1. Read inputs
    setState(() {
      cruiseSpeed = double.tryParse(cruiseSpeedController.text) ?? cruiseSpeed;
      missionDistance =
          double.tryParse(missionDistanceController.text) ?? missionDistance;
      altitude = double.tryParse(altitudeController.text) ?? altitude;
      temperature =
          double.tryParse(temperatureController.text) ?? temperature;
      weight = double.tryParse(weightController.text) ?? weight;
      fuelOnboard = double.tryParse(fuelController.text) ?? fuelOnboard;
      extraHoistMinutes =
          double.tryParse(hoistTimeController.text) ?? 0.0;
    });

    // 2. Base performance
    double desiredSpeed = cruiseSpeed;
    double baseTorqueReference = 60;
    double hourlyBurnRate = 400;

    // 3. Override with OEI if needed
    if (emergencyModeEnabled) {
      final oei = getOEICruiseData(altitude, temperature);
      desiredSpeed = oei.speed;
      hourlyBurnRate = oei.fuelBurn;
      baseTorqueReference = oei.torque.clamp(0, 140);
    }

    // 4. Torque adjustment
    final speedDelta = desiredSpeed - 150;
    double torqueAdjustment = speedDelta * 1.5;
    torqueAdjustment += (weight - 6000) / 1000 * 5;
    torqueAdjustment += (altitude / 10000) * 3;
    torqueAdjustment += (temperature / 50) * 2;

    // 5. Equipment correction
    double correctionFactor = 0.0;
    if (searchlight) correctionFactor += 0.3;
    if (radarTelephonic) correctionFactor += 0.3;
    if (flir) correctionFactor += 0.3;
    if (goodrichHoist) correctionFactor += 0.2;

    // 6. Final torque & fuel burn
    double requiredTorque =
        (baseTorqueReference + torqueAdjustment) * (1 + correctionFactor);
    requiredTorque = requiredTorque.clamp(40, 140);
    adjustedFuelBurn =
        hourlyBurnRate + (requiredTorque - baseTorqueReference) * 1.2;

    // 7. Mission profile
    final extraHoistTime = hoistingMission ? extraHoistMinutes / 60 : 0.0;
    const hoverFuelBurnRate = 450.0;
    final cruiseDuration = missionDistance / cruiseSpeed;
    final fuelForCruise = adjustedFuelBurn * cruiseDuration;
    final fuelForHoisting =
        hoistingMission ? hoverFuelBurnRate * extraHoistTime : 0.0;
    final fuelForMission = fuelForCruise + fuelForHoisting;
    final fuelRemainingAfterMission = fuelOnboard - fuelForMission;
    final postMissionLowFuel = fuelRemainingAfterMission < 180;

    // 8. Endurance & range
    final endurance = fuelOnboard / adjustedFuelBurn;
    final estimatedRange = cruiseSpeed * endurance;
    final missionDuration = cruiseDuration + extraHoistTime;

    // 9. Fuel timeline (every 5 min)
    final fuelTimeline = <double>[];
    const intervalMinutes = 5.0;
    final intervalsPerHour = 60 / intervalMinutes;
    final burnPerInterval = adjustedFuelBurn / intervalsPerHour;
    double currentFuel = fuelOnboard;
    final totalIntervals = (missionDuration * intervalsPerHour).toInt();
    for (int i = 0; i <= totalIntervals; i++) {
      fuelTimeline.add(currentFuel);
      currentFuel = (currentFuel - burnPerInterval).clamp(0.0, double.infinity);
    }

    // 10. Mission timeline (hourly snapshot)
    missionTimeline.clear();
    currentFuel = fuelOnboard;
    double currentWeight = weight;
    double currentTorque = requiredTorque;
    final totalHours = missionDuration.ceil();
    for (int hour = 0; hour <= totalHours; hour++) {
      missionTimeline.add({
        'hour': hour,
        'fuel': currentFuel,
        'weight': currentWeight,
        'torque': currentTorque,
      });
      currentFuel = (currentFuel - adjustedFuelBurn).clamp(0.0, double.infinity);
      currentWeight =
          (currentWeight - adjustedFuelBurn).clamp(0.0, double.infinity);
      currentTorque += 0.5;
    }

    // 11. Show results
    showCruiseResultsDialog(
      context,
      desiredSpeed,
      altitude,
      temperature,
      weight,
      correctionFactor,
      requiredTorque,
      adjustedFuelBurn,
      fuelOnboard,
      endurance,
      estimatedRange,
      missionDistance,
      extraHoistMinutes,
      missionDuration,
      fuelForMission,
      fuelRemainingAfterMission,
      postMissionLowFuel,
      fuelTimeline,
      missionTimeline,
      emergencyModeEnabled,
    );
  }

   // 11. Show results
  void showCruiseResultsDialog(
    BuildContext context,
    double desiredSpeed,
    double altitude,
    double temperature,
    double weight,
    double correctionFactor,
    double requiredTorque,
    double adjustedFuelBurn,
    double fuelOnboard,
    double endurance,
    double estimatedRange,
    double missionDistance,
    double extraHoistMinutes,
    double missionDuration,
    double fuelForMission,
    double fuelRemainingAfterMission,
    bool postMissionLowFuel,
    List<double> fuelTimeline,
    List<Map<String, dynamic>> missionTimeline,
    bool emergencyModeEnabled,
  ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cruise Results v4'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Desired Speed: ${desiredSpeed.toStringAsFixed(1)} knots'),
              Text('Altitude: ${altitude.toStringAsFixed(0)} ft'),
              Text('Temperature: ${temperature.toStringAsFixed(0)} °C'),
              Text('Gross Weight: ${weight.toInt()} kg'),
              const SizedBox(height: 10),
              Text('Correction Factor: ${correctionFactor.toStringAsFixed(2)}'),
              Text('Required Torque: ${requiredTorque.toStringAsFixed(1)} %'),
              Text('Fuel Burn: ${adjustedFuelBurn.toStringAsFixed(1)} kg/hr'),
              Text('Fuel Onboard: ${fuelOnboard.toStringAsFixed(0)} kg'),
              Text('Endurance: ${endurance.toStringAsFixed(2)} hrs'),
              Text('Range: ${estimatedRange.toStringAsFixed(0)} NM'),
              Text('Mission Distance (RT): ${(missionDistance * 2).toStringAsFixed(0)} NM'),
              Text('Hoist Time: ${extraHoistMinutes.toStringAsFixed(0)} min'),
              Text('Mission Duration: ${missionDuration.toStringAsFixed(2)} hrs'),
              Text('Fuel for Mission: ${fuelForMission.toStringAsFixed(0)} kg'),
              Text('Fuel Remaining: ${fuelRemainingAfterMission.toStringAsFixed(0)} kg'),
              if (postMissionLowFuel)
                const Text(
                  'Warning: Low fuel threshold breached!',
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                ),
              if (emergencyModeEnabled)
                const Text(
                  'EMERGENCY MODE: If GEN1 lost, set MAIN BAT switch OFF.',
                  style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AW139 Cruise Planner v4'),
        backgroundColor: Colors.black87,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildInputField('Cruise Speed (knots)', cruiseSpeedController),
            buildInputField('Mission Distance (NM)', missionDistanceController),
            buildInputField('Altitude (ft)', altitudeController),
            buildInputField('Temperature (°C)', temperatureController),
            buildInputField('Gross Weight (kg)', weightController),
            buildInputField('Fuel Onboard (kg)', fuelController),
            buildInputField('Hoist Time (min)', hoistTimeController),
            const SizedBox(height: 10),
            CheckboxListTile(
              title: const Text('Select All Optional Equipment'),
              value: selectAllOptional,
              onChanged: (val) {
                setState(() {
                  selectAllOptional = val ?? false;
                  searchlight = selectAllOptional;
                  radarTelephonic = selectAllOptional;
                  flir = selectAllOptional;
                  goodrichHoist = selectAllOptional;
                });
              },
              controlAffinity: ListTileControlAffinity.leading,
            ),
            Wrap(
              spacing: 8,
              children: [
                buildToggle('Searchlight', searchlight, (v) => setState(() => searchlight = v), Icons.lightbulb),
                buildToggle('Radar', radarTelephonic, (v) => setState(() => radarTelephonic = v), Icons.radar),
                buildToggle('FLIR', flir, (v) => setState(() => flir = v), Icons.thermostat),
                buildToggle('Hoist', goodrichHoist, (v) => setState(() => goodrichHoist = v), Icons.precision_manufacturing),
                buildToggle('Hoisting Mission', hoistingMission, (v) => setState(() => hoistingMission = v), Icons.arrow_upward),
                buildToggle('Emergency Mode', emergencyModeEnabled, (v) => setState(() => emergencyModeEnabled = v), Icons.warning_amber_rounded),
              ],
            ),
            const SizedBox(height: 20),
            Center(
              child: ElevatedButton(
                onPressed: calculateCruise,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                ),
                child: const Text('CALCULATE', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Simulation feature coming soon!')),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[700],
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                ),
                child: const Text('SIMULATE', style: TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}