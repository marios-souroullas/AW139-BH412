// Dart CLI to convert assets/villages/village_cords.geojson into a proper
// GeoJSON FeatureCollection with Point geometries using coordinates parsed
// from DMS fields (Field2: latitude, Field3: longitude). The output keeps
// original properties and adds a normalized 'name' property.
//
// Usage (from project root):
//   dart run bin/convert_villages.dart
//
// Output:
//   assets/villages/village_cords_points.geojson

import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  final root = Directory.current.path;
  final inPath = pathJoin(root, 'assets', 'villages', 'village_cords.geojson');
  final outPath = pathJoin(
    root,
    'assets',
    'villages',
    'village_cords_points.geojson',
  );
  if (!await File(inPath).exists()) {
    stderr.writeln('Input file not found: $inPath');
    exit(2);
  }
  final raw = await File(inPath).readAsString();
  dynamic json;
  try {
    json = jsonDecode(raw);
  } catch (e) {
    stderr.writeln('Failed to parse JSON: $e');
    exit(3);
  }
  if (json is! Map || json['type'] != 'FeatureCollection') {
    stderr.writeln('Expected a GeoJSON FeatureCollection at top level.');
    exit(4);
  }
  final features = (json['features'] as List?) ?? [];
  int converted = 0;
  int skipped = 0;
  final List outFeatures = [];
  for (final f in features) {
    if (f is! Map) {
      skipped++;
      continue;
    }
    final props = (f['properties'] is Map)
        ? Map<String, dynamic>.from(f['properties'])
        : <String, dynamic>{};
    Map<String, dynamic>? geom = (f['geometry'] is Map)
        ? Map<String, dynamic>.from(f['geometry'])
        : null;

    // Extract name
    final name =
        (props['name_gr'] ??
                props['name_greek'] ??
                props['name'] ??
                props['Field1'] ??
                '')
            .toString();

    double? lat;
    double? lon;

    // Prefer geometry if valid
    if (geom != null && geom['type'] == 'Point') {
      final coords = (geom['coordinates'] as List?) ?? const [];
      if (coords.length >= 2) {
        lon = _asDouble(coords[0]);
        lat = _asDouble(coords[1]);
      }
    }

    // Fallback: parse DMS from Field2/Field3
    if (lat == null || lon == null) {
      final rawLat = props['Field2']?.toString() ?? '';
      final rawLon = props['Field3']?.toString() ?? '';
      if (rawLat.isNotEmpty && rawLon.isNotEmpty) {
        lat = _parseDmsLoose(rawLat, isLat: true);
        lon = _parseDmsLoose(rawLon, isLat: false);
      }
    }

    if (name.isEmpty || lat == null || lon == null) {
      skipped++;
      continue;
    }

    // Ensure a 'name' property for app compatibility
    props['name'] = name;

    outFeatures.add({
      'type': 'Feature',
      'properties': props,
      'geometry': {
        'type': 'Point',
        'coordinates': [lon, lat], // GeoJSON is [lon, lat]
      },
    });
    converted++;
  }

  final out = {'type': 'FeatureCollection', 'features': outFeatures};
  final outPretty = const JsonEncoder.withIndent('  ').convert(out);
  await File(outPath).writeAsString(outPretty);
  stdout.writeln('Wrote $converted features to $outPath');
  if (skipped > 0) {
    stdout.writeln('Skipped $skipped items that lacked usable name/coords.');
  }
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

// Accepts formats like:
// - 34 59 18
// - 34  59 18
// - 33.19.27
// - With optional hemisphere letters, deg/min/sec separators, etc.
double? _parseDmsLoose(String input, {required bool isLat}) {
  String s = input.trim().toUpperCase();
  // If it looks like 33.19.27 (two dots), normalize to spaces.
  final dotCount = '.'.allMatches(s).length;
  final digitsAndDots = RegExp(r'^[0-9.\s]+');
  if (dotCount == 2 && digitsAndDots.hasMatch(s)) {
    s = s.replaceAll('.', ' ');
  }
  // Replace symbols with spaces
  s = s
      .replaceAll('°', ' ')
      .replaceAll("'", ' ')
      .replaceAll('"', ' ')
      .replaceAll(':', ' ')
      .replaceAll(',', ' ');
  // Collapse whitespace
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Extract hemisphere if present
  double sign = 1.0;
  if (s.contains('S') && isLat) sign = -1.0;
  if (s.contains('W') && !isLat) sign = -1.0;
  s = s.replaceAll(RegExp(r'[NSEW]'), '').trim();

  final parts = s.split(' ');
  final nums = <double>[];
  for (final p in parts) {
    if (p.isEmpty) continue;
    final v = double.tryParse(p);
    if (v != null) nums.add(v);
  }
  if (nums.isEmpty) return null;
  double deg = 0, min = 0, sec = 0;
  if (nums.length == 1) {
    deg = nums[0];
  } else if (nums.length == 2) {
    deg = nums[0];
    min = nums[1];
  } else {
    deg = nums[0];
    min = nums[1];
    sec = nums[2];
  }
  if (min < 0 || min >= 60 || sec < 0 || sec >= 60) return null;
  double val = deg.abs() + (min / 60.0) + (sec / 3600.0);
  val *= (deg < 0 ? -1 : 1);
  val *= sign;
  // Range check
  if (isLat) {
    if (val < -90 || val > 90) return null;
  } else {
    if (val < -180 || val > 180) return null;
  }
  return val;
}

String pathJoin(String a, String b, [String? c, String? d]) {
  final sep = Platform.pathSeparator;
  final parts = [a, b, if (c != null) c, if (d != null) d];
  return parts.join(sep);
}
