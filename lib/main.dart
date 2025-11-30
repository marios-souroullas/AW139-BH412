// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter_map/flutter_map.dart';
// Dragging vertices implemented with gesture detectors; no extra plugin needed
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart'
    show rootBundle, Clipboard, ClipboardData;
import 'package:flutter/services.dart' as services;
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'cruise_input_screen.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'dart:convert'
    show jsonDecode, jsonEncode, Utf8Encoder; // include needed converters only
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart' as xml;
import 'dart:io' show File, Directory;

// API keys and tokens
// Prefer passing at build/run via: --dart-define=OPENWEATHER_API_KEY=...; fallback keeps current value
const String kOpenWeatherApiKey = String.fromEnvironment(
  'OPENWEATHER_API_KEY',
  defaultValue: '2bfda15eb1d3c7ea910fc5cc180ab4ad',
);
// TODO: Replace with secure storage / env injection for production
const String kAvwxApiToken = 'f03J12T09f6TiY6YqSR39M8Sv6o-bEkieivjBnVi_C8';

// Live link base for in-flight sharing (used to compose share URLs)
// If hosting the web app, point this to your live viewer page.
const String kLiveViewerBase = '/live.html';

// Minimal obstacle model (used by obstacles overlay and loader)
class _Obstacle {
  final String country;
  final double lat;
  final double lon;
  final String name;
  final String kind;
  final double? heightFeet;
  const _Obstacle({
    required this.country,
    required this.lat,
    required this.lon,
    required this.name,
    required this.kind,
    this.heightFeet,
  });
}

class _Waypoint {
  final String id;
  final String name;
  final double lat;
  final double lon;
  final double? altMeters;
  final String type;
  final DateTime createdAt;
  const _Waypoint({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    this.altMeters,
    this.type = 'User',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lat': lat,
    'lon': lon,
    'altMeters': altMeters,
    'type': type,
    'createdAt': createdAt.toIso8601String(),
  };

  factory _Waypoint.fromJson(Map<String, dynamic> json) {
    return _Waypoint(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'WPT',
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      altMeters: (json['altMeters'] as num?)?.toDouble(),
      type: json['type']?.toString() ?? 'User',
      createdAt: () {
        final v = json['createdAt'];
        if (v is String) {
          try {
            return DateTime.parse(v);
          } catch (_) {}
        }
        return DateTime.now();
      }(),
    );
  }
}

class _SavedRoute {
  final String id;
  final String name;
  final List<LatLng> points;
  final DateTime createdAt;
  const _SavedRoute({
    required this.id,
    required this.name,
    required this.points,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'points': points
        .map((p) => {'lat': p.latitude, 'lon': p.longitude})
        .toList(),
  };

  factory _SavedRoute.fromJson(Map<String, dynamic> json) {
    final pts = <LatLng>[];
    final rawPts =
        (json['points'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    for (final p in rawPts) {
      final lat = (p['lat'] as num?)?.toDouble();
      final lon = (p['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      pts.add(LatLng(lat, lon));
    }
    DateTime created;
    final c = json['createdAt'];
    if (c is String) {
      try {
        created = DateTime.parse(c);
      } catch (_) {
        created = DateTime.now();
      }
    } else {
      created = DateTime.now();
    }
    return _SavedRoute(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Route',
      points: pts,
      createdAt: created,
    );
  }
}

class _Navaid {
  final String name;
  final String ident;
  final String? type; // VOR/NDB/etc
  final String? freq; // textual
  final String country; // CY/GR/IL
  final double lat;
  final double lon;
  const _Navaid({
    required this.name,
    required this.ident,
    this.type,
    this.freq,
    required this.country,
    required this.lat,
    required this.lon,
  });
}

class _Village {
  final String name;
  final List<String> aliases;
  final double lat;
  final double lon;
  const _Village({
    required this.name,
    this.aliases = const [],
    required this.lat,
    required this.lon,
  });

  factory _Village.fromJson(Map<String, dynamic> json) {
    return _Village(
      name: json['name']?.toString() ?? '',
      aliases:
          (json['aliases'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
    );
  }
}

class _ReportingPoint {
  final String name;
  final String country; // CY/GR/IL
  final double lat;
  final double lon;
  const _ReportingPoint({
    required this.name,
    required this.country,
    required this.lat,
    required this.lon,
  });
}

class _Airport {
  final String name;
  final String? icao;
  final String? iata;
  final LatLng position;
  final Map<String, dynamic>? properties;
  const _Airport({
    required this.name,
    this.icao,
    this.iata,
    required this.position,
    this.properties,
  });
}

class _ImportedLayer {
  final String id;
  final String name;
  final List<List<LatLng>> polylines;
  final List<List<LatLng>> polygons;
  final List<LatLng> points;
  final bool visible;
  final bool useAsPowerLines; // include polylines in power-line warnings
  final String strokeColorHex; // AARRGGBB
  final String fillColorHex; // AARRGGBB
  final DateTime createdAt;
  const _ImportedLayer({
    required this.id,
    required this.name,
    this.polylines = const [],
    this.polygons = const [],
    this.points = const [],
    this.visible = true,
    this.useAsPowerLines = false,
    this.strokeColorHex = 'FF000000',
    this.fillColorHex = '33000000',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'visible': visible,
    'asPowerLines': useAsPowerLines,
    'createdAt': createdAt.toIso8601String(),
    'strokeColor': strokeColorHex,
    'fillColor': fillColorHex,
    'polylines': polylines
        .map(
          (line) =>
              line.map((p) => {'lat': p.latitude, 'lon': p.longitude}).toList(),
        )
        .toList(),
    'polygons': polygons
        .map(
          (poly) =>
              poly.map((p) => {'lat': p.latitude, 'lon': p.longitude}).toList(),
        )
        .toList(),
    'points': points
        .map((p) => {'lat': p.latitude, 'lon': p.longitude})
        .toList(),
  };

  factory _ImportedLayer.fromJson(Map<String, dynamic> json) {
    List<List<LatLng>> readLines(String key) {
      final out = <List<LatLng>>[];
      final raw = json[key] as List?;
      if (raw != null) {
        for (final seg in raw) {
          final pts = <LatLng>[];
          final arr = (seg as List?)?.cast<Map<String, dynamic>>() ?? [];
          for (final p in arr) {
            final lat = (p['lat'] as num?)?.toDouble();
            final lon = (p['lon'] as num?)?.toDouble();
            if (lat != null && lon != null) pts.add(LatLng(lat, lon));
          }
          if (pts.isNotEmpty) out.add(pts);
        }
      }
      return out;
    }

    List<LatLng> readPoints() {
      final out = <LatLng>[];
      final raw = json['points'] as List?;
      if (raw != null) {
        for (final p in raw.cast<Map<String, dynamic>>()) {
          final lat = (p['lat'] as num?)?.toDouble();
          final lon = (p['lon'] as num?)?.toDouble();
          if (lat != null && lon != null) out.add(LatLng(lat, lon));
        }
      }
      return out;
    }

    DateTime created;
    final c = json['createdAt'];
    if (c is String) {
      try {
        created = DateTime.parse(c);
      } catch (_) {
        created = DateTime.now();
      }
    } else {
      created = DateTime.now();
    }

    return _ImportedLayer(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Imported',
      polylines: readLines('polylines'),
      polygons: readLines('polygons'),
      points: readPoints(),
      visible: json['visible'] == false ? false : true,
      useAsPowerLines: json['asPowerLines'] == true,
      strokeColorHex: json['strokeColor']?.toString() ?? 'FF000000',
      fillColorHex: json['fillColor']?.toString() ?? '33000000',
      createdAt: created,
    );
  }
}

class _SavedArea {
  final String id;
  final String name;
  final String type; // 'circle', 'polygon', or 'line'
  final double? centerLat;
  final double? centerLon;
  final double? radiusNm; // for circle
  final List<LatLng>
  points; // polygon boundary (for circle: generated perimeter)
  final DateTime createdAt;
  final String strokeColorHex; // AARRGGBB
  final String fillColorHex; // AARRGGBB (lower alpha)
  const _SavedArea({
    required this.id,
    required this.name,
    required this.type,
    this.centerLat,
    this.centerLon,
    this.radiusNm,
    required this.points,
    required this.createdAt,
    this.strokeColorHex = 'FFFF0000',
    this.fillColorHex = '55FF0000',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'centerLat': centerLat,
    'centerLon': centerLon,
    'radiusNm': radiusNm,
    'createdAt': createdAt.toIso8601String(),
    'points': points
        .map((p) => {'lat': p.latitude, 'lon': p.longitude})
        .toList(),
    'strokeColor': strokeColorHex,
    'fillColor': fillColorHex,
  };

  factory _SavedArea.fromJson(Map<String, dynamic> json) {
    final pts = <LatLng>[];
    final rawPts =
        (json['points'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    for (final p in rawPts) {
      final lat = (p['lat'] as num?)?.toDouble();
      final lon = (p['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      pts.add(LatLng(lat, lon));
    }
    DateTime created;
    final c = json['createdAt'];
    if (c is String) {
      try {
        created = DateTime.parse(c);
      } catch (_) {
        created = DateTime.now();
      }
    } else {
      created = DateTime.now();
    }
    return _SavedArea(
      id:
          json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Area',
      type: json['type']?.toString() ?? 'polygon',
      centerLat: (json['centerLat'] as num?)?.toDouble(),
      centerLon: (json['centerLon'] as num?)?.toDouble(),
      radiusNm: (json['radiusNm'] as num?)?.toDouble(),
      points: pts,
      createdAt: created,
      strokeColorHex: json['strokeColor']?.toString() ?? 'FFFF0000',
      fillColorHex: json['fillColor']?.toString() ?? '55FF0000',
    );
  }
}

// Simple weather cell model (top-level)
class _WeatherCell {
  final LatLng pos;
  final double density; // 0.0 .. 1.0
  const _WeatherCell(this.pos, this.density);
}

// Simple wind cell model (top-level)
class _WindCell {
  final LatLng pos;
  final double speedMs; // meters per second
  final double dirDeg; // meteorological direction FROM which wind blows
  const _WindCell(this.pos, this.speedMs, this.dirDeg);
}

class MovingMapScreen extends StatefulWidget {
  const MovingMapScreen({super.key});
  @override
  State<MovingMapScreen> createState() => _MovingMapScreenState();
}

// Small helper widget used for info bar items later
// _InfoItem and _FlightTimeFormat are defined later in this file
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    if (kDebugMode) debugPrint('Firebase init skipped/failed: $e');
  }
  runApp(const AW139CruiseApp());
}

class AW139CruiseApp extends StatelessWidget {
  const AW139CruiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AW139 Cruise',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const MovingMapScreen(),
    );
  }
}

class _PatternSegment {
  final int id; // stable identifier
  int start; // 1-based starting waypoint index in _routePoints
  int count; // number of points the pattern segment spans
  String type; // e.g. 'ExpandingSquare', 'SectorSearch', etc.
  final Map<String, dynamic> params; // extra generation parameters
  _PatternSegment({
    required this.id,
    required this.start,
    required this.count,
    required this.type,
    this.params = const {},
  });
}

enum _AltSource { gps, baro }

enum _NvgStyle { full, uiOnly }

class _MovingMapScreenState extends State<MovingMapScreen> {
  // Utility to parse stored AARRGGBB hex colors for areas
  Color _colorFromHex(String hex) {
    final cleaned = hex.trim().replaceAll('#', '');
    if (cleaned.length == 8) {
      final v = int.tryParse(cleaned, radix: 16);
      if (v != null) return Color(v);
    } else if (cleaned.length == 6) {
      final v = int.tryParse(cleaned, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return Colors.redAccent; // fallback
  }

  final MapController _mapController = MapController();
  // Key for positioning overlays relative to the map Stack
  final GlobalKey _mapStackKey = GlobalKey();
  // Info bar state
  bool _showInfoBar = false;
  DateTime? _flightStart;
  DateTime? _flightEnd; // set on landing
  Timer? _flightTicker; // periodic update while running
  int? _selectedAirspaceIdx;
  double _mapZoom = 10.0;
  bool _autoCenter = false;
  bool _headingUp = false;
  bool _nvgMode = false; // Night Vision Goggle friendly palette toggle
  double _nvgIntensity = 0.7; // 0.2 .. 1.0 controls brightness of green tint
  _NvgStyle _nvgStyle = _NvgStyle.full; // default to full overlay tint for NVG
  bool _nightMode = false; // Night mode (neutral dark dim), exclusive with NVG
  // Cruise calculation panel toggle
  // Cruise calculator toggle removed; accessed via menu header button only.
  // Overlay panel expansion state
  bool _overlayExpanded = false;
  // Auto-close timer for overlays (closes map options after inactivity)
  Timer? _overlayAutoCloseTimer;

  // Auto-center temporary suppression (when user interacts with the map)
  bool _autoCenterSuppressed = false;
  Timer? _autoCenterResumeTimer;

  void _cancelAutoCenterResumeTimer() {
    try {
      _autoCenterResumeTimer?.cancel();
    } catch (_) {}
    _autoCenterResumeTimer = null;
  }

  // NVG settings persistence
  Future<void> _loadNvgSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mode = prefs.getBool('nvgMode');
      final intensity = prefs.getDouble('nvgIntensity');
      final styleStr = prefs.getString('nvgStyle');
      final night = prefs.getBool('nightMode');
      if (mounted) {
        setState(() {
          if (mode != null) _nvgMode = mode;
          if (intensity != null) {
            _nvgIntensity = intensity.clamp(0.2, 1.0);
          }
          if (styleStr != null) {
            _nvgStyle = styleStr == 'full' ? _NvgStyle.full : _NvgStyle.uiOnly;
          }
          if (night != null) _nightMode = night;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveNvgSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('nvgMode', _nvgMode);
      await prefs.setDouble('nvgIntensity', _nvgIntensity);
      await prefs.setString(
        'nvgStyle',
        _nvgStyle == _NvgStyle.full ? 'full' : 'uiOnly',
      );
      await prefs.setBool('nightMode', _nightMode);
    } catch (_) {}
  }

  // _nvgFilterColor removed (unused). NVG tint uses matrix-based filter.

  Widget _nvgWrap(Widget child) {
    if (_nightMode) {
      // Night mode: desaturate + darken with black overlay
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.30,
          0.30,
          0.30,
          0,
          0,
          0.30,
          0.30,
          0.30,
          0,
          0,
          0.30,
          0.30,
          0.30,
          0,
          0,
          0.00,
          0.00,
          0.00,
          1,
          0,
        ]),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
          ),
          child: child,
        ),
      );
    }
    if (!_nvgMode || _nvgStyle == _NvgStyle.uiOnly) return child;
    final gScale = 0.4 + 0.4 * _nvgIntensity;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(<double>[
        0.25,
        0.00,
        0.00,
        0,
        0,
        0.00,
        gScale,
        0.00,
        0,
        0,
        0.00,
        0.00,
        0.15,
        0,
        0,
        0.00,
        0.00,
        0.00,
        1,
        0,
      ]),
      child: child,
    );
  }

  void _suppressAutoCenterFor(Duration duration) {
    // Only suppress when user has auto-center enabled; respect manual disable
    if (!_autoCenter) return;
    _cancelAutoCenterResumeTimer();
    setState(() => _autoCenterSuppressed = true);
    _autoCenterResumeTimer = Timer(duration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _autoCenterSuppressed = false;
        // Recenter when resuming if we still have a position
        if (_autoCenter && _currentPosition != null) {
          _mapController.move(_currentPosition!, _mapZoom);
        }
      });
    });
  }

  void _startOverlayAutoCloseTimer() {
    _cancelOverlayAutoCloseTimer();
    _overlayAutoCloseTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) {
        return;
      }
      if (_overlayExpanded) setState(() => _overlayExpanded = false);
    });
  }

  void _cancelOverlayAutoCloseTimer() {
    try {
      _overlayAutoCloseTimer?.cancel();
    } catch (_) {}
    _overlayAutoCloseTimer = null;
  }

  void _setOverlayExpanded(bool v) {
    setState(() => _overlayExpanded = v);
    if (v) {
      _startOverlayAutoCloseTimer();
    } else {
      _cancelOverlayAutoCloseTimer();
    }
  }

  // Weather toggles
  bool _showClouds = false;
  bool _showRain = false;
  // Weather overlays: cells with a position and density 0..1
  final List<_WeatherCell> _cloudCells = []; // density ~ cloud cover
  final List<_WeatherCell> _rainCells = []; // density ~ precipitation rate
  // Weather overlay presentation controls
  bool _wxShowPercentLabels = true; // toggle numeric % inside markers
  double _wxOpacity = 1.0; // global opacity multiplier for cloud/rain markers
  // Winds aloft selection: discrete standard levels (0=SFC uses surface winds)
  static const List<int> _windLevelsFt = [
    0,
    3000,
    6000,
    9000,
    12000,
    18000,
    24000,
    30000,
    34000,
    39000,
  ];
  int _wxWindLevelIdx = 0; // index into _windLevelsFt
  int get _wxWindLevelFt => _windLevelsFt[_wxWindLevelIdx];
  int? _lastWxWindLevelFt; // cache key to avoid unnecessary refetch
  // Map our discrete feet levels to common isobaric levels (hPa) for providers
  static const Map<int, int> _feetToHpa = {
    3000: 900, // ~3k ft
    6000: 800, // ~6k ft
    9000: 700, // ~9-10k ft
    12000: 600, // ~12k ft
    18000: 500, // ~FL180
    24000: 400,
    30000: 300,
    34000: 250,
    39000: 200,
  };

  // Pick the nearest supported pressure (hPa) for a requested feet level
  int _pressureForFeet(int feet) {
    if (feet <= 0) return 0; // surface
    if (_feetToHpa.containsKey(feet)) return _feetToHpa[feet]!;
    // nearest by absolute feet difference
    int bestFeet = _feetToHpa.keys.first;
    for (final f in _feetToHpa.keys) {
      if ((f - feet).abs() < (bestFeet - feet).abs()) bestFeet = f;
    }
    return _feetToHpa[bestFeet] ?? 700;
  }

  // Fetch wind at a specific pressure level using Windy (if key present) or Open‑Meteo.
  // Returns speed (m/s) and direction FROM (deg), or null on failure.
  Future<Map<String, double>?> _fetchWindAloftAt({
    required double lat,
    required double lon,
    required int feetLevel,
  }) async {
    try {
      final p = _pressureForFeet(feetLevel);
      // Try Windy first if key available via the imported cruise screen constant
      try {
        if (kWindyApiKey.isNotEmpty) {
          final windyUri = Uri.parse(
            'https://api.windy.com/api/point-forecast/v2'
            '?lat=$lat&lon=$lon&model=gfs&levels=$p&parameters=wind',
          );
          final windyRes = await http.get(
            windyUri,
            headers: {
              'x-windy-key': kWindyApiKey,
              'Accept': 'application/json',
            },
          );
          if (windyRes.statusCode == 200) {
            final wd = jsonDecode(windyRes.body) as Map<String, dynamic>;
            final levels = (wd['levels'] ?? {}) as Map;
            final entry = levels['$p'] as Map?;
            Map? windMap = entry?['wind'] as Map?;
            double sp = 0.0;
            double dir = 0.0;
            if (windMap != null) {
              final s = windMap['speed'];
              final d = windMap['direction'];
              if (s is num) sp = s.toDouble();
              if (d is num) dir = d.toDouble();
            } else if (entry != null) {
              final s = entry['speed'];
              final d = entry['direction'];
              if (s is num) sp = s.toDouble();
              if (d is num) dir = d.toDouble();
            }
            if (sp > 0) return {'speedMs': sp, 'dirDeg': dir};
          }
        }
      } catch (_) {}

      // Fallback to Open‑Meteo hourly isobaric level
      try {
        final omParams = StringBuffer()
          ..write('&forecast_days=1')
          ..write('&hourly=wind_speed_${p}hPa,wind_direction_${p}hPa');
        final uri = Uri.parse(
          'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon${omParams.toString()}',
        );
        final res = await http.get(uri);
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final h = (data['hourly'] ?? {}) as Map<String, dynamic>;
          final spArr = h['wind_speed_${p}hPa'];
          final drArr = h['wind_direction_${p}hPa'];
          double spMs = 0.0;
          double dir = 0.0;
          if (spArr is List && spArr.isNotEmpty) {
            final v = spArr[0];
            if (v is num) spMs = (v.toDouble()) / 3.6; // km/h -> m/s
          } else if (spArr is num) {
            spMs = (spArr.toDouble()) / 3.6;
          }
          if (drArr is List && drArr.isNotEmpty) {
            final v = drArr[0];
            if (v is num) dir = v.toDouble();
          } else if (drArr is num) {
            dir = drArr.toDouble();
          }
          if (spMs > 0) return {'speedMs': spMs, 'dirDeg': dir};
        }
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  // Weather sampling controls
  double _wxRadiusKm = 150.0; // radius from center to sample grid (km)
  int _wxGridSide = 5; // number of samples per side (odd: 3,5,7,9)
  DateTime? _lastWxFetch;
  LatLng? _lastWxCenter; // last fetch map center
  double? _lastWxRadiusKm;
  int? _lastWxGridSide;
  // Wind overlay state
  final List<_WindCell> _windCells = [];
  Color _windColorForSpeedKts(double kts) {
    final t = (kts / 35.0).clamp(0.0, 1.0); // scale ~0..35 kts
    Color lerp(Color a, Color b, double x) => Color.fromARGB(
      (a.a * 255 + ((b.a - a.a) * x * 255)).round().clamp(0, 255),
      (a.r + (b.r - a.r) * x).round().clamp(0, 255),
      (a.g + (b.g - a.g) * x).round().clamp(0, 255),
      (a.b + (b.b - a.b) * x).round().clamp(0, 255),
    );
    if (t < 0.33) return lerp(Colors.blueAccent, Colors.green, t / 0.33);
    if (t < 0.66) return lerp(Colors.green, Colors.yellow, (t - 0.33) / 0.33);
    return lerp(Colors.orange, Colors.redAccent, (t - 0.66) / 0.34);
  }

  // Gradient: light grey -> dark grey for clouds
  Color _cloudColorForDensity(double d) {
    final t = d.clamp(0.0, 1.0);
    final v = (200 - 120 * t).round(); // 200 -> 80
    final a = (80 + 140 * t).round(); // 80 -> 220
    return Color.fromARGB(a, v, v, v);
  }

  // Gradient: yellow -> orange -> red for rain
  Color _rainColorForDensity(double d) {
    final t = d.clamp(0.0, 1.0);
    // Interpolate through two segments: yellow(255,255,0) -> orange(255,165,0) -> red(255,0,0)
    int r = 255;
    int g;
    int b = 0;
    if (t < 0.5) {
      final k = t / 0.5; // 0..1
      g = (255 - (255 - 165) * k).round();
    } else {
      final k = (t - 0.5) / 0.5; // 0..1
      g = (165 - 165 * k).round();
    }
    final a = (90 + 165 * t).round(); // 90 -> 255
    return Color.fromARGB(a, r, g, b);
  }

  // Update helpers to be called after fetching API data
  // ignore: unused_element
  void _setCloudData(List<_WeatherCell> cells) {
    setState(() {
      _cloudCells
        ..clear()
        ..addAll(cells);
    });
  }

  // ignore: unused_element
  void _setRainData(List<_WeatherCell> cells) {
    setState(() {
      _rainCells
        ..clear()
        ..addAll(cells);
    });
  }

  // Build a small horizontal legend row with sample swatches
  Widget _buildWxLegendRow(String label, List<Color> samples) {
    return Row(
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              for (int i = 0; i < samples.length; i++) ...[
                Expanded(
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: samples[i].withValues(
                        alpha: samples[i].a * _wxOpacity,
                      ),
                      borderRadius: i == 0
                          ? const BorderRadius.horizontal(
                              left: Radius.circular(4),
                            )
                          : i == samples.length - 1
                          ? const BorderRadius.horizontal(
                              right: Radius.circular(4),
                            )
                          : BorderRadius.zero,
                    ),
                  ),
                ),
                // Draggable endpoint for draft line: long-press drag to create WPT
                if (_draftLineMode && _draftLinePoints.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _draftLinePoints.last,
                        width: 36,
                        height: 36,
                        child: _buildDraggableDraftEndpoint(),
                      ),
                    ],
                  ),
                if (i != samples.length - 1) const SizedBox(width: 2),
              ],
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text('%', style: const TextStyle(color: Colors.white38, fontSize: 10)),
      ],
    );
  }

  bool _showWind = false;
  // Info bar position format
  bool _posDms = true;
  double? _currentAltitudeM;
  // Altitude source & baro settings
  // gps: use Geolocator altitude. baro: compute from device pressure and QNH.
  _AltSource _altSource = _AltSource.gps;
  bool _qnhAuto =
      true; // when true, use 1013.25 hPa (STD) unless we later wire a METAR source
  double _qnhHpa = 1013.25; // manual QNH when _qnhAuto == false
  double? _baroPressureHpa; // latest device pressure (hPa)
  double? _baroAltitudeM; // computed altitude from pressure & QNH (meters)
  // Barometer subscription (device pressure sensor via sensors_plus / raw channel)
  StreamSubscription<dynamic>? _baroSub;
  // Location subscription and auto-stop timer (limit background tracking to 4 hours)
  StreamSubscription<Position>? _locationSub;
  Timer? _locationAutoStopTimer;
  static const Duration _locationMaxDuration = Duration(hours: 4);
  // Fallback pressure event channel (matches sensors_plus native channel name when available)
  final services.EventChannel _pressureChannel = const services.EventChannel(
    'dev.flutter.sensors/pressure',
  );
  // Voice alert state
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;
  bool _ttsEnabled = true; // master voice toggle
  double? _currentGpsSpeedKts; // live computed ground speed
  LatLng? _lastSpeedPos;
  DateTime? _lastSpeedTime;
  // Altitude warnings: two thresholds with simple hysteresis
  bool _alt1Warned = false;
  bool _alt2Warned = false;
  bool _speedWarnedBelow = false;
  // thresholds & hysteresis (user configurable)
  int _altWarn1Ft = 150; // e.g., 150 ft
  int _altWarn2Ft = 50; // e.g., 50 ft
  double _speedWarnKts = 40; // trigger below (announce N knots)
  double get _speedResetKts => _speedWarnKts + 4; // small hysteresis
  // Warning toggles and AGL
  bool _altWarnsEnabled = true;
  bool _speedWarnEnabled = true;
  bool _useAglForWarns = false;
  double? _groundElevM; // cached ground elevation (meters AMSL)
  LatLng? _groundElevPos;
  DateTime? _groundElevFetchedAt;
  bool _elevFetchInFlight = false;
  DateTime? _groundElevFailedAt;
  DateTime? _lastElevWarnAt;
  static const int _elevFailCooldownSec =
      300; // don't retry/show warning for 5 minutes
  // Info bar customization
  bool _infoAglReplaceEte = false;
  bool _infoShowTrk = true;
  bool _infoShowEtaOrAgl = false;
  bool _infoShowEte = true;
  bool _infoShowDist = true;
  bool _infoShowAlt = true;
  bool _infoShowFlight = true;
  bool _infoShowPos = true;
  bool _infoShowGs = true;
  bool _infoShowAglNextToAlt = false;
  // Track-up support
  double _currentHeadingDeg = 0.0; // 0..360, 0 = North
  LatLng?
  _lastPosForHeading; // for computing course-based heading when sensor heading is unavailable

  LatLng? _currentPosition;
  // Location debug state
  String _locationDebugStatus = 'Initializing...';
  DateTime? _lastPositionUpdate;
  int _positionUpdateCount = 0;
  String? _locationError;
  // Track current permission (used to always show a grant button if needed)
  LocationPermission? _locationPermission;
  // ===== Flight track & logbook =====
  List<LatLng> _currentTrack = [];
  DateTime? _trackStartTime;
  LatLng? _trackStartPos;
  LatLng? _trackEndPos;
  List<Map<String, dynamic>> _flightLog = [];
  List<LatLng>? _selectedLogRoute;
  bool _isLoadingLog = false;
  bool _recoveredActiveFlight = false; // recovered unfinished flight flag
  final LatLng _initialCenter = const LatLng(34.8723, 33.6243);
  final double _initialZoom = 10.0;

  // ===== Live Share (Realtime "Follow Me") =====
  bool _liveShareActive = false;
  String? _liveSessionId;
  String? _liveShareToken; // optional token appended to URL and stored in doc
  Timer? _livePublishTimer;
  final List<LatLng> _pendingLivePoints = [];
  DateTime? _lastLivePublish;
  final int _livePublishIntervalSec = 5; // publish heartbeat/chunk every 5s
  final double _liveMinMoveMeters = 25.0; // accumulate points if moved >=25m

  // User callsign (shown in viewer)
  String _callsign = 'AW139';

  // === Route management ===
  final List<LatLng> _routePoints = [];
  int _activeLegIndex = 0; // index of starting waypoint for remaining route
  double _groundSpeedKts = 120; // user-adjustable groundspeed for ETE
  // Preview-only generated pattern points (dashed overlay)
  List<LatLng> _previewPatternPoints = [];
  // (Holding debug overlay removed)
  // Geo helpers
  final Distance _geo = const Distance();
  double _nmToMeters(double nm) => nm * 1852.0;
  double _normalize360(double deg) => (deg % 360 + 360) % 360;
  double _turn90(String turnDir, double bearing) => _normalize360(
    bearing + (turnDir.toUpperCase().startsWith('R') ? 90.0 : -90.0),
  );
  LatLng _offsetNM(LatLng from, double nm, double bearingDeg) =>
      _geo.offset(from, _nmToMeters(nm), bearingDeg);

  // Compute per-leg distances in nautical miles.
  List<double> _legDistancesNm() {
    if (_routePoints.length < 2) return const [];
    final dist = const Distance();
    final result = <double>[];
    for (int i = 1; i < _routePoints.length; i++) {
      final m = dist.as(LengthUnit.Meter, _routePoints[i - 1], _routePoints[i]);
      result.add(m / 1852.0);
    }
    return result;
  }

  double _remainingDistanceNm() {
    if (_activeLegIndex >= _routePoints.length - 1) return 0.0;
    final legs = _legDistancesNm();
    if (legs.isEmpty) return 0.0;
    double rem = 0;
    for (int i = _activeLegIndex; i < legs.length; i++) {
      rem += legs[i];
    }
    return rem;
  }

  // Total ETE for full route (hrs) and remaining ETE (Duration)
  Duration? _remainingEte() {
    if (_groundSpeedKts <= 0) return null;
    final remNm = _remainingDistanceNm();
    if (remNm <= 0) return null;
    final hours = remNm / _groundSpeedKts;
    return Duration(seconds: (hours * 3600).round());
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String _formatEta() {
    final d = _remainingEte();
    if (d == null) return '--';
    final eta = DateTime.now().add(d);
    final hh = eta.hour.toString().padLeft(2, '0');
    final mm = eta.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  void _setActiveLeg(int idx) {
    setState(() {
      _activeLegIndex = idx.clamp(0, _routePoints.length - 1);
    });
  }

  void _reorderRoute(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= _routePoints.length) return;
    if (newIndex < 0 || newIndex >= _routePoints.length) return;
    setState(() {
      final item = _routePoints.removeAt(oldIndex);
      _routePoints.insert(newIndex, item);
      // Adjust active leg index if necessary
      if (_activeLegIndex == oldIndex) {
        _activeLegIndex = newIndex;
      } else if (oldIndex < _activeLegIndex && newIndex >= _activeLegIndex) {
        _activeLegIndex -= 1;
      } else if (oldIndex > _activeLegIndex && newIndex <= _activeLegIndex) {
        _activeLegIndex += 1;
      }
    });
    _persistRoute();
  }

  void _openRouteManager() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        final legDists = _legDistancesNm();
        return StatefulBuilder(
          builder: (ctx, setModalState) => Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Route Manager',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                if (_routePoints.length < 2)
                  const Text('Add at least two points to manage the route.'),
                if (_routePoints.length >= 2)
                  ReorderableListView(
                    shrinkWrap: true,
                    buildDefaultDragHandles: true,
                    physics: const ClampingScrollPhysics(),
                    onReorder: (oldIndex, newIndex) {
                      _reorderRoute(oldIndex, newIndex);
                      setModalState(() {});
                    },
                    children: [
                      for (int i = 0; i < _routePoints.length; i++)
                        ListTile(
                          key: ValueKey('rp_$i'),
                          dense: true,
                          title: Text(
                            'Waypoint ${i + 1}${i < legDists.length ? '  (${legDists[i].toStringAsFixed(1)} nm to next)' : ''}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            '${_toDms(_routePoints[i].latitude, isLat: true)}, ${_toDms(_routePoints[i].longitude, isLat: false)}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Set active leg start',
                                icon: Icon(
                                  Icons.flag,
                                  color:
                                      _activeLegIndex == i &&
                                          i < _routePoints.length - 1
                                      ? Colors.orangeAccent
                                      : Colors.white54,
                                ),
                                onPressed: i < _routePoints.length - 1
                                    ? () {
                                        _setActiveLeg(i);
                                        setModalState(() {});
                                      }
                                    : null,
                              ),
                              IconButton(
                                tooltip: 'Delete',
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _routePoints.removeAt(i);
                                    if (_activeLegIndex >=
                                        _routePoints.length - 1) {
                                      _activeLegIndex = math.max(
                                        0,
                                        _routePoints.length - 2,
                                      );
                                    }
                                  });
                                  setModalState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _routePoints.isEmpty ? null : _exportRouteJson,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Export JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _importRouteJson,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Import JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _routePoints.isEmpty ? null : _exportRouteGpx,
                      icon: const Icon(Icons.route),
                      label: const Text('Export GPX'),
                    ),
                    TextButton.icon(
                      onPressed: _routePoints.isEmpty ? null : _undoRoute,
                      icon: const Icon(Icons.undo),
                      label: const Text('Undo'),
                    ),
                    TextButton.icon(
                      onPressed: _routePoints.isEmpty ? null : _clearRoute,
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _exportRouteJson() async {
    if (_routePoints.isEmpty) return;
    final data = {
      'generated': DateTime.now().toIso8601String(),
      'points': _routePoints
          .map((p) => {'lat': p.latitude, 'lon': p.longitude})
          .toList(),
      'activeLegIndex': _activeLegIndex,
      'groundSpeedKts': _groundSpeedKts,
    };
    final jsonStr = jsonEncode(data);
    final bytes = const Utf8Encoder().convert(jsonStr);
    final fileName = 'route_${DateTime.now().millisecondsSinceEpoch}.json';
    try {
      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'application/json',
      );
      await xFile.saveTo(fileName);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Route exported: $fileName')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _importRouteJson() async {
    try {
      final typeGroup = const XTypeGroup(label: 'JSON', extensions: ['json']);
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;
      final contents = await file.readAsString();
      final decoded = jsonDecode(contents) as Map<String, dynamic>;
      final pts = (decoded['points'] as List?)?.cast<Map<String, dynamic>>();
      if (pts == null || pts.isEmpty) throw 'Invalid route file';
      final newPoints = <LatLng>[];
      for (final p in pts) {
        final lat = (p['lat'] as num?)?.toDouble();
        final lon = (p['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        newPoints.add(LatLng(lat, lon));
      }
      if (newPoints.isEmpty) throw 'No valid points';
      setState(() {
        _routePoints
          ..clear()
          ..addAll(newPoints);
        _activeLegIndex =
            (decoded['activeLegIndex'] as int?)?.clamp(
              0,
              newPoints.length - 1,
            ) ??
            0;
        _groundSpeedKts =
            (decoded['groundSpeedKts'] as num?)?.toDouble() ?? _groundSpeedKts;
      });
      await _persistRoute();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Route imported')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<void> _exportRouteGpx() async {
    if (_routePoints.isEmpty) return;
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln(
      '<gpx version="1.1" creator="AW139Cruise" xmlns="http://www.topografix.com/GPX/1/1">',
    );
    sb.writeln('  <trk><name>Route</name><trkseg>');
    for (final p in _routePoints) {
      sb.writeln(
        '    <trkpt lat="${p.latitude}" lon="${p.longitude}"></trkpt>',
      );
    }
    sb.writeln('  </trkseg></trk></gpx>');
    final gpxBytes = const Utf8Encoder().convert(sb.toString());
    final gpxName = 'route_${DateTime.now().millisecondsSinceEpoch}.gpx';
    try {
      final xFile = XFile.fromData(
        gpxBytes,
        name: gpxName,
        mimeType: 'application/gpx+xml',
      );
      await xFile.saveTo(gpxName);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('GPX exported: $gpxName')));
      }
      _persistRoute();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('GPX export failed: $e')));
      }
    }
  }

  void _addToRoute(LatLng p) {
    setState(() => _routePoints.add(p));
    _persistRoute();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Added to route')));
  }

  void _undoRoute() {
    if (_routePoints.isEmpty) return;
    setState(() => _routePoints.removeLast());
    _persistRoute();
  }

  void _clearRoute() {
    if (_routePoints.isEmpty) return;
    setState(() => _routePoints.clear());
    _persistRoute();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Route cleared')));
  }

  double _routeDistanceNm() {
    if (_routePoints.length < 2) return 0.0;
    final dist = const Distance();
    double meters = 0;
    for (int i = 1; i < _routePoints.length; i++) {
      meters += dist.as(LengthUnit.Meter, _routePoints[i - 1], _routePoints[i]);
    }
    return meters / 1852.0;
  }

  // Create a direct-to from current position to target (or just target if current unknown)
  void _directTo(LatLng target) {
    setState(() {
      _routePoints.clear();
      if (_currentPosition != null) {
        _routePoints.add(_currentPosition!);
      }
      _routePoints.add(target);
      _activeLegIndex = 0;
    });
    _persistRoute();
    // Provide visual feedback and center map
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Direct-to set')));
    }
    _mapController.move(target, 13.0);
  }

  // ===== Search Pattern Generators =====
  List<LatLng> _genParallel({
    required LatLng start,
    required double bearingDeg,
    required String turnDir, // 'L' or 'R'
    required int legs,
    required double legLenNm,
    required double spacingNm,
  }) {
    // Implements standard Parallel Track Search (PS):
    // - Long legs are parallel to the orientation (bearingDeg)
    // - Cross legs are a constant "direction of creep" (same side each time)
    // - Begin with a 1/2 spacing lead-in from the corner point to the CSP
    final pts = <LatLng>[start];
    var curr = start;
    var dir = _normalize360(bearingDeg);
    // Constant cross-track (inside) direction based on the initial leg
    final crossDir = _turn90(turnDir, dir);

    // Lead-in to the Commence Search Point (CSP): 1/2 S from the corner
    curr = _offsetNM(curr, spacingNm * 0.5, crossDir);
    pts.add(curr);

    for (int i = 0; i < legs; i++) {
      // Long leg
      curr = _offsetNM(curr, legLenNm, dir);
      pts.add(curr);

      if (i == legs - 1) break;

      // Cross to the next long leg (constant direction of creep)
      curr = _offsetNM(curr, spacingNm, crossDir);
      pts.add(curr);

      // Reverse for the next long leg
      dir = _normalize360(dir + 180.0);
    }
    return pts;
  }

  List<LatLng> _genExpSquare({
    required LatLng start,
    required double bearingDeg,
    required String turnDir,
    required double startLegNm,
    required double spacingNm,
    int maxLegs = 12,
  }) {
    final pts = <LatLng>[start];
    var curr = start;
    var dir = _normalize360(bearingDeg);
    var len = startLegNm;
    for (int i = 0; i < maxLegs; i++) {
      curr = _offsetNM(curr, len, dir);
      pts.add(curr);
      dir = _turn90(turnDir, dir);
      if (i % 2 == 1) len += spacingNm;
    }
    return pts;
  }

  List<LatLng> _genSectors({
    required LatLng center,
    required double bearingDeg,
    required String turnDir,
    required double diameterNm,
    required double angleStepDeg,
  }) {
    final radiusNm = diameterNm / 2.0;
    final pts = <LatLng>[center];
    final step = angleStepDeg.clamp(1, 180);
    final sweepDir = turnDir.toUpperCase().startsWith('R') ? 1.0 : -1.0;
    for (double a = 0; a < 360; a += step) {
      final brg = _normalize360(bearingDeg + sweepDir * a);
      final tip = _offsetNM(center, radiusNm, brg);
      pts
        ..add(tip)
        ..add(center);
    }
    return pts;
  }

  // Simple circular orbit pattern (centered on start point).
  // The generated points trace the perimeter of a circle of radiusNm around center.
  // startBearingDeg chooses where on the circle the orbit begins (radial from center).
  // turnDir controls direction (R = clockwise, L = counter‑clockwise).
  // We do NOT include the center point to avoid a spoke from center to first perimeter point.
  List<LatLng> _genOrbit({
    required LatLng center,
    required double startBearingDeg,
    required String turnDir,
    required double radiusNm,
    int laps = 1,
    int arcStepDeg = 10,
  }) {
    if (radiusNm <= 0) return [center];
    laps = math.max(1, laps);
    arcStepDeg = arcStepDeg.clamp(1, 45); // allow finer than holding, but cap
    final sweepSign = turnDir.toUpperCase().startsWith('R') ? 1.0 : -1.0;
    final pts = <LatLng>[];
    final startBrg = _normalize360(startBearingDeg);
    final first = _offsetNM(center, radiusNm, startBrg);
    pts.add(first);
    final totalDeg = 360 * laps;
    for (int a = arcStepDeg; a <= totalDeg; a += arcStepDeg) {
      final ang = _normalize360(startBrg + sweepSign * a);
      pts.add(_offsetNM(center, radiusNm, ang));
    }
    // Ensure closure back to first point (avoid duplicate if exact division)
    if (pts.last != first) pts.add(first);
    return pts;
  }

  // Full holding racetrack: outbound leg, 180° turn, inbound leg, 180° turn back to FIX.
  // Returns a closed loop starting/ending at FIX (final heading restored outbound).
  List<LatLng> _genRacetrack({
    required LatLng fix,
    required double bearingDeg,
    required String turnDir, // 'R' or 'L'
    required double legLenNm,
    required double turnRadiusNm,
    int arcStepDeg = 15,
  }) {
    if (legLenNm <= 0 || turnRadiusNm <= 0) return [fix];
    arcStepDeg = arcStepDeg.clamp(1, 45);
    final rightTurn = turnDir.toUpperCase().startsWith('R');
    final hOut = _normalize360(bearingDeg);
    final hIn = _normalize360(hOut + 180.0);
    final sideDir = _turn90(turnDir, hOut); // perpendicular toward centers

    final pts = <LatLng>[fix];

    // Outbound leg end (tangent into far turn)
    final legEndOut = _offsetNM(fix, legLenNm, hOut);
    pts.add(legEndOut);

    // Far turn center
    final cFar = _offsetNM(legEndOut, turnRadiusNm, sideDir);

    double bearingCenterTo(LatLng c, LatLng p) {
      final lat1 = c.latitude * math.pi / 180.0;
      final lat2 = p.latitude * math.pi / 180.0;
      final dLon = (p.longitude - c.longitude) * math.pi / 180.0;
      final y = math.sin(dLon) * math.cos(lat2);
      final x =
          math.cos(lat1) * math.sin(lat2) -
          math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
      return _normalize360(math.atan2(y, x) * 180.0 / math.pi);
    }

    // First 180° turn
    final startRadFar = bearingCenterTo(cFar, legEndOut);
    final endRadFar = _normalize360(
      rightTurn ? startRadFar + 180.0 : startRadFar - 180.0,
    );
    for (
      double a = arcStepDeg.toDouble();
      a < 180.0;
      a += arcStepDeg.toDouble()
    ) {
      final ang = _normalize360(startRadFar + (rightTurn ? a : -a));
      final p = _offsetNM(cFar, turnRadiusNm, ang);
      if (p != legEndOut) pts.add(p);
    }
    final inboundStart = _offsetNM(cFar, turnRadiusNm, endRadFar);
    if (pts.last != inboundStart) pts.add(inboundStart);

    // Inbound leg (parallel, opposite direction) toward near turn tangent
    final cNear = _offsetNM(
      fix,
      turnRadiusNm,
      sideDir,
    ); // near turn center offset from FIX
    final radialInboundTangent = rightTurn
        ? _normalize360(hIn - 90.0)
        : _normalize360(hIn + 90.0);
    final legEndIn = _offsetNM(cNear, turnRadiusNm, radialInboundTangent);
    pts.add(legEndIn);

    // Second 180° turn back to FIX (restores outbound heading)
    final startRadNear = radialInboundTangent;
    for (
      double a = arcStepDeg.toDouble();
      a < 180.0;
      a += arcStepDeg.toDouble()
    ) {
      final ang = _normalize360(startRadNear + (rightTurn ? a : -a));
      final p = _offsetNM(cNear, turnRadiusNm, ang);
      if (p != legEndIn) pts.add(p);
    }
    // Final fix (ensure exact)
    if (pts.last != fix) pts.add(fix);
    return pts;
  }

  Future<void> _openSearchPatternsDialog({
    LatLng? startPoint,
    int? startWaypointIndex,
    int? editingPatternId,
  }) async {
    final types = ['Parallel', 'Exp Square', 'Sectors', 'Orbit', 'Racetrack'];
    String type = types.first;
    final bearingCtl = TextEditingController(text: '0');
    final ValueNotifier<String> turnDirCtl = ValueNotifier<String>('R');
    final legsCtl = TextEditingController(text: '6');
    final coverageCtl = TextEditingController(text: '2');
    final spacingCtl = TextEditingController(text: '0.5');
    final angleStepCtl = TextEditingController(text: '30');
    final lapsCtl = TextEditingController(text: '1');
    final arcStepCtl = TextEditingController(text: '10');
    bool appendToRoute = true;

    // Choose start: explicit override, else last route point, else current position, else map center
    LatLng start =
        startPoint ??
        (_routePoints.isNotEmpty
            ? _routePoints.last
            : (_currentPosition ?? _initialCenter));

    // If editing an existing pattern, pre-fill controls based on stored params
    _PatternSegment? editingSeg;
    if (editingPatternId != null) {
      try {
        editingSeg = _patternSegments.firstWhere(
          (s) => s.id == editingPatternId,
        );
        final params = editingSeg.params;
        final t = params['type'] as String?;
        if (t != null && types.contains(t)) type = t;
        final b = params['bearing']?.toString();
        if (b != null) bearingCtl.text = b;
        final turn = params['turn']?.toString();
        if (turn != null) turnDirCtl.value = turn;
        final legs = params['legs']?.toString();
        if (legs != null) legsCtl.text = legs;
        final cov = params['coverage']?.toString();
        if (cov != null) coverageCtl.text = cov;
        final spacing = params['spacing']?.toString();
        if (spacing != null) spacingCtl.text = spacing;
        final step = params['angleStep']?.toString();
        if (step != null) angleStepCtl.text = step;
        final laps = params['laps']?.toString();
        if (laps != null) lapsCtl.text = laps;
        // Derive start from current route using segment start - 1
        if (editingSeg.start > 0 &&
            editingSeg.start - 1 < _routePoints.length) {
          start = _routePoints[editingSeg.start - 1];
        }
      } catch (_) {}
    }

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSB) {
            Widget numericField(
              String label,
              TextEditingController ctl, {
              String? suffix,
            }) {
              return SizedBox(
                width: 150,
                child: TextField(
                  controller: ctl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: label,
                    suffixText: suffix,
                    border: const OutlineInputBorder(),
                  ),
                ),
              );
            }

            return AlertDialog(
              title: const Text('Search Pattern'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButton<String>(
                      value: type,
                      items: [
                        for (final t in types)
                          DropdownMenuItem<String>(value: t, child: Text(t)),
                      ],
                      onChanged: (v) => setSB(() => type = v ?? type),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        numericField('Bearing', bearingCtl, suffix: '°'),
                        const SizedBox(width: 8),
                        ValueListenableBuilder<String>(
                          valueListenable: turnDirCtl,
                          builder: (_, v, _) => SizedBox(
                            width: 150,
                            child: DropdownButtonFormField<String>(
                              initialValue: v,
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Turn',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem<String>(
                                  value: 'R',
                                  child: Text('Right'),
                                ),
                                DropdownMenuItem<String>(
                                  value: 'L',
                                  child: Text('Left'),
                                ),
                              ],
                              onChanged: (nv) => turnDirCtl.value = nv ?? 'R',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (type == 'Parallel') ...[
                      Row(
                        children: [
                          numericField('Legs', legsCtl),
                          const SizedBox(width: 8),
                          numericField('Coverage', coverageCtl, suffix: 'nm'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      numericField('Track spacing', spacingCtl, suffix: 'nm'),
                    ] else if (type == 'Exp Square') ...[
                      Row(
                        children: [
                          numericField('Start leg', coverageCtl, suffix: 'nm'),
                          const SizedBox(width: 8),
                          numericField('Spacing', spacingCtl, suffix: 'nm'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(children: [numericField('Max legs', legsCtl)]),
                    ] else if (type == 'Sectors') ...[
                      Row(
                        children: [
                          numericField('Diameter', coverageCtl, suffix: 'nm'),
                          const SizedBox(width: 8),
                          numericField('Angle step', angleStepCtl, suffix: '°'),
                        ],
                      ),
                    ] else if (type == 'Orbit') ...[
                      Row(
                        children: [
                          numericField('Radius', coverageCtl, suffix: 'nm'),
                          const SizedBox(width: 8),
                          numericField('Laps', lapsCtl),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          numericField('Arc step', arcStepCtl, suffix: '°'),
                          const SizedBox(width: 8),
                          // Orbit smoothing hint hidden per user request
                        ],
                      ),
                    ] else if (type == 'Racetrack') ...[
                      Row(
                        children: [
                          numericField('Leg length', coverageCtl, suffix: 'nm'),
                          const SizedBox(width: 8),
                          numericField('Turn radius', spacingCtl, suffix: 'nm'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          numericField('Arc step', arcStepCtl, suffix: '°'),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    CheckboxListTile(
                      value: appendToRoute,
                      onChanged: (v) => setSB(() => appendToRoute = v ?? true),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        'Append to Route (unchecked = Preview only)',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 6),
                    // Start position details hidden per user request
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final bearing = double.tryParse(bearingCtl.text) ?? 0;
                    final turn = turnDirCtl.value;
                    List<LatLng> pts = const [];
                    if (type == 'Parallel') {
                      final legs = int.tryParse(legsCtl.text) ?? 6;
                      final legLenNm = double.tryParse(coverageCtl.text) ?? 2;
                      final spacingNm = double.tryParse(spacingCtl.text) ?? 0.5;
                      pts = _genParallel(
                        start: start,
                        bearingDeg: bearing,
                        turnDir: turn,
                        legs: legs,
                        legLenNm: legLenNm,
                        spacingNm: spacingNm,
                      );
                    } else if (type == 'Exp Square') {
                      final startLegNm = double.tryParse(coverageCtl.text) ?? 1;
                      final spacingNm = double.tryParse(spacingCtl.text) ?? 0.5;
                      final maxLegs = int.tryParse(legsCtl.text) ?? 12;
                      pts = _genExpSquare(
                        start: start,
                        bearingDeg: bearing,
                        turnDir: turn,
                        startLegNm: startLegNm,
                        spacingNm: spacingNm,
                        maxLegs: maxLegs,
                      );
                    } else if (type == 'Sectors') {
                      final diameterNm = double.tryParse(coverageCtl.text) ?? 2;
                      final stepDeg = double.tryParse(angleStepCtl.text) ?? 30;
                      pts = _genSectors(
                        center: start,
                        bearingDeg: bearing,
                        turnDir: turn,
                        diameterNm: diameterNm,
                        angleStepDeg: stepDeg,
                      );
                    } else if (type == 'Orbit') {
                      final radiusNm = double.tryParse(coverageCtl.text) ?? 1;
                      final laps = int.tryParse(lapsCtl.text) ?? 1;
                      final arcStep = int.tryParse(arcStepCtl.text) ?? 15;
                      pts = _genOrbit(
                        center: start,
                        startBearingDeg: bearing,
                        turnDir: turn,
                        radiusNm: radiusNm,
                        laps: laps,
                        arcStepDeg: arcStep,
                      );
                    } else if (type == 'Racetrack') {
                      final legLenNm = double.tryParse(coverageCtl.text) ?? 2;
                      final radiusNm = double.tryParse(spacingCtl.text) ?? 0.5;
                      final arcStep = int.tryParse(arcStepCtl.text) ?? 15;
                      pts = _genRacetrack(
                        fix: start,
                        bearingDeg: bearing,
                        turnDir: turn,
                        legLenNm: legLenNm,
                        turnRadiusNm: radiusNm,
                        arcStepDeg: arcStep,
                      );
                    }
                    if (appendToRoute) {
                      setState(() {
                        final paramMap = <String, dynamic>{
                          'type': type,
                          'bearing': bearing,
                          'turn': turn,
                          'legs': int.tryParse(legsCtl.text) ?? 0,
                          'coverage': double.tryParse(coverageCtl.text),
                          'spacing': double.tryParse(spacingCtl.text),
                          'angleStep': double.tryParse(angleStepCtl.text),
                          'laps': int.tryParse(lapsCtl.text) ?? 0,
                          'arcStep': int.tryParse(arcStepCtl.text) ?? 10,
                        };
                        if (editingSeg != null) {
                          // Replace existing segment
                          final seg = editingSeg;
                          final firstPatternIdx = seg.start - 1;
                          final fullCountOld = seg.count + 1;
                          final removeStart = firstPatternIdx >= 0
                              ? firstPatternIdx
                              : seg.start;
                          final removeEndExclusive =
                              (removeStart + fullCountOld).clamp(
                                0,
                                _routePoints.length,
                              );
                          if (removeEndExclusive > removeStart) {
                            _routePoints.removeRange(
                              removeStart,
                              removeEndExclusive,
                            );
                          }
                          // Insert new points
                          _routePoints.insertAll(removeStart, pts);
                          seg
                            ..start = removeStart + 1
                            ..count = (pts.length > 1 ? pts.length - 1 : 0)
                            ..params.clear()
                            ..params.addAll(paramMap)
                            ..type = type;
                          final delta = pts.length - fullCountOld;
                          if (delta != 0) {
                            for (final s in _patternSegments) {
                              if (identical(s, seg)) continue;
                              if (s.start > removeStart) s.start += delta;
                            }
                          }
                          if (_activeLegIndex >= removeStart) {
                            _activeLegIndex = math.min(
                              _activeLegIndex + delta,
                              math.max(0, _routePoints.length - 2),
                            );
                          }
                        } else if (startWaypointIndex != null &&
                            startWaypointIndex >= 0 &&
                            startWaypointIndex < _routePoints.length) {
                          final skip = 1; // skip duplicate starting waypoint
                          final addPts = pts.length > skip
                              ? pts.sublist(skip)
                              : const <LatLng>[];
                          final insertionIdx = startWaypointIndex + 1;
                          _routePoints.insertAll(insertionIdx, addPts);
                          final seg = _PatternSegment(
                            id: _nextPatternId++,
                            start: insertionIdx,
                            count: addPts.length,
                            type: type,
                            params: paramMap,
                          );
                          _patternSegments.add(seg);
                          for (final s in _patternSegments) {
                            if (!identical(s, seg) && s.start >= insertionIdx) {
                              s.start += addPts.length;
                            }
                          }
                          if (_activeLegIndex > startWaypointIndex) {
                            _activeLegIndex += addPts.length;
                          }
                        } else if (_routePoints.isEmpty) {
                          _routePoints.addAll(pts);
                          if ((type == 'Orbit' || type == 'Racetrack') &&
                              pts.length > 1) {
                            final seg = _PatternSegment(
                              id: _nextPatternId++,
                              start: 1,
                              count: pts.length - 1,
                              type: type,
                              params: paramMap,
                            );
                            _patternSegments.add(seg);
                          }
                        } else {
                          final joiningSameStart =
                              pts.isNotEmpty && _routePoints.last == pts.first;
                          final insertionIdx = _routePoints.length;
                          final Iterable<LatLng> add = joiningSameStart
                              ? pts.skip(1)
                              : pts;
                          _routePoints.addAll(add);
                          if ((type == 'Orbit' || type == 'Racetrack') &&
                              add.isNotEmpty) {
                            final startIndex = joiningSameStart
                                ? insertionIdx
                                : insertionIdx + 1;
                            final count = joiningSameStart
                                ? add.length
                                : (add.isNotEmpty ? add.length - 1 : 0);
                            if (count > 0) {
                              final seg = _PatternSegment(
                                id: _nextPatternId++,
                                start: startIndex,
                                count: count,
                                type: type,
                                params: paramMap,
                              );
                              _patternSegments.add(seg);
                            }
                          }
                        }
                        _previewPatternPoints = [];
                      });
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            editingSeg != null
                                ? 'Pattern updated'
                                : 'Added ${pts.length} points to route',
                          ),
                        ),
                      );
                    } else {
                      setState(() => _previewPatternPoints = pts);
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Text('Generate'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Pattern segments metadata for SAR patterns inserted at waypoints
  final List<_PatternSegment> _patternSegments = [];
  int _nextPatternId = 1;

  // Airport data
  final List<_Airport> _airports = [];
  // Saved waypoints
  final List<_Waypoint> _waypoints = [];
  // Saved routes library
  final List<_SavedRoute> _savedRoutes = [];
  // Each airspace: {'perimeter': List<LatLng>, 'name': String?}
  List<Map<String, dynamic>> _airspacePerimeters = [];
  // Power lines: list of polylines (each is a List<LatLng>)
  List<List<LatLng>> _powerLinePolys = [];
  // Villages loaded from asset
  List<_Village> _villages = [];
  // IFR reporting points (all countries combined)
  List<_ReportingPoint> _reportingPoints = [];
  // Saved areas (circles / polygons / lines)
  final List<_SavedArea> _savedAreas = [];
  // Imported layers (from KML/GPX) with visibility toggles
  final List<_ImportedLayer> _importedLayers = [];
  // Polygon drafting state
  bool _draftPolygonMode = false;
  final List<LatLng> _draftPolygonPoints = [];
  // Line drafting state
  bool _draftLineMode = false;
  final List<LatLng> _draftLinePoints = [];

  // Saved-area lines visibility (quick toggle)
  bool _showSavedAreaLines = true;

  // Polygon vertex edit state
  bool _vertexEditMode =
      false; // true when editing a saved polygon's vertices on map
  int? _vertexEditAreaIndex; // index in _savedAreas of the polygon being edited
  final List<LatLng> _vertexEditPoints =
      []; // working copy of polygon points (closed ring)
  int?
  _vertexEditSelectedVertex; // index of vertex selected for reposition by tap
  bool _vertexDragging = false; // true while a vertex handle is being dragged
  LatLng? _vertexDragPos; // live position under drag
  int? _vertexDragIndex; // which vertex is being dragged (1-based for UI)
  Offset? _vertexDragLocalPos; // overlay anchor in Stack-local coordinates

  // Draft line drag state (for dragging the last endpoint to create a WPT)

  void _updateDragOverlayPosition(Offset global) {
    final ctx = _mapStackKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(global);
    // Clamp within stack bounds with margin
    final size = box.size;
    const margin = 8.0;
    double dx = local.dx.clamp(margin, size.width - margin);
    double dy = local.dy.clamp(margin, size.height - margin);
    setState(() => _vertexDragLocalPos = Offset(dx, dy));
  }

  // Build a draggable vertex handle widget
  // Build draggable vertex handle (long-press then drag, or tap to select)
  Widget _buildDraggableVertexHandle(int i) {
    final selected = _vertexEditSelectedVertex == i;
    LatLng startPos = _vertexEditPoints[i];
    Offset? dragStartGlobal;
    return GestureDetector(
      onTap: () => setState(() => _vertexEditSelectedVertex = i),
      onLongPressStart: (d) {
        dragStartGlobal = d.globalPosition;
        startPos = _vertexEditPoints[i];
        setState(() {
          _vertexEditSelectedVertex = i;
          _vertexDragging = true;
          _vertexDragIndex = i + 1;
          _vertexDragPos = startPos;
        });
        _updateDragOverlayPosition(d.globalPosition);
      },
      onLongPressMoveUpdate: (d) {
        if (dragStartGlobal == null) return;
        final delta = d.globalPosition - dragStartGlobal!;
        final centerLat = startPos.latitude;
        final metersPerDegLat = 111320.0;
        final metersPerDegLon =
            111320.0 * math.cos(centerLat * math.pi / 180.0);
        final dLat = delta.dy / metersPerDegLat;
        final dLon = delta.dx / metersPerDegLon;
        final newPos = LatLng(
          startPos.latitude - dLat,
          startPos.longitude + dLon,
        );
        setState(() {
          _vertexEditPoints[i] = newPos;
          if (i == 0 && _vertexEditPoints.length > 1) {
            _vertexEditPoints[_vertexEditPoints.length - 1] = newPos;
          } else if (i == _vertexEditPoints.length - 1 &&
              _vertexEditPoints.length > 1) {
            _vertexEditPoints[0] = newPos;
          }
        });
      },
      onLongPressEnd: (_) {
        setState(() {
          _vertexDragging = false;
          _vertexDragIndex = null;
        });
        _vertexDragLocalPos = null;
      },
      child: Container(
        decoration: BoxDecoration(
          color: selected ? Colors.yellowAccent : Colors.orangeAccent,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black87, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 2)],
        ),
        alignment: Alignment.center,
        width: 36,
        height: 36,
        child: Text(
          '${i + 1}',
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  // Build draggable handle for the draft line endpoint (last point).
  Widget _buildDraggableDraftEndpoint() {
    if (_draftLinePoints.isEmpty) return const SizedBox.shrink();
    final idx = _draftLinePoints.length - 1;
    LatLng startPos = _draftLinePoints[idx];
    Offset? dragStartGlobal;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Touch long-press drag (mobile / iPad)
      onLongPressStart: (d) {
        dragStartGlobal = d.globalPosition;
        startPos = _draftLinePoints[idx];
        _updateDragOverlayPosition(d.globalPosition);
      },
      onLongPressMoveUpdate: (d) {
        if (dragStartGlobal == null) return;
        final delta = d.globalPosition - dragStartGlobal!;
        final centerLat = startPos.latitude;
        final metersPerDegLat = 111320.0;
        final metersPerDegLon =
            111320.0 * math.cos(centerLat * math.pi / 180.0);
        final dLat = delta.dy / metersPerDegLat;
        final dLon = delta.dx / metersPerDegLon;
        final newPos = LatLng(
          startPos.latitude - dLat,
          startPos.longitude + dLon,
        );
        setState(() {
          _draftLinePoints[idx] = newPos;
        });
        _updateDragOverlayPosition(d.globalPosition);
      },
      onLongPressEnd: (d) {
        // create waypoint at final dropped position
        final finalPos = _draftLinePoints[idx];
        final now = DateTime.now();
        final name =
            'WPT ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        final wp = _Waypoint(
          id: now.microsecondsSinceEpoch.toString(),
          name: name,
          lat: finalPos.latitude,
          lon: finalPos.longitude,
          altMeters: null,
          type: 'User',
          createdAt: now,
        );
        _addWaypoint(wp);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created waypoint "${wp.name}"')),
        );
      },
      // Mouse / pointer drag support for web/desktop (Chrome)
      onPanStart: (details) {
        dragStartGlobal = details.globalPosition;
        startPos = _draftLinePoints[idx];
        _updateDragOverlayPosition(details.globalPosition);
      },
      onPanUpdate: (details) {
        if (dragStartGlobal == null) return;
        final delta = details.globalPosition - dragStartGlobal!;
        final centerLat = startPos.latitude;
        final metersPerDegLat = 111320.0;
        final metersPerDegLon =
            111320.0 * math.cos(centerLat * math.pi / 180.0);
        final dLat = delta.dy / metersPerDegLat;
        final dLon = delta.dx / metersPerDegLon;
        final newPos = LatLng(
          startPos.latitude - dLat,
          startPos.longitude + dLon,
        );
        setState(() {
          _draftLinePoints[idx] = newPos;
        });
        _updateDragOverlayPosition(details.globalPosition);
      },
      onPanEnd: (details) {
        // create waypoint on drop
        final finalPos = _draftLinePoints[idx];
        final now = DateTime.now();
        final name =
            'WPT ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        final wp = _Waypoint(
          id: now.microsecondsSinceEpoch.toString(),
          name: name,
          lat: finalPos.latitude,
          lon: finalPos.longitude,
          altMeters: null,
          type: 'User',
          createdAt: now,
        );
        _addWaypoint(wp);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created waypoint "${wp.name}"')),
        );
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.orangeAccent,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black87, width: 2),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.drag_handle, size: 18, color: Colors.black),
      ),
    );
  }

  void _applyVertexEdit() {
    if (!_vertexEditMode || _vertexEditAreaIndex == null) return;
    final idx = _vertexEditAreaIndex!;
    if (idx < 0 || idx >= _savedAreas.length) {
      setState(() {
        _vertexEditMode = false;
        _vertexEditAreaIndex = null;
        _vertexEditPoints.clear();
      });
      return;
    }
    // Ensure ring closure
    if (_vertexEditPoints.length >= 3) {
      final pts = List<LatLng>.from(_vertexEditPoints);
      if (pts.first != pts.last) pts.add(pts.first);
      final existing = _savedAreas[idx];
      setState(() {
        _savedAreas[idx] = _SavedArea(
          id: existing.id,
          name: existing.name,
          type: existing.type,
          centerLat: null,
          centerLon: null,
          radiusNm: null,
          points: pts,
          createdAt: existing.createdAt,
          strokeColorHex: existing.strokeColorHex,
          fillColorHex: existing.fillColorHex,
        );
        _vertexEditMode = false;
        _vertexEditAreaIndex = null;
        _vertexEditPoints.clear();
        _vertexEditSelectedVertex = null;
      });
      _persistSavedAreas();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Vertices updated')));
    }
  }

  void _cancelVertexEdit() {
    setState(() {
      _vertexEditMode = false;
      _vertexEditAreaIndex = null;
      _vertexEditPoints.clear();
      _vertexEditSelectedVertex = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Vertex edit cancelled')));
  }

  // Navaids & Obstacles
  final List<_Navaid> _navaids = [];
  final List<_Obstacle> _obstacles = [];

  // Per-country per-layer toggles
  bool _showCyAirports = true;
  bool _showCyAirspace = false;
  bool _showCyNavaids = false;
  bool _showCyReportingPoints = false;
  bool _showCyObstacles = false;
  bool _showCyPowerLines = true;

  bool _showGrAirports = false;
  bool _showGrAirspace = false; // placeholder until GR airspace available
  bool _showGrNavaids = false;
  bool _showGrReportingPoints = false;
  bool _showGrObstacles = false;

  bool _showIlAirports = false;
  bool _showIlAirspace = false; // placeholder until IL airspace available
  bool _showIlNavaids = false;
  bool _showIlReportingPoints = false;
  bool _showIlObstacles = false;
  // Global toggle controlling visibility of saved waypoint markers
  bool _showWaypoints = true;

  // Ruler tool: measure distance (NM) and bearings between two points
  bool _rulerActive = false;
  LatLng? _rulerStart;
  LatLng? _rulerEnd;

  // Power lines voice alert (live callouts every 0.2 nm from 1.0 -> 0.0 while approaching)
  bool _powerLineVoiceAlert = true; // toggle in UI
  // Callout configuration (treated as instance finals to avoid 'static' lints inside state class)
  final double _powerLineCalloutMaxNm = 1.0; // start announcing at or below
  final double _powerLineCalloutStepNm = 0.2; // step interval
  final double _powerLineResetBufferNm =
      1.2; // distance to reset after moving away
  final double _powerLineAheadConeDeg = 70; // forward cone half-angle
  final double _powerLineOverheadNm = 0.05; // ~300 ft
  double? _lastPowerLineCalloutBoundary; // last boundary announced (e.g. 0.8)
  double? _lastPowerLineDistanceNm; // for downward crossing detection
  bool _powerLineOverheadAnnounced = false; // avoid repeating 0.0

  // Obstacles voice alerts (two thresholds with cone + vertical band)
  bool _obstacleVoiceAlert = true;
  // Voice phrasing: relative (left/right) vs absolute (degrees)
  bool _voiceRelativeBearing = true;
  double _obstacleConeDeg = 30; // forward cone half-angle (deg)
  double _obstacleWarn1Nm = 1.0; // first boundary (nm)
  double _obstacleWarn2Nm = 0.5; // second boundary (nm)
  int _obstacleTopBandFt = 500; // within +/- band from obstacle top
  String? _lastObstacleKey; // nearest obstacle identity
  double? _lastObstacleDistanceNm; // last distance to nearest
  double? _lastObstacleAnnounced; // last boundary spoken (nm)

  bool _isObstaclesVisibleForCountry(String c) {
    switch (c.toUpperCase()) {
      case 'CY':
        return _showCyObstacles;
      case 'GR':
        return _showGrObstacles;
      case 'IL':
        return _showIlObstacles;
      default:
        // For any other country added later, allow alerts by default
        return true;
    }
  }

  void _toggleRuler() {
    setState(() {
      if (_rulerActive) {
        _rulerActive = false;
        _rulerStart = null;
        _rulerEnd = null;
      } else {
        _rulerActive = true;
        _rulerStart = null;
        _rulerEnd = null;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ruler active: tap start and end on map'),
          ),
        );
      }
    });
  }

  void _handleRulerTap(LatLng latLng) {
    if (!_rulerActive) return;
    setState(() {
      if (_rulerStart == null) {
        _rulerStart = latLng;
        _rulerEnd = null;
      } else if (_rulerEnd == null) {
        _rulerEnd = latLng;
      } else {
        _rulerStart = latLng;
        _rulerEnd = null;
      }
    });
  }

  void _addRulerEndToRoute() {
    if (_rulerEnd == null) return;
    setState(() {
      if (_routePoints.isEmpty && _currentPosition != null) {
        // Seed route with current position for meaningful leg start
        _routePoints.add(_currentPosition!);
      }
      _routePoints.add(_rulerEnd!);
      if (_activeLegIndex >= _routePoints.length - 1) {
        _activeLegIndex = 0; // reset start if only one leg now
      }
    });
    _persistRoute();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Ruler end added to route')));
  }

  void _zoomToPowerLines() {
    final segments = _gatherPowerLineSegments();
    if (segments.isEmpty) return;
    double? minLat, minLon, maxLat, maxLon;
    for (final line in segments) {
      for (final p in line) {
        final lat = p.latitude;
        final lon = p.longitude;
        minLat = (minLat == null) ? lat : math.min(minLat, lat);
        maxLat = (maxLat == null) ? lat : math.max(maxLat, lat);
        minLon = (minLon == null) ? lon : math.min(minLon, lon);
        maxLon = (maxLon == null) ? lon : math.max(maxLon, lon);
      }
    }
    if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
      return;
    }
    final center = LatLng((minLat + maxLat) / 2.0, (minLon + maxLon) / 2.0);
    final spanLat = (maxLat - minLat).abs();
    final spanLon = (maxLon - minLon).abs();
    double zoom;
    final span = math.max(spanLat, spanLon);
    if (span < 0.05) {
      zoom = 14.0;
    } else if (span < 0.2) {
      zoom = 12.5;
    } else if (span < 0.6) {
      zoom = 11.0;
    } else if (span < 1.5) {
      zoom = 10.0;
    } else if (span < 3.0) {
      zoom = 9.5;
    } else if (span < 6.0) {
      zoom = 9.0;
    } else {
      zoom = 8.0;
    }
    _mapController.move(center, zoom);
  }

  // Compute initial true bearing from A to B (0..360, 0 = North)
  double _bearingDegrees(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;
    final dLon = (b.longitude - a.longitude) * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final brg = math.atan2(y, x) * 180.0 / math.pi;
    return (brg % 360 + 360) % 360;
  }

  // Format bearing from current heading to target as relative: "20 degrees to the left/right" or "ahead".
  String _formatRelativeBearing(double headingDeg, double targetBearingDeg) {
    if (!headingDeg.isFinite || !targetBearingDeg.isFinite) return 'ahead';
    double d =
        ((targetBearingDeg - headingDeg + 540.0) % 360.0) - 180.0; // -180..180
    final side = d >= 0 ? 'to the right' : 'to the left';
    final mag = d.abs().round();
    if (mag == 0) return 'ahead';
    return '$mag degrees $side';
  }

  String _fmt3(double v) => v.toStringAsFixed(0).padLeft(3, '0');

  // Format ground track as 3-digit degrees plus cardinal (e.g., 090° E)
  String _formatTrack() {
    final deg = _currentHeadingDeg;
    if (deg.isNaN) return '--';
    final d3 = _fmt3(deg);
    return '$d3° ${_cardinal(deg)}';
  }

  String _cardinal(double deg) {
    final dirs = [
      'N',
      'NNE',
      'NE',
      'ENE',
      'E',
      'ESE',
      'SE',
      'SSE',
      'S',
      'SSW',
      'SW',
      'WSW',
      'W',
      'WNW',
      'NW',
      'NNW',
    ];
    final norm = _normalize360(deg);
    final idx = ((norm + 11.25) / 22.5).floor() % 16;
    return dirs[idx];
  }

  // Compute nearest distance in meters from pos to any power-line segment.
  // Returns a tuple-like map with {'meters': double, 'point': LatLng} for closest point.
  List<List<LatLng>> _gatherPowerLineSegments() {
    final out = <List<LatLng>>[];
    out.addAll(_powerLinePolys);
    for (final l in _importedLayers) {
      if (l.visible && l.useAsPowerLines && l.polylines.isNotEmpty) {
        out.addAll(l.polylines);
      }
    }
    return out;
  }

  Map<String, dynamic>? _nearestPowerLineProximity(LatLng pos) {
    final segments = _gatherPowerLineSegments();
    if (segments.isEmpty) return null;
    double bestMeters = double.infinity;
    LatLng? bestPoint;
    // Local scale for lon->meters at this latitude
    final latRad = pos.latitude * math.pi / 180.0;
    final kx = 111320.0 * math.cos(latRad);
    const ky = 110540.0;

    double distToSegmentMeters(LatLng p, LatLng a, LatLng b) {
      final px = (p.longitude - a.longitude) * kx;
      final py = (p.latitude - a.latitude) * ky;
      final vx = (b.longitude - a.longitude) * kx;
      final vy = (b.latitude - a.latitude) * ky;
      final vLen2 = vx * vx + vy * vy;
      double t = 0.0;
      if (vLen2 > 0) t = (px * vx + py * vy) / vLen2;
      t = t.clamp(0.0, 1.0);
      final cx = vx * t;
      final cy = vy * t;
      final dx = px - cx;
      final dy = py - cy;
      final meters = math.sqrt(dx * dx + dy * dy);
      final cLon = a.longitude + (cx / kx);
      final cLat = a.latitude + (cy / ky);
      // Track best
      if (meters < bestMeters) {
        bestMeters = meters;
        bestPoint = LatLng(cLat, cLon);
      }
      return meters;
    }

    for (final line in segments) {
      for (int i = 1; i < line.length; i++) {
        distToSegmentMeters(pos, line[i - 1], line[i]);
      }
    }
    if (bestPoint == null) return null;
    return {'meters': bestMeters, 'point': bestPoint!};
  }

  // --- Village loading & search helpers ---
  // Overlay panel with grouped toggles
  List<Marker> _buildRouteMarkers() {
    return List<Marker>.generate(_routePoints.length, (i) {
      final p = _routePoints[i];
      // Find pattern segment anchored at this waypoint (segment.start == i+1)
      _PatternSegment? anchorSeg;
      for (final seg in _patternSegments) {
        if (seg.start == i + 1) {
          anchorSeg = seg;
          break;
        }
      }
      return Marker(
        point: p,
        width: 34,
        height: 34,
        child: GestureDetector(
          onTap: () {
            showModalBottomSheet(
              context: context,
              backgroundColor: const Color(0xFF1E1E1E),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              ),
              builder: (ctx) {
                final dmsLat = _toDms(p.latitude, isLat: true);
                final dmsLon = _toDms(p.longitude, isLat: false);
                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Waypoint #${i + 1}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ],
                        ),
                        Text(
                          'Lat: $dmsLat\nLon: $dmsLon',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        if (anchorSeg != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Pattern: ${anchorSeg.type} (${anchorSeg.count} pts)',
                            style: const TextStyle(
                              color: Colors.lightBlueAccent,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.deepPurpleAccent,
                              ),
                              onPressed: i < _routePoints.length - 1
                                  ? () {
                                      setState(() => _activeLegIndex = i);
                                      Navigator.of(ctx).pop();
                                    }
                                  : null,
                              icon: const Icon(Icons.flag),
                              label: const Text('Set Active Leg'),
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal,
                              ),
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                _openSearchPatternsDialog(
                                  startPoint: p,
                                  startWaypointIndex: i,
                                  editingPatternId: anchorSeg?.id,
                                );
                              },
                              icon: const Icon(Icons.route),
                              label: Text(
                                anchorSeg != null
                                    ? 'Edit Pattern'
                                    : 'Pattern Here',
                              ),
                            ),
                            if (anchorSeg != null)
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.indigo,
                                ),
                                onPressed: () {
                                  setState(() {
                                    final seg = anchorSeg!;
                                    final startIdx = seg.start;
                                    final endIdx = (seg.start + seg.count)
                                        .clamp(0, _routePoints.length);
                                    if (endIdx > startIdx) {
                                      _routePoints.removeRange(
                                        startIdx,
                                        endIdx,
                                      );
                                    }
                                    final removedCount = seg.count;
                                    _patternSegments.removeWhere(
                                      (s) => s.id == seg.id,
                                    );
                                    for (final s in _patternSegments) {
                                      if (s.start > startIdx) {
                                        s.start -= removedCount;
                                      }
                                    }
                                    if (_activeLegIndex >= startIdx) {
                                      _activeLegIndex = math.max(
                                        0,
                                        _activeLegIndex - removedCount,
                                      );
                                    }
                                  });
                                  Navigator.of(ctx).pop();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Pattern deleted'),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Delete Pattern'),
                              ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orangeAccent,
                              ),
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                _directTo(p);
                              },
                              icon: const Icon(Icons.navigation),
                              label: const Text('Direct To'),
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                              ),
                              onPressed: () {
                                setState(() {
                                  // If this waypoint anchors a pattern, remove pattern points too
                                  _PatternSegment? seg = anchorSeg;
                                  if (seg != null) {
                                    final startIdx = seg.start;
                                    final endIdx = (seg.start + seg.count)
                                        .clamp(0, _routePoints.length);
                                    if (endIdx > startIdx) {
                                      _routePoints.removeRange(
                                        startIdx,
                                        endIdx,
                                      );
                                      final removedCount = seg.count;
                                      for (final s in _patternSegments) {
                                        if (s.start > startIdx) {
                                          s.start -= removedCount;
                                        }
                                      }
                                    }
                                    _patternSegments.removeWhere(
                                      (s) => s.id == seg.id,
                                    );
                                  }
                                  _routePoints.removeAt(i);
                                  if (_activeLegIndex >=
                                      _routePoints.length - 1) {
                                    _activeLegIndex = math.max(
                                      0,
                                      _routePoints.length - 2,
                                    );
                                  }
                                });
                                Navigator.of(ctx).pop();
                              },
                              icon: const Icon(Icons.delete),
                              label: const Text('Remove'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withValues(alpha: 0.92),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black87, width: 1),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 3),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              '${i + 1}',
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ),
      );
    });
  }

  // Reconstructed overlay menu (was displaced by previous patch)
  Widget _buildOverlayMenu() {
    if (!_overlayExpanded) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _nvgMode ? 'Disable NVG mode' : 'Enable NVG mode',
            icon: Icon(
              _nvgMode ? Icons.nightlight : Icons.nightlight_outlined,
              color: _nvgMode ? const Color(0xFF33AA33) : Colors.white70,
            ),
            onPressed: () async {
              setState(() {
                _nvgMode = !_nvgMode;
                if (_nvgMode) {
                  _nvgStyle = _NvgStyle.full; // prefer full overlay by default
                }
                if (_nvgMode) _nightMode = false; // exclusive
              });
              await _saveNvgSettings();
            },
          ),
          IconButton(
            tooltip: _nightMode ? 'Disable night mode' : 'Enable night mode',
            icon: Icon(
              _nightMode ? Icons.dark_mode : Icons.dark_mode_outlined,
              color: _nightMode ? Colors.blueGrey.shade200 : Colors.white54,
            ),
            onPressed: () async {
              setState(() {
                _nightMode = !_nightMode;
                if (_nightMode) _nvgMode = false; // exclusive
              });
              await _saveNvgSettings();
            },
          ),
          IconButton(
            tooltip: 'Map options',
            icon: Icon(
              Icons.tune,
              color: _nvgMode ? const Color(0xFF6BFF6B) : Colors.white,
            ),
            onPressed: () => _setOverlayExpanded(true),
          ),
        ],
      );
    }
    final mq = MediaQuery.of(context);
    final screenH = mq.size.height;
    final screenW = mq.size.width;
    // Reserve space for status bar + bottom insets and a small margin.
    final double reservedTop = mq.padding.top;
    final double reservedBottom = mq.padding.bottom;
    final double maxPanelHeight =
        screenH - reservedTop - reservedBottom - 80; // 80px breathing room
    // Responsive width to avoid right overflow on small screens
    final double panelWidth = (screenW - 16).clamp(280.0, 420.0);
    return SizedBox(
      width: panelWidth,
      height: maxPanelHeight.clamp(
        300,
        screenH,
      ), // enforce a reasonable min height
      child: Listener(
        onPointerDown: (_) => _startOverlayAutoCloseTimer(),
        child: Material(
          color: _nvgMode
              ? const Color(0xFF0D1F0D).withValues(alpha: 0.85)
              : Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                primary: false,
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Layers & Options',
                            style: TextStyle(
                              color: _nvgMode
                                  ? const Color(0xFF6BFF6B)
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _nvgMode
                              ? 'Disable NVG mode'
                              : 'Enable NVG mode',
                          icon: Icon(
                            _nvgMode
                                ? Icons.nightlight
                                : Icons.nightlight_outlined,
                            color: _nvgMode
                                ? const Color(0xFF33AA33)
                                : Colors.white70,
                          ),
                          onPressed: () async {
                            setState(() {
                              _nvgMode = !_nvgMode;
                              if (_nvgMode) {
                                _nvgStyle = _NvgStyle
                                    .full; // prefer full overlay by default
                              }
                              if (_nvgMode) _nightMode = false;
                            });
                            await _saveNvgSettings();
                          },
                        ),
                        IconButton(
                          tooltip: _nightMode
                              ? 'Disable night mode'
                              : 'Enable night mode',
                          icon: Icon(
                            _nightMode
                                ? Icons.dark_mode
                                : Icons.dark_mode_outlined,
                            color: _nightMode
                                ? Colors.blueGrey.shade200
                                : Colors.white54,
                          ),
                          onPressed: () async {
                            setState(() {
                              _nightMode = !_nightMode;
                              if (_nightMode) _nvgMode = false;
                            });
                            await _saveNvgSettings();
                          },
                        ),
                        IconButton(
                          tooltip: 'Cruise calculator',
                          icon: const Icon(Icons.speed, color: Colors.white70),
                          onPressed: () async {
                            _setOverlayExpanded(false);
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const CruiseInputScreen(),
                              ),
                            );
                          },
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => _setOverlayExpanded(false),
                        ),
                      ],
                    ),
                    const Divider(height: 10, color: Colors.white24),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            _setOverlayExpanded(false);
                            _openRouteManager();
                          },
                          icon: const Icon(Icons.polyline),
                          label: const Text('Route tools'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            _setOverlayExpanded(false);
                            _showFlightLog();
                          },
                          icon: const Icon(Icons.list_alt),
                          label: const Text('Flight Log'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            _setOverlayExpanded(false);
                            _startLiveShare();
                          },
                          icon: const Icon(Icons.share_location),
                          label: const Text('Live Share'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            _setOverlayExpanded(false);
                            _openVillageSearch();
                          },
                          icon: const Icon(Icons.search),
                          label: const Text('Search '),
                        ),
                        // Combined Waypoints/Routes button: opens the same manager.
                        PopupMenuButton<String>(
                          color: const Color(0xFF1E1E1E),
                          onSelected: (sel) {
                            _setOverlayExpanded(false);
                            if (sel == 'routes') {
                              _openWaypointsFolder(initialShowRoutes: true);
                            } else {
                              _openWaypointsFolder();
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'waypoints',
                              child: Text('Waypoints'),
                            ),
                            const PopupMenuItem(
                              value: 'routes',
                              child: Text('Routes'),
                            ),
                          ],
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              // Default action: open Waypoints tab
                              _setOverlayExpanded(false);
                              _openWaypointsFolder();
                            },
                            icon: const Icon(Icons.folder),
                            label: const Text('Waypoints & Routes'),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            _setOverlayExpanded(false);
                            _openAreasManager();
                          },
                          icon: const Icon(Icons.hexagon_outlined),
                          label: const Text('Areas'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            _setOverlayExpanded(false);
                            _openImportsManager();
                          },
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Imports'),
                        ),
                        // (Cruise quick action removed here; keep only top-right dedicated button)
                        // Removed duplicate Warnings entry; use top-left always-visible Warnings button
                      ],
                    ),
                    // Quick toggles toolbar: Airspaces / Lines / Zoom
                    Padding(
                      padding: const EdgeInsets.only(top: 6.0, bottom: 4.0),
                      child: Row(
                        children: [
                          // Airspaces (toggle all countries)
                          IconButton(
                            tooltip: 'Toggle airspaces',
                            icon: Icon(
                              Icons.map,
                              color:
                                  (_showCyAirspace ||
                                      _showGrAirspace ||
                                      _showIlAirspace)
                                  ? Colors.orangeAccent
                                  : Colors.white70,
                            ),
                            onPressed: () {
                              final anyOn =
                                  _showCyAirspace ||
                                  _showGrAirspace ||
                                  _showIlAirspace;
                              setState(() {
                                final newVal = !anyOn;
                                _showCyAirspace = newVal;
                                _showGrAirspace = newVal;
                                _showIlAirspace = newVal;
                              });
                            },
                          ),
                          // Lines (saved-area lines + power lines)
                          IconButton(
                            tooltip: 'Toggle lines (areas + power lines)',
                            icon: Icon(
                              Icons.alt_route,
                              color: (_showSavedAreaLines || _showCyPowerLines)
                                  ? Colors.orangeAccent
                                  : Colors.white70,
                            ),
                            onPressed: () {
                              final anyOn =
                                  _showSavedAreaLines || _showCyPowerLines;
                              setState(() {
                                final newVal = !anyOn;
                                _showSavedAreaLines = newVal;
                                _showCyPowerLines = newVal;
                              });
                            },
                          ),
                          // Zoom to power lines
                          IconButton(
                            tooltip: 'Zoom to power lines',
                            icon: const Icon(
                              Icons.center_focus_strong,
                              color: Colors.white,
                            ),
                            onPressed: _zoomToPowerLines,
                          ),
                        ],
                      ),
                    ),
                    // (Removed misplaced Cruise/Live-share block that corrupted the quick toggles area)
                    const SizedBox(height: 6),
                    const Divider(height: 10, color: Colors.white24),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 2),
                      child: Text(
                        'View',
                        style: TextStyle(
                          color: _nvgMode
                              ? const Color(0xFF33AA33)
                              : Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: _autoCenter,
                      onChanged: (v) => setState(() => _autoCenter = v),
                      title: const Text(
                        'Auto center on aircraft',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: _headingUp,
                      onChanged: (v) => setState(() {
                        _headingUp = v;
                        if (!_headingUp) {
                          _mapController.rotate(0.0);
                        } else {
                          _mapController.rotate(_currentHeadingDeg);
                        }
                      }),
                      title: const Text(
                        'Heading up',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: _posDms,
                      onChanged: (v) => setState(() => _posDms = v),
                      title: const Text(
                        'Info bar: Position in DMS',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (_nvgMode) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 2),
                        child: Text(
                          'NVG',
                          style: TextStyle(
                            color: _nvgMode
                                ? const Color(0xFF33AA33)
                                : Colors.orangeAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              min: 0.2,
                              max: 1.0,
                              divisions: 8,
                              label: '${(_nvgIntensity * 100).round()}%',
                              value: _nvgIntensity,
                              onChanged: (v) async {
                                setState(() => _nvgIntensity = v);
                                await _saveNvgSettings();
                              },
                            ),
                          ),
                          SizedBox(
                            width: 56,
                            child: Text(
                              '${(_nvgIntensity * 100).round()}%',
                              textAlign: TextAlign.end,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          ChoiceChip(
                            label: const Text('UI Only'),
                            selected: _nvgStyle == _NvgStyle.uiOnly,
                            onSelected: (sel) async {
                              if (!sel) return;
                              setState(() => _nvgStyle = _NvgStyle.uiOnly);
                              await _saveNvgSettings();
                            },
                            selectedColor: const Color(0xFF163316),
                            labelStyle: TextStyle(
                              color: _nvgStyle == _NvgStyle.uiOnly
                                  ? const Color(0xFF55FF55)
                                  : Colors.white70,
                            ),
                          ),
                          ChoiceChip(
                            label: const Text('Full Overlay'),
                            selected: _nvgStyle == _NvgStyle.full,
                            onSelected: (sel) async {
                              if (!sel) return;
                              setState(() => _nvgStyle = _NvgStyle.full);
                              await _saveNvgSettings();
                            },
                            selectedColor: const Color(0xFF163316),
                            labelStyle: TextStyle(
                              color: _nvgStyle == _NvgStyle.full
                                  ? const Color(0xFF55FF55)
                                  : Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_nightMode) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 2),
                        child: Text(
                          'Night',
                          style: TextStyle(
                            color: Colors.blueGrey.shade200,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Text(
                        'Night mode dims and desaturates the map for reduced eye strain.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Brightness reduced ~55%.',
                        style: TextStyle(
                          color: Colors.blueGrey.shade200,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    // Warnings controls moved to dedicated sub-panel (see "Warnings" quick action)
                    // Cruise calculator toggle removed from view options.
                    const SizedBox(height: 6),
                    const Divider(height: 10, color: Colors.white24),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 2),
                      child: Text(
                        'Weather',
                        style: TextStyle(
                          color: _nvgMode
                              ? const Color(0xFF33AA33)
                              : Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: _showWind,
                      onChanged: (v) => setState(() => _showWind = v),
                      title: const Text(
                        'Show wind',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    // Winds aloft level selector
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0, bottom: 2.0),
                      child: Row(
                        children: [
                          const Text(
                            'Wind level',
                            style: TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Slider(
                              min: 0,
                              max: (_windLevelsFt.length - 1).toDouble(),
                              divisions: _windLevelsFt.length - 1,
                              label: _wxWindLevelIdx == 0
                                  ? 'SFC'
                                  : '${_windLevelsFt[_wxWindLevelIdx]} ft',
                              value: _wxWindLevelIdx.toDouble(),
                              onChanged: (v) async {
                                setState(() {
                                  _wxWindLevelIdx = v.round();
                                });
                                // Auto-refresh wind overlay when level changes
                                if (_showWind) {
                                  await _refreshWeatherOverlays();
                                }
                              },
                            ),
                          ),
                          SizedBox(
                            width: 64,
                            child: Text(
                              _wxWindLevelIdx == 0
                                  ? 'SFC'
                                  : '${_windLevelsFt[_wxWindLevelIdx] ~/ 1000}k ft',
                              textAlign: TextAlign.end,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: _showClouds,
                      onChanged: (v) => setState(() => _showClouds = v),
                      title: const Text(
                        'Show clouds',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: _showRain,
                      onChanged: (v) => setState(() => _showRain = v),
                      title: const Text(
                        'Show rain',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: _wxShowPercentLabels,
                      onChanged: (v) =>
                          setState(() => _wxShowPercentLabels = v),
                      title: const Text(
                        'WX markers: show % labels',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    // Weather territory controls
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0, bottom: 2.0),
                      child: Row(
                        children: [
                          const Text(
                            'Radius',
                            style: TextStyle(color: Colors.white70),
                          ),
                          Expanded(
                            child: Slider(
                              min: 25,
                              max: 400,
                              divisions: 15,
                              label: '${_wxRadiusKm.round()} km',
                              value: _wxRadiusKm,
                              onChanged: (v) => setState(() => _wxRadiusKm = v),
                            ),
                          ),
                          SizedBox(
                            width: 70,
                            child: Text(
                              '${_wxRadiusKm.round()} km',
                              textAlign: TextAlign.end,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        const Text(
                          'Grid',
                          style: TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(width: 8),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final n in [3, 5, 7, 9])
                              ChoiceChip(
                                label: Text('${n}x$n'),
                                selected: _wxGridSide == n,
                                onSelected: (_) =>
                                    setState(() => _wxGridSide = n),
                              ),
                          ],
                        ),
                        const Spacer(),
                        Text(
                          '${_wxGridSide * _wxGridSide} req',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),

                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        children: [
                          const Text(
                            'WX opacity',
                            style: TextStyle(color: Colors.white70),
                          ),
                          Expanded(
                            child: Slider(
                              min: 0.25,
                              max: 1.0,
                              divisions: 3,
                              label: (_wxOpacity * 100).round().toString(),
                              value: _wxOpacity,
                              onChanged: (v) => setState(() => _wxOpacity = v),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          FilledButton.icon(
                            onPressed: _refreshWeatherOverlays,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Refresh WX overlays'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _cloudCells.clear();
                                _rainCells.clear();
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('WX overlays cleared'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.delete_sweep),
                            label: const Text('Clear'),
                          ),
                        ],
                      ),
                    ),
                    // Compact legend for weather colour ramps
                    Container(
                      margin: const EdgeInsets.only(top: 6, bottom: 4),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF222222),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Legend',
                            style: TextStyle(
                              color: Colors.orangeAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _buildWxLegendRow('Clouds', [
                            _cloudColorForDensity(0.0),
                            _cloudColorForDensity(0.25),
                            _cloudColorForDensity(0.5),
                            _cloudColorForDensity(0.75),
                            _cloudColorForDensity(1.0),
                          ]),
                          const SizedBox(height: 4),
                          _buildWxLegendRow('Rain', [
                            _rainColorForDensity(0.0),
                            _rainColorForDensity(0.25),
                            _rainColorForDensity(0.5),
                            _rainColorForDensity(0.75),
                            _rainColorForDensity(1.0),
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Divider(height: 10, color: Colors.white24),
                    Theme(
                      data: Theme.of(context).copyWith(
                        dividerColor: Colors.white12,
                        listTileTheme: const ListTileThemeData(
                          iconColor: Colors.white70,
                          textColor: Colors.white,
                        ),
                      ),
                      child: Column(
                        children: [
                          // Global overlays
                          SwitchListTile.adaptive(
                            dense: true,
                            value: _showWaypoints,
                            onChanged: (v) =>
                                setState(() => _showWaypoints = v),
                            title: InkWell(
                              onTap: () {
                                // Open the same Waypoints/Routes manager as the options menu
                                _setOverlayExpanded(false);
                                _openWaypointsFolder();
                              },
                              child: const Text(
                                'Waypoints',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                          ExpansionTile(
                            initiallyExpanded: false,
                            collapsedIconColor: Colors.white70,
                            textColor: Colors.white,
                            iconColor: Colors.white,
                            title: Row(
                              children: [
                                const Text('Cyprus (CY)'),
                                const Spacer(),
                                IconButton(
                                  tooltip: 'Toggle CY airspace',
                                  icon: Icon(
                                    _showCyAirspace
                                        ? Icons.map
                                        : Icons.map_outlined,
                                    color: _showCyAirspace
                                        ? Colors.orangeAccent
                                        : Colors.white70,
                                  ),
                                  onPressed: () => setState(
                                    () => _showCyAirspace = !_showCyAirspace,
                                  ),
                                ),
                              ],
                            ),
                            childrenPadding: const EdgeInsets.only(left: 8),
                            children: [
                              _countrySwitch(
                                'Airports',
                                _showCyAirports,
                                (v) => _showCyAirports = v,
                              ),
                              _countrySwitch(
                                'Airspace',
                                _showCyAirspace,
                                (v) => _showCyAirspace = v,
                              ),
                              _countrySwitch(
                                'Reporting points',
                                _showCyReportingPoints,
                                (v) => _showCyReportingPoints = v,
                              ),
                              _countrySwitch(
                                'Navaids',
                                _showCyNavaids,
                                (v) => _showCyNavaids = v,
                              ),
                              _countrySwitch(
                                'Obstacles',
                                _showCyObstacles,
                                (v) => _showCyObstacles = v,
                              ),
                              _countrySwitch(
                                'Power lines',
                                _showCyPowerLines,
                                (v) => _showCyPowerLines = v,
                              ),
                            ],
                          ),
                          ExpansionTile(
                            collapsedIconColor: Colors.white70,
                            textColor: Colors.white,
                            iconColor: Colors.white,
                            title: Row(
                              children: [
                                const Text('Greece (GR)'),
                                const Spacer(),
                                IconButton(
                                  tooltip: 'Toggle GR airspace',
                                  icon: Icon(
                                    _showGrAirspace
                                        ? Icons.map
                                        : Icons.map_outlined,
                                    color: _showGrAirspace
                                        ? Colors.orangeAccent
                                        : Colors.white70,
                                  ),
                                  onPressed: () => setState(
                                    () => _showGrAirspace = !_showGrAirspace,
                                  ),
                                ),
                              ],
                            ),
                            childrenPadding: const EdgeInsets.only(left: 8),
                            children: [
                              _countrySwitch(
                                'Airports',
                                _showGrAirports,
                                (v) => _showGrAirports = v,
                              ),
                              _countrySwitch(
                                'Airspace',
                                _showGrAirspace,
                                (v) => _showGrAirspace = v,
                              ),
                              _countrySwitch(
                                'Reporting points',
                                _showGrReportingPoints,
                                (v) => _showGrReportingPoints = v,
                              ),
                              _countrySwitch(
                                'Navaids',
                                _showGrNavaids,
                                (v) => _showGrNavaids = v,
                              ),
                              _countrySwitch(
                                'Obstacles',
                                _showGrObstacles,
                                (v) => _showGrObstacles = v,
                              ),
                            ],
                          ),
                          ExpansionTile(
                            collapsedIconColor: Colors.white70,
                            textColor: Colors.white,
                            iconColor: Colors.white,
                            title: Row(
                              children: [
                                const Text('Israel (IL)'),
                                const Spacer(),
                                IconButton(
                                  tooltip: 'Toggle IL airspace',
                                  icon: Icon(
                                    _showIlAirspace
                                        ? Icons.map
                                        : Icons.map_outlined,
                                    color: _showIlAirspace
                                        ? Colors.orangeAccent
                                        : Colors.white70,
                                  ),
                                  onPressed: () => setState(
                                    () => _showIlAirspace = !_showIlAirspace,
                                  ),
                                ),
                              ],
                            ),
                            childrenPadding: const EdgeInsets.only(left: 8),
                            children: [
                              _countrySwitch(
                                'Airports',
                                _showIlAirports,
                                (v) => _showIlAirports = v,
                              ),
                              _countrySwitch(
                                'Airspace',
                                _showIlAirspace,
                                (v) => _showIlAirspace = v,
                              ),
                              _countrySwitch(
                                'Reporting points',
                                _showIlReportingPoints,
                                (v) => _showIlReportingPoints = v,
                              ),
                              _countrySwitch(
                                'Navaids',
                                _showIlNavaids,
                                (v) => _showIlNavaids = v,
                              ),
                              _countrySwitch(
                                'Obstacles',
                                _showIlObstacles,
                                (v) => _showIlObstacles = v,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ], // children
                ), // Column
              ), // SingleChildScrollView
            ), // Scrollbar
          ), // Padding
        ), // Material
      ), // Listener
    ); // SizedBox
  }

  // Build markers labeling each route leg with bearing and distance to next waypoint
  bool _isLegInPattern(int legIndex) {
    // A pattern segment stores: start = index of 2nd pattern point, count = number of points after the first.
    // The full pattern point index range is [start-1 .. start+count-1]. Legs covered are those between
    // consecutive points in that range, i.e. leg indices [firstPoint .. lastPoint-1].
    for (final seg in _patternSegments) {
      if (seg.count <= 0) continue;
      final int firstPoint = math.max(0, seg.start - 1);
      final int lastPoint = seg.start + seg.count - 1; // inclusive
      final int firstLeg = firstPoint;
      final int lastLeg = lastPoint - 1;
      if (legIndex >= firstLeg && legIndex <= lastLeg) return true;
    }
    return false;
  }

  List<Marker> _buildRouteLegLabels() {
    if (_routePoints.length < 2) return const [];
    final labels = <Marker>[];
    for (int i = 0; i < _routePoints.length - 1; i++) {
      // Hide labels for legs that belong to inserted SAR search patterns
      if (_isLegInPattern(i)) continue;
      final a = _routePoints[i];
      final b = _routePoints[i + 1];
      final brg = _bearingDegrees(a, b);
      final meters = _geo.as(LengthUnit.Meter, a, b);
      final nm = meters / 1852.0;
      // Middle-of-leg anchor with slight perpendicular offset to avoid covering the line
      final mid = LatLng(
        (a.latitude + b.latitude) / 2,
        (a.longitude + b.longitude) / 2,
      );
      const double labelOffsetNm = 0.01; // ~18.5 m
      final midOffset = _offsetNM(mid, labelOffsetNm, _normalize360(brg + 90));
      // Format: 3-digit degrees and distance in NM (1 decimal for < 10nm, else 0)
      final distStr = nm >= 10 ? nm.toStringAsFixed(0) : nm.toStringAsFixed(1);
      final text = '${_fmt3(brg)}°  $distStr nm';
      // Rotate label to align with leg; bearing is from North, so convert to screen angle (0° = east)
      double angDeg = brg - 90.0;
      if (angDeg > 90) angDeg -= 180; // keep text generally upright
      if (angDeg < -90) angDeg += 180;
      final angRad = angDeg * math.pi / 180.0;
      labels.add(
        Marker(
          point: midOffset,
          width: 130,
          height: 34,
          child: Transform.rotate(
            angle: angRad,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFFF00FF), width: 1.2),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 2),
                ],
              ),
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }
    return labels;
  }

  Widget _countrySwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SwitchListTile.adaptive(
    dense: true,
    value: value,
    onChanged: (v) => setState(() => onChanged(v)),
    title: Text(label, style: const TextStyle(color: Colors.white)),
    contentPadding: EdgeInsets.zero,
  );
  Future<void> _loadVillages() async {
    try {
      final text = await rootBundle.loadString(
        'assets/villages/village_cords.geojson',
      );
      final data = jsonDecode(text);
      final List<_Village> villages = [];
      if (data is List) {
        // Simple JSON array [{name, aliases?, lat, lon}, ...]
        for (final e in data) {
          try {
            villages.add(_Village.fromJson((e as Map).cast<String, dynamic>()));
          } catch (_) {}
        }
      } else if (data is Map<String, dynamic>) {
        // GeoJSON FeatureCollection or similar
        final features = (data['features'] as List?) ?? const [];
        for (final f in features) {
          try {
            final m = (f as Map).cast<String, dynamic>();
            final props = (m['properties'] ?? {}) as Map<String, dynamic>;
            final geom = m['geometry'] as Map<String, dynamic>?;
            double? lat;
            double? lon;
            // Prefer geometry when present
            if (geom != null && geom['type'] == 'Point') {
              final coords = (geom['coordinates'] as List?) ?? const [];
              if (coords.length >= 2) {
                lon = (coords[0] as num).toDouble();
                lat = (coords[1] as num).toDouble();
              }
            }
            // Fallback: parse DMS from Excel-like properties (Field2: lat, Field3: lon)
            if ((lat == null || lon == null) && props.isNotEmpty) {
              final rawLat = props['Field2']?.toString() ?? '';
              final rawLon = props['Field3']?.toString() ?? '';
              if (rawLat.isNotEmpty && rawLon.isNotEmpty) {
                final latParsed = _parseDmsLoose(rawLat, isLat: true);
                final lonParsed = _parseDmsLoose(rawLon, isLat: false);
                if (latParsed != null && lonParsed != null) {
                  lat = latParsed;
                  lon = lonParsed;
                }
              }
            }

            final name =
                (props['name_gr'] ??
                        props['name_greek'] ??
                        props['name'] ??
                        props['Field1'] ??
                        '')
                    .toString();
            if (name.isEmpty || lat == null || lon == null) continue;
            final aliases = <String>[];
            for (final k in ['name_en', 'latin', 'alias', 'aliases']) {
              final v = props[k];
              if (v is String && v.isNotEmpty) aliases.add(v);
              if (v is List) {
                aliases.addAll(v.map((e) => e.toString()));
              }
            }
            villages.add(
              _Village(name: name, aliases: aliases, lat: lat, lon: lon),
            );
          } catch (_) {}
        }
      }
      if (!mounted) {
        return;
      }
      setState(() => _villages = villages);
    } catch (_) {
      // ignore
    }
  }

  // Some of the village data uses dotted D.M.S format (e.g., 33.19.27).
  // This helper normalizes that case before reusing the robust _parseDms().
  double? _parseDmsLoose(String input, {required bool isLat}) {
    String s = input.trim();
    final dottedDms = RegExp(r'^\s*\d{1,3}\.\d{1,2}\.\d{1,2}\s*\$');
    // If it looks like D.M.S with dots, replace dots with spaces
    if (dottedDms.hasMatch(s)) {
      s = s.replaceAll('.', ' ');
    }
    return _parseDms(s, isLat: isLat);
  }

  String _normalize(String s) {
    // Lowercase, trim, remove diacritics for Greek/Latin
    s = s.toLowerCase().trim();
    const repl = {
      'ά': 'α',
      'έ': 'ε',
      'ή': 'η',
      'ί': 'ι',
      'ό': 'ο',
      'ύ': 'υ',
      'ώ': 'ω',
      'ϊ': 'ι',
      'ΐ': 'ι',
      'ΰ': 'υ',
      'ϋ': 'υ',
      'Ά': 'α',
      'Έ': 'ε',
      'Ή': 'η',
      'Ί': 'ι',
      'Ό': 'ο',
      'Ύ': 'υ',
      'Ώ': 'ω',
    };
    final sb = StringBuffer();
    for (final ch in s.split('')) {
      sb.write(repl[ch] ?? ch);
    }
    return sb.toString();
  }

  String _transliterateGreekToLatin(String input) {
    // Basic greek->latin mapping sufficient for search matching
    const map = {
      'Α': 'A',
      'Β': 'V',
      'Γ': 'G',
      'Δ': 'D',
      'Ε': 'E',
      'Ζ': 'Z',
      'Η': 'I',
      'Θ': 'Th',
      'Ι': 'I',
      'Κ': 'K',
      'Λ': 'L',
      'Μ': 'M',
      'Ν': 'N',
      'Ξ': 'X',
      'Ο': 'O',
      'Π': 'P',
      'Ρ': 'R',
      'Σ': 'S',
      'Τ': 'T',
      'Υ': 'Y',
      'Φ': 'F',
      'Χ': 'Ch',
      'Ψ': 'Ps',
      'Ω': 'O',
      'α': 'a',
      'β': 'v',
      'γ': 'g',
      'δ': 'd',
      'ε': 'e',
      'ζ': 'z',
      'η': 'i',
      'θ': 'th',
      'ι': 'i',
      'κ': 'k',
      'λ': 'l',
      'μ': 'm',
      'ν': 'n',
      'ξ': 'x',
      'ο': 'o',
      'π': 'p',
      'ρ': 'r',
      'σ': 's',
      'ς': 's',
      'τ': 't',
      'υ': 'y',
      'φ': 'f',
      'χ': 'ch',
      'ψ': 'ps',
      'ω': 'o',
      'ά': 'a',
      'έ': 'e',
      'ή': 'i',
      'ί': 'i',
      'ό': 'o',
      'ύ': 'y',
      'ώ': 'o',
      'ϊ': 'i',
      'ΐ': 'i',
      'ΰ': 'y',
      'ϋ': 'y',
    };
    final b = StringBuffer();
    for (final ch in input.split('')) {
      b.write(map[ch] ?? ch);
    }
    return b.toString();
  }

  List<_Village> _searchVillages(String query) {
    if (query.trim().isEmpty) return const [];
    final q = _normalize(query);
    final qLatin = _normalize(_transliterateGreekToLatin(query));
    final results = <_Village>[];
    for (final v in _villages) {
      final nameN = _normalize(v.name);
      final nameLatin = _normalize(_transliterateGreekToLatin(v.name));
      final aliasMatch = v.aliases.any((a) {
        final an = _normalize(a);
        return an.contains(q) || an.contains(qLatin);
      });
      if (nameN.contains(q) || nameLatin.contains(qLatin) || aliasMatch) {
        results.add(v);
      }
    }
    return results;
  }

  Future<void> _openVillageSearch() async {
    // Expanded search: Villages + Saved Waypoints + Reporting Points
    final villageResults = <_Village>[];
    final waypointResults = <_Waypoint>[];
    final rppResults = <_ReportingPoint>[];
    final controller = TextEditingController();
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Search',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Enter name (Greek or Latin)',
                    labelStyle: TextStyle(color: Colors.white70),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  style: const TextStyle(color: Colors.white),
                  onChanged: (val) {
                    setModalState(() {
                      // Villages
                      villageResults
                        ..clear()
                        ..addAll(_searchVillages(val));
                      // Waypoints (simple case-insensitive contains)
                      final q = val.trim().toLowerCase();
                      waypointResults
                        ..clear()
                        ..addAll(
                          _waypoints.where(
                            (w) => w.name.toLowerCase().contains(q),
                          ),
                        );
                      // Reporting points
                      rppResults
                        ..clear()
                        ..addAll(
                          _reportingPoints.where(
                            (rp) => rp.name.toLowerCase().contains(q),
                          ),
                        );
                    });
                  },
                ),
                const SizedBox(height: 12),
                if (controller.text.isNotEmpty)
                  Text(
                    '${villageResults.length + waypointResults.length + rppResults.length} result'
                    '${(villageResults.length + waypointResults.length + rppResults.length) == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                const SizedBox(height: 8),
                Flexible(
                  child: () {
                    final total =
                        villageResults.length +
                        waypointResults.length +
                        rppResults.length;
                    if (total == 0) {
                      return const Text(
                        'No matches',
                        style: TextStyle(color: Colors.white54),
                      );
                    }
                    final children = <Widget>[];
                    if (villageResults.isNotEmpty) {
                      children.add(
                        const Padding(
                          padding: EdgeInsets.only(top: 4, bottom: 2),
                          child: Text(
                            'Villages',
                            style: TextStyle(
                              color: Colors.orangeAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                      children.addAll(
                        villageResults.map(
                          (v) => ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.location_city,
                              color: Colors.white70,
                            ),
                            title: Text(
                              v.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              '${_toDms(v.lat, isLat: true)}, ${_toDms(v.lon, isLat: false)}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _showVillageActions(v);
                            },
                          ),
                        ),
                      );
                    }
                    if (waypointResults.isNotEmpty) {
                      children.add(
                        const Padding(
                          padding: EdgeInsets.only(top: 8, bottom: 2),
                          child: Text(
                            'Saved Waypoints',
                            style: TextStyle(
                              color: Colors.orangeAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                      children.addAll(
                        waypointResults.map(
                          (w) => ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.place,
                              color: Colors.lightBlueAccent,
                            ),
                            title: Text(
                              w.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              '${_toDms(w.lat, isLat: true)}, ${_toDms(w.lon, isLat: false)}  •  ${w.type}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _showWaypointActions(w);
                            },
                          ),
                        ),
                      );
                    }
                    if (rppResults.isNotEmpty) {
                      children.add(
                        const Padding(
                          padding: EdgeInsets.only(top: 8, bottom: 2),
                          child: Text(
                            'Reporting Points',
                            style: TextStyle(
                              color: Colors.orangeAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                      children.addAll(
                        rppResults.map(
                          (rp) => ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.change_history,
                              color: Colors.black,
                            ),
                            title: Text(
                              rp.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              '${_toDms(rp.lat, isLat: true)}, ${_toDms(rp.lon, isLat: false)}  •  ${rp.country}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _showSimplePointActions(rp.name, rp.lat, rp.lon);
                            },
                          ),
                        ),
                      );
                    }
                    return ListView(shrinkWrap: true, children: children);
                  }(),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showVillageActions(_Village v) {
    // Center map immediately
    _mapController.move(LatLng(v.lat, v.lon), 13.0);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              v.name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '${_toDms(v.lat, isLat: true)}, ${_toDms(v.lon, isLat: false)}',
              style: const TextStyle(color: Colors.white70),
            ),
            if (v.aliases.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Also known as: ${v.aliases.join(', ')}',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _directTo(LatLng(v.lat, v.lon));
                  },
                  icon: const Icon(Icons.navigation),
                  label: const Text('Direct To'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _addToRoute(LatLng(v.lat, v.lon));
                  },
                  icon: const Icon(Icons.route),
                  label: const Text('Add to Route'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSimplePointActions(String name, double lat, double lon) {
    _mapController.move(LatLng(lat, lon), 13.0);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '${_toDms(lat, isLat: true)}, ${_toDms(lon, isLat: false)}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _directTo(LatLng(lat, lon));
                  },
                  icon: const Icon(Icons.navigation),
                  label: const Text('Direct To'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _addToRoute(LatLng(lat, lon));
                  },
                  icon: const Icon(Icons.route),
                  label: const Text('Add to Route'),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _mapController.move(LatLng(lat, lon), 15.0);
                  },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('Center'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Waypoint specific action sheet: add to route / direct-to and show altitude if stored.
  void _showWaypointActions(_Waypoint wp) {
    final lat = wp.lat;
    final lon = wp.lon;
    final altFt = wp.altMeters != null
        ? (wp.altMeters! * 3.28084).round()
        : null;
    final LatLng pos = LatLng(lat, lon);
    final nearestAirports = _nearestAirportsInFIR(pos, 2);
    final firCode = nearestAirports.isNotEmpty
        ? ((nearestAirports.first.properties?['countryCode'] as String?) ?? '')
        : '';
    _mapController.move(LatLng(lat, lon), 13.0);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    wp.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (altFt != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orangeAccent, width: 1),
                    ),
                    child: Text(
                      '$altFt ft',
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${_toDms(lat, isLat: true)}, ${_toDms(lon, isLat: false)}',
              style: const TextStyle(color: Colors.white70),
            ),
            if (nearestAirports.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Nearest airports${firCode.isNotEmpty ? ' (FIR: $firCode)' : ''}:',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 4),
              for (final a in nearestAirports)
                Text(
                  _formatAirportRadialDistance(a, pos),
                  style: const TextStyle(color: Colors.white70),
                ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _directTo(LatLng(lat, lon));
                  },
                  icon: const Icon(Icons.navigation),
                  label: const Text('Direct To'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _addToRoute(LatLng(lat, lon));
                  },
                  icon: const Icon(Icons.route),
                  label: const Text('Add to Route'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _mapController.move(LatLng(lat, lon), 15.0);
                  },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('Center'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _editWaypoint(_waypoints.indexOf(wp));
                  },
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    () async {
                      final ok = await _confirmDeleteDialog(
                        'Delete waypoint',
                        'Delete waypoint "${wp.name}"?',
                      );
                      if (!ok) return;
                      setState(() {
                        _waypoints.remove(wp);
                      });
                      await _persistWaypoints();
                      if (mounted) {
                        _openWaypointsFolder();
                      }
                    }();
                  },
                  icon: const Icon(
                    Icons.delete_forever,
                    color: Colors.redAccent,
                  ),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Helper: split a path when jumps exceed a threshold (meters)
  List<List<LatLng>> _splitByLongJumps(
    List<LatLng> pts,
    double maxDistanceMeters,
  ) {
    if (pts.length < 2) return const [];
    final result = <List<LatLng>>[];
    var current = <LatLng>[pts.first];
    final dist = const Distance();
    for (int i = 1; i < pts.length; i++) {
      final prev = current.last;
      final curr = pts[i];
      final d = dist.as(LengthUnit.Meter, prev, curr);
      if (d < maxDistanceMeters) {
        current.add(curr);
      } else {
        if (current.length > 1) result.add(current);
        current = [curr];
      }
    }
    if (current.length > 1) result.add(current);
    return result;
  }

  // Helper: greedy nearest-neighbor ordering to connect isolated points
  List<LatLng> _greedyOrder(List<LatLng> pts) {
    if (pts.isEmpty) return const [];
    final used = <int>{0};
    final ordered = <LatLng>[pts[0]];
    final dist = const Distance();
    while (used.length < pts.length) {
      final last = ordered.last;
      int? nextIdx;
      double? minD;
      for (int i = 0; i < pts.length; i++) {
        if (used.contains(i)) continue;
        final d = dist.as(LengthUnit.Meter, last, pts[i]);
        if (minD == null || d < minD) {
          minD = d;
          nextIdx = i;
        }
      }
      if (nextIdx == null) break;
      used.add(nextIdx);
      ordered.add(pts[nextIdx]);
    }
    return ordered;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only load once
    if (_powerLinePolys.isEmpty) {
      _loadPowerLines();
    }
  }

  Future<void> _loadPowerLines() async {
    try {
      // Discover all power line KMLs declared in the Flutter asset manifest
      final manifestStr = await rootBundle.loadString('AssetManifest.json');
      final manifest = jsonDecode(manifestStr) as Map<String, dynamic>;
      final kmlFiles =
          manifest.keys
              .where(
                (k) =>
                    k.startsWith('assets/Power_Lines/') &&
                    k.toLowerCase().endsWith('.kml'),
              )
              .toList()
            ..sort();

      // Fallback to the original single file if scanning returns nothing
      if (kmlFiles.isEmpty) {
        kmlFiles.add('assets/Power_Lines/Power_Lines.kml');
      }

      final List<List<LatLng>> lines = [];
      final List<LatLng> pointPool = [];

      for (final file in kmlFiles) {
        try {
          final kmlString = await rootBundle.loadString(file);
          final doc = xml.XmlDocument.parse(kmlString);
          for (final c in doc.findAllElements('coordinates')) {
            final parent = c.parent;
            final parentName = parent is xml.XmlElement
                ? parent.name.local
                : null;
            final text = c.innerText.trim();
            if (text.isEmpty) continue;
            final parts = text.split(RegExp(r'\s+'));
            final pts = <LatLng>[];
            for (final p in parts) {
              final xyz = p.split(',');
              if (xyz.length >= 2) {
                final lon = double.tryParse(xyz[0]);
                final lat = double.tryParse(xyz[1]);
                if (lat != null && lon != null) {
                  pts.add(LatLng(lat, lon));
                }
              }
            }
            if (pts.isEmpty) continue;

            if ((parentName == 'LineString' || parentName == 'LinearRing') &&
                pts.length > 1) {
              // Respect provided line geometry
              lines.addAll(
                _splitByLongJumps(pts, 2414),
              ); // ~1.5 miles in meters
            } else if (parentName == 'Point' && pts.length == 1) {
              pointPool.add(pts.first);
            } else {
              // Unknown container; conservatively accumulate as points
              if (pts.length == 1) {
                pointPool.add(pts.first);
              } else {
                lines.addAll(_splitByLongJumps(pts, 2414));
              }
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('Power lines: failed to parse $file: $e');
        }
      }

      // If only points collected overall, connect them into plausible segments
      if (lines.isEmpty && pointPool.length > 1) {
        final ordered = _greedyOrder(pointPool);
        lines.addAll(_splitByLongJumps(ordered, 2414));
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _powerLinePolys = lines;
      });

      if (kDebugMode) {
        debugPrint(
          'Power lines loaded: files=${kmlFiles.length} lines=${lines.length} pts=${pointPool.length}',
        );
      }
    } catch (e) {
      // ignore errors but clear the overlay
      if (!mounted) {
        return;
      }
      setState(() {
        _powerLinePolys = [];
      });
      if (kDebugMode) debugPrint('Power lines load failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadNvgSettings(); // restore NVG mode + intensity
    // Early permission attempt so dialog appears without needing START press.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final initial = await Geolocator.checkPermission();
      setState(() => _locationPermission = initial);
      if (initial == LocationPermission.denied) {
        final p = await Geolocator.requestPermission();
        setState(() => _locationPermission = p);
        if (p == LocationPermission.always ||
            p == LocationPermission.whileInUse) {
          _initLocation();
        }
      } else if (initial == LocationPermission.always ||
          initial == LocationPermission.whileInUse) {
        _initLocation();
      } else if (initial == LocationPermission.deniedForever) {
        setState(() => _locationError = 'Permission denied forever');
      }
    });
    _loadCallsign();
    _loadFlightLog();
    _loadAirports();
    _loadAirspace();
    _loadWaypoints();
    _loadSavedAreas();
    _loadImportedLayers();
    _loadSavedRoutes();
    _loadRoute();
    _loadVillages();
    _loadReportingPointsCyprus();
    _loadReportingPointsOtherCountries();
    _loadNavaids();
    _loadObstacles();
    _loadPowerLines();
    // Listen for map taps to reset airspace selection
    // (Handled in MapOptions.onTap below)
    // Initialize flight ticker lazily when user starts flight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recoverActiveFlightIfAny();
    });
    _initTts();
    _loadAltSettings();
    _loadWarnSettings();
    _loadInfoBarSettings();
    _loadObstacleVoiceSettings();
    // Legacy adjustable power line alert settings removed (live callouts now fixed); no load required.
  }

  @override
  void dispose() {
    _flightTicker?.cancel();
    _livePublishTimer?.cancel();
    _baroSub?.cancel();
    _locationSub?.cancel();
    _locationAutoStopTimer?.cancel();
    _cancelOverlayAutoCloseTimer();
    _cancelAutoCenterResumeTimer();
    // Stop any ongoing speech
    try {
      _tts.stop();
    } catch (_) {}
    super.dispose();
  }

  void _startFlightTimer() {
    if (_flightStart != null && _flightEnd == null) {
      // Already running
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Flight timer already running')),
      );
      return;
    }
    setState(() {
      _flightStart = DateTime.now();
      _flightEnd = null;
    });
    _flightTicker?.cancel();
    _flightTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      if (_flightStart != null && _flightEnd == null) {
        setState(() {}); // trigger info bar refresh
      }
    });
    _startNewFlightLogging();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Flight timer started')));
    // Nearest T/O context
    if (_currentPosition != null) {
      final nearest = _nearestPlace(_currentPosition!, 1.0);
      final msg = nearest != null
          ? 'T/O near ${nearest['type']} ${nearest['name']} (${(nearest['distanceNm'] as double).toStringAsFixed(2)} NM)'
          : 'T/O at ${_toDms(_currentPosition!.latitude, isLat: true)}, ${_toDms(_currentPosition!.longitude, isLat: false)}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _stopFlightTimer() {
    if (_flightStart == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Flight timer not started')));
      return;
    }
    if (_flightEnd != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Flight already stopped')));
      return;
    }
    setState(() {
      _flightEnd = DateTime.now();
      _trackEndPos = _currentPosition;
    });
    // Auto-stop live share when landing if active
    if (_liveShareActive) {
      _stopLiveShare();
    }
    _flightTicker?.cancel();
    _finalizeAndSaveFlight();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Flight time: ${_formatFlightTime()}')),
    );
    // Nearest landing context
    if (_trackEndPos != null) {
      final nearest = _nearestPlace(_trackEndPos!, 1.0);
      final msg = nearest != null
          ? 'LNDG near ${nearest['type']} ${nearest['name']} (${(nearest['distanceNm'] as double).toStringAsFixed(2)} NM)'
          : 'LNDG at ${_toDms(_trackEndPos!.latitude, isLat: true)}, ${_toDms(_trackEndPos!.longitude, isLat: false)}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _initLocation() async {
    setState(() {
      _locationDebugStatus = 'Checking permissions...';
      _locationError = null;
    });

    // Use unified readiness check
    final ready = await _ensureLocationReady(openSettingsIfNeeded: true);
    if (!ready) {
      setState(() {
        _locationDebugStatus = 'Permission denied or services off';
        _locationError = 'Enable location in Settings';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enable location services & permission'),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    setState(() => _locationDebugStatus = 'Starting position stream...');

    // Cancel any existing subscription before starting a new one
    _locationSub?.cancel();
    _locationSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
          ),
        ).listen(
          (Position pos) {
            final next = LatLng(pos.latitude, pos.longitude);
            // Compute heading: prefer sensor heading if finite; else derive from motion
            double? newHeading;
            if (pos.heading.isFinite && pos.heading >= 0) {
              newHeading = pos.heading;
            } else if (_lastPosForHeading != null) {
              final dLat = next.latitude - _lastPosForHeading!.latitude;
              final dLon = next.longitude - _lastPosForHeading!.longitude;
              if (dLat.abs() > 1e-9 || dLon.abs() > 1e-9) {
                final angRad = math.atan2(dLon, dLat); // note: lat ~ Y, lon ~ X
                final deg = (angRad * 180.0 / math.pi);
                newHeading = (90.0 - deg) % 360.0; // convert to 0=N,90=E
              }
            }

            setState(() {
              _currentPosition = next;
              _lastPositionUpdate = DateTime.now();
              _positionUpdateCount++;
              _locationDebugStatus = 'Active ($_positionUpdateCount updates)';
              _locationError = null;
              _currentAltitudeM = pos.altitude.isFinite ? pos.altitude : null;
              if (newHeading != null && newHeading.isFinite) {
                _currentHeadingDeg = (newHeading % 360 + 360) % 360;
              }
              _lastPosForHeading = next;
              if (_flightStart != null && _flightEnd == null) {
                _appendTrackPoint(next);
              }
              _updateGpsSpeed(next, DateTime.now());
              _checkVoiceAlerts();
              if (_liveShareActive) {
                _publishLiveUpdate(forceFlush: false);
              }
            });

            if (_useAglForWarns ||
                _infoAglReplaceEte ||
                _infoShowAglNextToAlt) {
              _ensureGroundElevation(next);
            }

            // Apply auto-center if enabled and not temporarily suppressed
            if (_autoCenter &&
                !_autoCenterSuppressed &&
                _currentPosition != null) {
              _mapController.move(_currentPosition!, _mapZoom);
            }

            // Apply heading-up rotation if enabled
            if (_headingUp) {
              _mapController.rotate(_currentHeadingDeg);
            }
          },
          onError: (error) {
            setState(() {
              _locationDebugStatus = 'Stream error';
              _locationError = error.toString();
            });
            if (kDebugMode) debugPrint('Location stream error: $error');
            // Retry after 3 seconds
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) _initLocation();
            });
          },
          onDone: () {
            setState(() {
              _locationDebugStatus = 'Stream closed';
            });
            if (kDebugMode) debugPrint('Location stream closed unexpectedly');
          },
        );

    // Schedule auto-stop after maximum allowed duration (background safety)
    _locationAutoStopTimer?.cancel();
    _locationAutoStopTimer = Timer(_locationMaxDuration, () {
      _stopLocationTracking(auto: true);
    });
  }

  void _stopLocationTracking({bool auto = false}) {
    _locationSub?.cancel();
    _locationSub = null;
    _locationAutoStopTimer?.cancel();
    _locationAutoStopTimer = null;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            auto
                ? 'Location tracking auto-stopped after 4 hours'
                : 'Location tracking stopped',
          ),
        ),
      );
    }
  }

  // Ensures services + permission; opens settings if disabled/denied.
  Future<bool> _ensureLocationReady({bool openSettingsIfNeeded = true}) async {
    // ALWAYS request permission first (registers app in Android Settings → Location)
    var perm = await Geolocator.checkPermission();
    setState(() => _locationPermission = perm);
    if (perm == LocationPermission.denied) {
      final requested = await Geolocator.requestPermission();
      perm = requested;
      setState(() => _locationPermission = perm);
      if (perm == LocationPermission.denied) return false;
    }
    if (perm == LocationPermission.deniedForever) {
      if (openSettingsIfNeeded) {
        await Geolocator.openAppSettings();
      }
      return false;
    }

    // Then check services (user may have granted permission but GPS is off)
    final servicesEnabled = await Geolocator.isLocationServiceEnabled();
    if (!servicesEnabled) {
      if (openSettingsIfNeeded) {
        await Geolocator.openLocationSettings();
        return false;
      }
      return false;
    }

    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  void _initTts() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      _ttsReady = true;
    } catch (e) {
      if (kDebugMode) debugPrint('TTS init failed: $e');
    }
  }

  // Legacy _loadPowerLineAlertSettings / _savePowerLineAlertSettings removed.

  Future<void> _speak(String text) async {
    if (!_ttsReady || !_ttsEnabled) return;
    try {
      await _tts.stop(); // clear previous queued speech for immediacy
      await _tts.speak(text);
    } catch (_) {}
  }

  void _updateGpsSpeed(LatLng current, DateTime now) {
    if (_lastSpeedPos != null && _lastSpeedTime != null) {
      final dt = now.difference(_lastSpeedTime!).inMilliseconds / 1000.0;
      if (dt > 0.5) {
        // minimal interval
        final dMeters = _distanceMeters(
          _lastSpeedPos!.latitude,
          _lastSpeedPos!.longitude,
          current.latitude,
          current.longitude,
        );
        // Ignore tiny moves < 3m to reduce jitter
        if (dMeters >= 3) {
          final mps = dMeters / dt;
          _currentGpsSpeedKts = mps * 1.94384; // meters/sec to knots
        }
      }
    }
    _lastSpeedPos = current;
    _lastSpeedTime = now;
  }

  void _checkVoiceAlerts() {
    // Altitude warnings
    double? altFt;
    final metersSrc = _altSource == _AltSource.gps
        ? _currentAltitudeM
        : _baroAltitudeM;
    if (_useAglForWarns && _currentPosition != null) {
      // Opportunistically refresh ground elevation
      _ensureGroundElevation(_currentPosition!);
    }
    double? metersForWarn = metersSrc;
    if (_useAglForWarns && metersSrc != null && _groundElevM != null) {
      metersForWarn = (metersSrc - _groundElevM!).clamp(-1000.0, 100000.0);
    }
    if (metersForWarn != null) altFt = metersForWarn * 3.28084;
    if (altFt != null && _altWarnsEnabled) {
      // Warning 1 (e.g., 150 ft)
      if (altFt < _altWarn1Ft && !_alt1Warned) {
        _alt1Warned = true;
        final msg = '$_altWarn1Ft feet';
        _speak(msg);
        Future.delayed(const Duration(milliseconds: 900), () => _speak(msg));
      } else if (altFt > (_altWarn1Ft + 10)) {
        _alt1Warned = false;
      }
      // Warning 2 (e.g., 50 ft)
      if (altFt < _altWarn2Ft && !_alt2Warned) {
        _alt2Warned = true;
        final msg = '$_altWarn2Ft feet';
        _speak(msg);
        Future.delayed(const Duration(milliseconds: 900), () => _speak(msg));
      } else if (altFt > (_altWarn2Ft + 10)) {
        _alt2Warned = false;
      }
    }
    // Speed warning
    final spd = _currentGpsSpeedKts;
    if (spd != null && _speedWarnEnabled) {
      if (spd < _speedWarnKts && !_speedWarnedBelow) {
        _speedWarnedBelow = true;
        final msg = '${_speedWarnKts.toStringAsFixed(0)} knots';
        _speak(msg);
        Future.delayed(const Duration(milliseconds: 900), () => _speak(msg));
      } else if (spd > _speedResetKts) {
        _speedWarnedBelow = false;
      }
    }
    // Power lines live callouts (every 0.2 nm from 1.0 -> 0.0 while approaching, overhead once)
    if (_powerLineVoiceAlert &&
        _showCyPowerLines &&
        _currentPosition != null &&
        _gatherPowerLineSegments().isNotEmpty) {
      final prox = _nearestPowerLineProximity(_currentPosition!);
      if (prox != null) {
        final meters = (prox['meters'] as num).toDouble();
        final cp = prox['point'] as LatLng;
        final nm = meters / 1852.0;

        // Determine if ahead in cone
        bool ahead = true;
        if (_currentHeadingDeg.isFinite) {
          final brg = _bearingDegrees(_currentPosition!, cp);
          double diff = (brg - _currentHeadingDeg).abs();
          if (diff > 180) diff = 360 - diff;
          ahead = diff <= _powerLineAheadConeDeg;
        }

        // Reset state if far again (> buffer)
        if (nm > _powerLineResetBufferNm) {
          _lastPowerLineCalloutBoundary = null;
          _lastPowerLineDistanceNm = null;
          _powerLineOverheadAnnounced = false;
        }

        if (ahead) {
          // Overhead (0.0) detection: within overhead threshold and not yet announced
          if (nm <= _powerLineOverheadNm && !_powerLineOverheadAnnounced) {
            _powerLineOverheadAnnounced = true;
            _speak('Power lines overhead');
          } else if (!_powerLineOverheadAnnounced &&
              nm <= _powerLineCalloutMaxNm &&
              nm > _powerLineOverheadNm) {
            // Downward boundary crossing logic
            final prev = _lastPowerLineDistanceNm;
            _lastPowerLineDistanceNm = nm;
            // Only speak when moving closer (prev == null or nm < prev)
            if (prev == null || nm < prev) {
              // Compute the boundary bucket we are now below
              // Boundaries: 1.0, 0.8, 0.6, 0.4, 0.2
              final steps = <double>[];
              for (
                double b = _powerLineCalloutMaxNm;
                b >= _powerLineCalloutStepNm;
                b -= _powerLineCalloutStepNm
              ) {
                steps.add(double.parse(b.toStringAsFixed(1))); // limit FP noise
              }
              // Find the highest boundary we just crossed below
              double? crossed;
              for (final b in steps) {
                if (nm <= b &&
                    (_lastPowerLineCalloutBoundary == null ||
                        b < _lastPowerLineCalloutBoundary!)) {
                  crossed = b;
                }
              }
              if (crossed != null && crossed != _lastPowerLineCalloutBoundary) {
                _lastPowerLineCalloutBoundary = crossed;
                final brg = _bearingDegrees(_currentPosition!, cp);
                if (_voiceRelativeBearing) {
                  final rel = _formatRelativeBearing(_currentHeadingDeg, brg);
                  _speak(
                    'Power lines $rel, ${crossed.toStringAsFixed(1)} nautical miles',
                  );
                } else {
                  final d3 = brg.isFinite
                      ? brg.round().toString().padLeft(3, '0')
                      : '--';
                  _speak(
                    'Power lines ${crossed.toStringAsFixed(1)} nautical miles, $d3 degrees',
                  );
                }
              }
            }
          }
        }
      }
    }

    // Obstacles voice alerts at two thresholds (requires heading cone and optional vertical band)
    if (_obstacleVoiceAlert &&
        _currentPosition != null &&
        _obstacles.isNotEmpty) {
      // Ensure AGL if available to evaluate "top band" proximity
      if (_groundElevM == null) {
        _ensureGroundElevation(_currentPosition!);
      }

      // Find nearest visible obstacle ahead in cone (respects per-country toggles; defaults to ON for unknown countries)
      _Obstacle? nearest;
      double bestMeters = double.infinity;
      for (final o in _obstacles) {
        if (!_isObstaclesVisibleForCountry(o.country)) continue;
        final dM = _distanceMeters(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          o.lat,
          o.lon,
        );
        // Quick prune beyond outer boundary + buffer
        final outerNm = _obstacleWarn1Nm;
        if (dM > (outerNm + 0.3) * 1852.0) continue;
        // Heading cone check
        if (_currentHeadingDeg.isFinite) {
          final brg = _bearingDegrees(_currentPosition!, LatLng(o.lat, o.lon));
          double diff = (brg - _currentHeadingDeg).abs();
          if (diff > 180) diff = 360 - diff;
          if (diff > _obstacleConeDeg) continue;
        }
        if (dM < bestMeters) {
          bestMeters = dM;
          nearest = o;
        }
      }

      if (nearest != null) {
        final nm = bestMeters / 1852.0;
        // Identity key (stable-ish across small motion)
        final key =
            '${nearest.lat.toStringAsFixed(4)},${nearest.lon.toStringAsFixed(4)}';

        // Reset when leaving area, target changes, or moving away
        final resetDist = math.max(_obstacleWarn1Nm, _obstacleWarn2Nm) + 0.2;
        final prevNm = _lastObstacleDistanceNm;
        final changedTarget =
            (_lastObstacleKey != null && _lastObstacleKey != key);
        if (nm > resetDist || changedTarget) {
          _lastObstacleAnnounced = null;
          _lastObstacleDistanceNm = null;
          _lastObstacleKey = key;
        }

        // Vertical band check (optional): within +/- band from obstacle top
        bool verticalOk = true;
        if (nearest.heightFeet != null &&
            _currentAltitudeM != null &&
            _groundElevM != null) {
          final aglFt = ((_currentAltitudeM! - _groundElevM!) * 3.28084).clamp(
            -10000.0,
            100000.0,
          );
          final diffFt = (aglFt - nearest.heightFeet!).abs();
          verticalOk = diffFt <= _obstacleTopBandFt.toDouble();
        }

        if (verticalOk) {
          // Only speak when approaching and crossing boundaries
          final approaching = prevNm == null || nm < prevNm;
          if (approaching) {
            // First boundary
            final b1 = math.max(_obstacleWarn1Nm, _obstacleWarn2Nm);
            final b2 = math.min(_obstacleWarn1Nm, _obstacleWarn2Nm);
            if (nm <= b1 &&
                (_lastObstacleAnnounced == null ||
                    _lastObstacleAnnounced! > b1)) {
              _lastObstacleAnnounced = b1;
              _lastObstacleKey = key;
              final k = (nearest.kind.isNotEmpty ? nearest.kind : 'Obstacle');
              final brg = _bearingDegrees(
                _currentPosition!,
                LatLng(nearest.lat, nearest.lon),
              );
              if (_voiceRelativeBearing) {
                final rel = _formatRelativeBearing(_currentHeadingDeg, brg);
                _speak('$k $rel, ${b1.toStringAsFixed(1)} nautical miles');
              } else {
                final d3 = brg.isFinite
                    ? brg.round().toString().padLeft(3, '0')
                    : '--';
                _speak(
                  '$k ${b1.toStringAsFixed(1)} nautical miles, $d3 degrees',
                );
              }
            }
            // Second boundary
            if (nm <= b2 &&
                (_lastObstacleAnnounced == null ||
                    _lastObstacleAnnounced! > b2)) {
              _lastObstacleAnnounced = b2;
              _lastObstacleKey = key;
              final k = (nearest.kind.isNotEmpty ? nearest.kind : 'Obstacle');
              final brg = _bearingDegrees(
                _currentPosition!,
                LatLng(nearest.lat, nearest.lon),
              );
              if (_voiceRelativeBearing) {
                final rel = _formatRelativeBearing(_currentHeadingDeg, brg);
                _speak('$k $rel, ${b2.toStringAsFixed(1)} nautical miles');
              } else {
                final d3 = brg.isFinite
                    ? brg.round().toString().padLeft(3, '0')
                    : '--';
                _speak(
                  '$k ${b2.toStringAsFixed(1)} nautical miles, $d3 degrees',
                );
              }
            }
          }
          _lastObstacleDistanceNm = nm;
        }
      }
    }
  }

  // ===== Track & Logbook Helpers =====
  void _appendTrackPoint(LatLng p) {
    if (_currentTrack.isEmpty) {
      _currentTrack.add(p);
      _persistActiveFlight();
      return;
    }
    final last = _currentTrack.last;
    final dMeters = _distanceMeters(
      last.latitude,
      last.longitude,
      p.latitude,
      p.longitude,
    );
    if (dMeters >= 30) {
      _currentTrack.add(p);
      _persistActiveFlight();
    }
  }

  double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  double _trackDistanceNm(List<LatLng> pts) {
    if (pts.length < 2) return 0.0;
    double meters = 0.0;
    for (int i = 0; i < pts.length - 1; i++) {
      meters += _distanceMeters(
        pts[i].latitude,
        pts[i].longitude,
        pts[i + 1].latitude,
        pts[i + 1].longitude,
      );
    }
    return meters / 1852.0;
  }

  Future<File> _logbookFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/flight_log.json');
  }

  // ===== Active flight persistence (recovery after app restart) =====
  Future<File> _activeFlightFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/flight_active.json');
  }

  Future<void> _deleteActiveFlightFile() async {
    try {
      final f = await _activeFlightFile();
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> _persistActiveFlight() async {
    // Only persist if a flight is running
    if (_flightStart == null || _flightEnd != null) return;
    try {
      final f = await _activeFlightFile();
      final data = {
        'startTime': _flightStart!.toIso8601String(),
        'trackStartTime': (_trackStartTime ?? _flightStart)!.toIso8601String(),
        'trackStartLat': _trackStartPos?.latitude ?? _currentPosition?.latitude,
        'trackStartLon':
            _trackStartPos?.longitude ?? _currentPosition?.longitude,
        'track': _currentTrack
            .map((p) => [p.latitude, p.longitude])
            .toList(growable: false),
      };
      await f.writeAsString(jsonEncode(data));
    } catch (e) {
      if (kDebugMode) debugPrint('Persist active flight failed: $e');
    }
  }

  Future<void> _recoverActiveFlightIfAny() async {
    if (_recoveredActiveFlight) return; // already handled once
    try {
      final f = await _activeFlightFile();
      if (!await f.exists()) return;
      final txt = await f.readAsString();
      final m = jsonDecode(txt);
      if (m is! Map<String, dynamic>) return;
      final startStr = m['startTime'] as String?;
      if (startStr == null || startStr.isEmpty) return;
      final trackList = (m['track'] as List?) ?? const [];
      final pts = <LatLng>[];
      for (final e in trackList) {
        try {
          final lat = (e[0] as num).toDouble();
          final lon = (e[1] as num).toDouble();
          pts.add(LatLng(lat, lon));
        } catch (_) {}
      }
      final start = DateTime.tryParse(startStr);
      final trackStartStr = m['trackStartTime'] as String?;
      final tStart = trackStartStr != null
          ? DateTime.tryParse(trackStartStr) ?? start
          : start;
      final sLat = (m['trackStartLat'] as num?)?.toDouble();
      final sLon = (m['trackStartLon'] as num?)?.toDouble();
      if (!mounted) {
        return;
      }
      _recoveredActiveFlight = true;
      if (start == null) return;
      // Prompt user with options
      // Use a post-frame dialog to ensure context is ready
      // ignore: use_build_context_synchronously
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final startLocal = start.toLocal();
          return AlertDialog(
            title: const Text('Unfinished Flight Detected'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Started: $startLocal'),
                const SizedBox(height: 6),
                Text('Track points: ${pts.length}'),
                const SizedBox(height: 6),
                const Text('What would you like to do?'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  // Discard
                  final navigator = Navigator.of(ctx);
                  final messenger = ScaffoldMessenger.of(context);
                  await _deleteActiveFlightFile();
                  if (mounted) {
                    setState(() {
                      _flightStart = null;
                      _flightEnd = null;
                      _currentTrack = [];
                      _trackStartTime = null;
                      _trackStartPos = null;
                      _trackEndPos = null;
                    });
                    navigator.pop();
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Discarded unfinished flight'),
                      ),
                    );
                  }
                },
                child: const Text('Discard'),
              ),
              TextButton(
                onPressed: () async {
                  // Finalize now
                  final navigator = Navigator.of(ctx);
                  final messenger = ScaffoldMessenger.of(context);
                  setState(() {
                    _flightStart = start;
                    _flightEnd = DateTime.now();
                    _currentTrack = pts;
                    _trackStartTime = tStart ?? start;
                    _trackStartPos = (sLat != null && sLon != null)
                        ? LatLng(sLat, sLon)
                        : (pts.isNotEmpty ? pts.first : null);
                    _trackEndPos = pts.isNotEmpty ? pts.last : _currentPosition;
                  });
                  _finalizeAndSaveFlight();
                  await _deleteActiveFlightFile();
                  if (mounted) {
                    navigator.pop();
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Finalized previous flight'),
                      ),
                    );
                  }
                },
                child: const Text('Finalize now'),
              ),
              FilledButton(
                onPressed: () {
                  final navigator = Navigator.of(ctx);
                  final messenger = ScaffoldMessenger.of(context);
                  setState(() {
                    _flightStart = start;
                    _flightEnd = null;
                    _currentTrack = pts;
                    _trackStartTime = tStart ?? start;
                    _trackStartPos = (sLat != null && sLon != null)
                        ? LatLng(sLat, sLon)
                        : (pts.isNotEmpty ? pts.first : _currentPosition);
                  });
                  _flightTicker?.cancel();
                  _flightTicker = Timer.periodic(const Duration(seconds: 1), (
                    _,
                  ) {
                    if (!mounted) {
                      return;
                    }
                    if (_flightStart != null && _flightEnd == null) {
                      setState(() {});
                    }
                  });
                  navigator.pop();
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Resumed unfinished flight')),
                  );
                },
                child: const Text('Resume'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Recover active flight failed: $e');
    }
  }

  Future<void> _loadFlightLog() async {
    setState(() => _isLoadingLog = true);
    try {
      final file = await _logbookFile();
      if (await file.exists()) {
        final txt = await file.readAsString();
        final data = jsonDecode(txt);
        if (data is List) {
          _flightLog = data.cast<Map<String, dynamic>>();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Load flight log error: $e');
    } finally {
      if (mounted) setState(() => _isLoadingLog = false);
    }
  }

  Future<void> _loadCallsign() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('callsign');
      if (stored != null && stored.trim().isNotEmpty) {
        setState(() => _callsign = stored.trim());
      }
    } catch (_) {}
  }

  Future<void> _saveFlightLog() async {
    try {
      final file = await _logbookFile();
      await file.writeAsString(jsonEncode(_flightLog));
    } catch (e) {
      if (kDebugMode) debugPrint('Save flight log error: $e');
    }
  }

  void _startNewFlightLogging() {
    _currentTrack = [];
    _trackStartTime = DateTime.now();
    _trackStartPos = _currentPosition;
    _trackEndPos = null;
    // Persist initial active-flight state
    _persistActiveFlight();
  }

  void _finalizeAndSaveFlight() {
    if (_trackStartTime == null || _flightStart == null || _flightEnd == null) {
      return;
    }
    final route = _currentTrack.map((e) => [e.latitude, e.longitude]).toList();
    final distNm = _trackDistanceNm(_currentTrack);
    final startNearest = _trackStartPos != null
        ? _nearestPlace(_trackStartPos!, 1.0)
        : null;
    final endPosForNearest = _trackEndPos ?? _currentPosition;
    final endNearest = endPosForNearest != null
        ? _nearestPlace(endPosForNearest, 1.0)
        : null;
    final secs = _flightEnd!.difference(_flightStart!).inSeconds;
    final hours = secs / 3600.0;
    final durationDec = (hours * 10).round() / 10.0; // 0.1 = 6 minutes
    final entry = {
      'startTime': _flightStart!.toIso8601String(),
      'endTime': _flightEnd!.toIso8601String(),
      'durationSec': secs,
      'durationDec': durationDec,
      'startLat': _trackStartPos?.latitude,
      'startLon': _trackStartPos?.longitude,
      'startPlace': startNearest != null
          ? {
              'type': startNearest['type'],
              'name': startNearest['name'],
              'distanceNm': startNearest['distanceNm'],
            }
          : null,
      'endLat': _trackEndPos?.latitude ?? _currentPosition?.latitude,
      'endLon': _trackEndPos?.longitude ?? _currentPosition?.longitude,
      'endPlace': endNearest != null
          ? {
              'type': endNearest['type'],
              'name': endNearest['name'],
              'distanceNm': endNearest['distanceNm'],
            }
          : null,
      'distanceNm': distNm,
      'points': route,
    };
    _flightLog.add(entry);
    _saveFlightLog();
    // Clear active-flight persistence
    _deleteActiveFlightFile();
  }

  void _showFlightLog() async {
    await _loadFlightLog();
    if (!mounted) {
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (_) {
        final flights = _flightLog.reversed.toList();
        return SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 8),
              const Text('Flight Log', style: TextStyle(fontSize: 18)),
              const Divider(),
              if (_isLoadingLog)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                )
              else if (flights.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No flights recorded'),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: flights.length,
                    itemBuilder: (c, i) {
                      final f = flights[i];
                      final start =
                          DateTime.tryParse(f['startTime'] ?? '') ??
                          DateTime.now();
                      // Prefer stored decimal duration (hours, 1 dp where 0.1 = 6 minutes).
                      final dist = (f['distanceNm'] ?? 0.0).toStringAsFixed(1);
                      double durDecVal;
                      if (f.containsKey('durationDec')) {
                        durDecVal = (f['durationDec'] as num).toDouble();
                      } else {
                        final secs = (f['durationSec'] ?? 0) as int;
                        final hours = secs / 3600.0;
                        durDecVal = (hours * 10).round() / 10.0;
                      }
                      final durStr = durDecVal.toStringAsFixed(1);
                      final idxOriginal =
                          _flightLog.length - 1 - i; // map reversed index back
                      return ListTile(
                        leading: const Icon(
                          Icons.flight_takeoff,
                          color: Colors.orangeAccent,
                        ),
                        title: Text('${start.toLocal()}'),
                        subtitle: Text('Dur: $durStr h | Dist: $dist NM'),
                        onTap: () => _showFlightDetailsDialog(f),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.route,
                                color: Colors.lightGreenAccent,
                              ),
                              tooltip: 'Show route',
                              onPressed: () {
                                final pts =
                                    (f['points'] as List?)
                                        ?.map(
                                          (e) => LatLng(
                                            (e[0] as num).toDouble(),
                                            (e[1] as num).toDouble(),
                                          ),
                                        )
                                        .toList() ??
                                    [];
                                setState(() => _selectedLogRoute = pts);
                                Navigator.pop(context);
                              },
                            ),
                            PopupMenuButton<String>(
                              itemBuilder: (ctx) => const [
                                PopupMenuItem(
                                  value: 'landing_now',
                                  child: Text('Set LNDG to now'),
                                ),
                                PopupMenuItem(
                                  value: 'landing_custom',
                                  child: Text('Edit landing time…'),
                                ),
                                PopupMenuItem(
                                  value: 'export_kml',
                                  child: Text('Export to KML'),
                                ),
                                PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                              onSelected: (val) async {
                                final navigator = Navigator.of(context);
                                if (val == 'delete') {
                                  await _deleteFlightEntry(idxOriginal);
                                  navigator.pop();
                                  _showFlightLog();
                                } else if (val == 'export_kml') {
                                  await _exportFlightToKml(
                                    _flightLog[idxOriginal],
                                  );
                                } else if (val == 'landing_now') {
                                  _setLandingTimeForFlight(
                                    idxOriginal,
                                    DateTime.now(),
                                  );
                                  navigator.pop();
                                  _showFlightLog();
                                } else if (val == 'landing_custom') {
                                  final picked = await _pickDateTime(
                                    context,
                                    initial: DateTime.now(),
                                  );
                                  if (picked != null) {
                                    if (!mounted) {
                                      return;
                                    }
                                    _setLandingTimeForFlight(
                                      idxOriginal,
                                      picked,
                                    );
                                    navigator.pop();
                                    _showFlightLog();
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ===== Live Share Implementation =====
  String _generateLiveUuid() {
    final r = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<DocumentReference<Map<String, dynamic>>> _liveDoc() async {
    if (_liveSessionId == null) throw StateError('No live session');
    return FirebaseFirestore.instance
        .collection('liveSessions')
        .doc(_liveSessionId);
  }

  Future<void> _startLiveShare() async {
    if (_liveShareActive || _currentPosition == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Live share unavailable')));
      return;
    }
    setState(() {
      _liveSessionId = _generateLiveUuid();
      _liveShareToken = _generateLiveUuid().substring(0, 8);
      _liveShareActive = true;
      _pendingLivePoints.clear();
      _pendingLivePoints.add(_currentPosition!);
    });
    try {
      final doc = await _liveDoc();
      final now = DateTime.now();
      await doc.set({
        'active': true,
        'createdAt': now.toIso8601String(),
        'callsign': _callsign,
        'token': _liveShareToken,
        'polylineChunks': [],
        'last': {
          'lat': _currentPosition!.latitude,
          'lon': _currentPosition!.longitude,
          'altM': _currentAltitudeM,
          'heading': _currentHeadingDeg,
          'ts': now.toIso8601String(),
        },
      }, SetOptions(merge: true));
    } catch (e) {
      if (kDebugMode) debugPrint('Live share start failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start live share')),
        );
      }
      setState(() {
        _liveShareActive = false;
        _liveSessionId = null;
      });
      return;
    }
    _livePublishTimer?.cancel();
    _livePublishTimer = Timer.periodic(
      Duration(seconds: _livePublishIntervalSec),
      (_) => _publishLiveUpdate(forceFlush: false),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Live link copied')));
    }
    final url = '$kLiveViewerBase?session=$_liveSessionId&t=$_liveShareToken';
    Clipboard.setData(ClipboardData(text: url));
  }

  Future<void> _stopLiveShare() async {
    if (!_liveShareActive) return;
    await _publishLiveUpdate(forceFlush: true, ending: true);
    _livePublishTimer?.cancel();
    setState(() {
      _liveShareActive = false;
      _liveSessionId = null;
      _pendingLivePoints.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Live share stopped')));
    }
  }

  String _encodePolyline(List<LatLng> pts) {
    int enc(double v) => (v * 1e5).round();
    final sb = StringBuffer();
    int prevLat = 0, prevLon = 0;
    for (final p in pts) {
      int lat = enc(p.latitude);
      int lon = enc(p.longitude);
      int dLat = lat - prevLat;
      int dLon = lon - prevLon;
      prevLat = lat;
      prevLon = lon;
      void write(int v) {
        v = v < 0 ? ~(v << 1) : (v << 1);
        while (v >= 0x20) {
          sb.writeCharCode((0x20 | (v & 0x1f)) + 63);
          v >>= 5;
        }
        sb.writeCharCode(v + 63);
      }

      write(dLat);
      write(dLon);
    }
    return sb.toString();
  }

  Future<void> _publishLiveUpdate({
    required bool forceFlush,
    bool ending = false,
  }) async {
    if (!_liveShareActive ||
        _liveSessionId == null ||
        _currentPosition == null) {
      return;
    }
    // Accumulate movement point
    if (_pendingLivePoints.isEmpty) {
      _pendingLivePoints.add(_currentPosition!);
    } else {
      final last = _pendingLivePoints.last;
      final d = _distanceMeters(
        last.latitude,
        last.longitude,
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
      if (d >= _liveMinMoveMeters) _pendingLivePoints.add(_currentPosition!);
    }
    bool flush = forceFlush;
    final now = DateTime.now();
    if (!flush &&
        _lastLivePublish != null &&
        now.difference(_lastLivePublish!).inSeconds >=
            _livePublishIntervalSec) {
      flush = true;
    }
    List<String> chunks = [];
    if (flush && _pendingLivePoints.length > 1) {
      chunks.add(_encodePolyline(_pendingLivePoints));
      _pendingLivePoints
        ..clear()
        ..add(_currentPosition!);
      _lastLivePublish = now;
    }
    try {
      final doc = await _liveDoc();
      final update = <String, dynamic>{
        'last': {
          'lat': _currentPosition!.latitude,
          'lon': _currentPosition!.longitude,
          'altM': _currentAltitudeM,
          'heading': _currentHeadingDeg,
          'ts': now.toIso8601String(),
        },
      };
      if (chunks.isNotEmpty) {
        update['polylineChunks'] = FieldValue.arrayUnion(chunks);
      }
      if (ending) {
        update['active'] = false;
        update['endedAt'] = now.toIso8601String();
      }
      if (_liveShareToken != null) {
        update['token'] = _liveShareToken;
      }
      await doc.set(update, SetOptions(merge: true));
    } catch (e) {
      if (kDebugMode) debugPrint('Live publish failed: $e');
    }
  }

  Future<void> _loadAirports() async {
    final files = <String>[
      'assets/airports/cy_apt.geojson',
      'assets/airports/gr_apt.geojson',
      'assets/airports/il_apt.geojson',
    ];
    final List<_Airport> loaded = [];
    for (final file in files) {
      try {
        final s = await rootBundle.loadString(file);
        final j = jsonDecode(s) as Map<String, dynamic>;
        final features = (j['features'] as List?) ?? const [];
        final String country = file.contains('/cy_') || file.contains('\\cy_')
            ? 'CY'
            : file.contains('/gr_') || file.contains('\\gr_')
            ? 'GR'
            : 'IL';
        for (final f in features) {
          try {
            final m = f as Map<String, dynamic>;
            final origProps = (m['properties'] ?? {}) as Map<String, dynamic>;
            final props = Map<String, dynamic>.from(origProps);
            props['countryCode'] = country;
            final geom = m['geometry'] as Map<String, dynamic>?;
            if (geom == null) continue;
            final name = (props['name'] ?? props['NAME'] ?? '').toString();
            if (name.isEmpty) continue;
            final coords = (geom['coordinates'] as List?) ?? const [];
            if (coords.length < 2) continue;
            final lon = (coords[0] as num).toDouble();
            final lat = (coords[1] as num).toDouble();
            final icao =
                (props['icaoCode'] ??
                        props['ICAO'] ??
                        props['ident'] ??
                        props['icao'] ??
                        props['icao_code'])
                    ?.toString()
                    .toUpperCase();
            final iata =
                (props['iataCode'] ??
                        props['IATA'] ??
                        props['iata'] ??
                        props['iata_code'])
                    ?.toString()
                    .toUpperCase();
            loaded.add(
              _Airport(
                name: name,
                icao: icao,
                iata: iata,
                position: LatLng(lat, lon),
                properties: props,
              ),
            );
          } catch (_) {
            // ignore malformed feature
          }
        }
      } catch (_) {
        // ignore missing/bad files
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _airports
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _loadAirspace() async {
    final files = [
      'assets/airspaces/cy_asp.geojson',
      // Add more airspace files here if needed
    ];
    final List<Map<String, dynamic>> perims = [];
    for (final file in files) {
      try {
        final s = await rootBundle.loadString(file);
        final j = jsonDecode(s) as Map<String, dynamic>;
        final features = (j['features'] as List?) ?? const [];
        final fileCountry = file.contains('cy_')
            ? 'CY'
            : file.contains('gr_')
            ? 'GR'
            : file.contains('il_')
            ? 'IL'
            : 'CY';
        for (final f in features) {
          try {
            final m = f as Map<String, dynamic>;
            final props = (m['properties'] ?? {}) as Map<String, dynamic>;
            final name = (props['name'] ?? props['NAME'] ?? '').toString();
            final aspType =
                (props['class'] ?? props['Class'] ?? props['type'] ?? '')
                    .toString();
            final geom = m['geometry'] as Map<String, dynamic>?;
            if (geom == null) continue;
            if (geom['type'] == 'Polygon') {
              final coords = geom['coordinates'] as List?;
              if (coords != null && coords.isNotEmpty) {
                final List<LatLng> ring = [
                  for (final pt in coords[0])
                    LatLng(
                      (pt[1] as num).toDouble(),
                      (pt[0] as num).toDouble(),
                    ),
                ];
                if (ring.length > 1) {
                  perims.add({
                    'perimeter': ring,
                    'name': name.isNotEmpty ? name : null,
                    'countryCode': fileCountry,
                    'aspType': aspType,
                  });
                }
              }
            } else if (geom['type'] == 'MultiPolygon') {
              final polys = geom['coordinates'] as List?;
              if (polys != null) {
                for (final poly in polys) {
                  if (poly.isNotEmpty) {
                    final List<LatLng> ring = [
                      for (final pt in poly[0])
                        LatLng(
                          (pt[1] as num).toDouble(),
                          (pt[0] as num).toDouble(),
                        ),
                    ];
                    if (ring.length > 1) {
                      perims.add({
                        'perimeter': ring,
                        'name': name.isNotEmpty ? name : null,
                        'countryCode': fileCountry,
                        'aspType': aspType,
                      });
                    }
                  }
                }
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _airspacePerimeters = perims;
    });
  }

  Future<void> _loadReportingPointsOtherCountries() async {
    final files = [
      ('assets/reporting_points/gr_rpp.geojson', 'GR'),
      ('assets/reporting_points/il_rpp.geojson', 'IL'),
    ];
    final List<_ReportingPoint> addList = [];
    for (final tuple in files) {
      final path = tuple.$1;
      final country = tuple.$2;
      try {
        final text = await rootBundle.loadString(path);
        final data = jsonDecode(text);
        final features = (data is Map<String, dynamic>)
            ? ((data['features'] as List?) ?? const [])
            : const [];
        for (final f in features) {
          try {
            final m = (f as Map).cast<String, dynamic>();
            final props = (m['properties'] ?? {}) as Map<String, dynamic>;
            final geom = m['geometry'] as Map<String, dynamic>?;
            String name =
                (props['name'] ?? props['NAME'] ?? props['Field2'] ?? '')
                    .toString();
            if (name.isEmpty) name = 'RPP';
            double? lat;
            double? lon;
            if (geom != null && geom['type'] == 'Point') {
              final coords = (geom['coordinates'] as List?) ?? const [];
              if (coords.length >= 2) {
                lon = (coords[0] as num).toDouble();
                lat = (coords[1] as num).toDouble();
              }
            }
            if (lat == null || lon == null) {
              final f7 = (props['Field7'] ?? props['coords'] ?? '').toString();
              if (f7.isNotEmpty) {
                final parsed = _parseField7LatLon(f7);
                if (parsed != null) {
                  lat = parsed.$1;
                  lon = parsed.$2;
                }
              }
            }
            if (lat == null || lon == null) continue;
            // Legacy fields (routes/remarks) ignored in simplified model
            addList.add(
              _ReportingPoint(name: name, lat: lat, lon: lon, country: country),
            );
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (!mounted) {
      return;
    }
    setState(() {
      // Keep any already loaded countries (like CY) and replace GR/IL fresh
      _reportingPoints.removeWhere(
        (rp) => rp.country == 'GR' || rp.country == 'IL',
      );
      _reportingPoints.addAll(addList);
    });
  }

  Future<void> _loadNavaids() async {
    final files = [
      'assets/navaids/cy_nav.geojson',
      'assets/navaids/gr_nav.geojson',
      'assets/navaids/il_nav.geojson',
    ];
    final list = <_Navaid>[];
    for (final file in files) {
      try {
        final text = await rootBundle.loadString(file);
        final data = jsonDecode(text);
        final country = file.contains('cy_')
            ? 'CY'
            : file.contains('gr_')
            ? 'GR'
            : file.contains('il_')
            ? 'IL'
            : 'CY';
        final features = (data is Map<String, dynamic>)
            ? ((data['features'] as List?) ?? const [])
            : const [];
        for (final f in features) {
          try {
            final m = (f as Map).cast<String, dynamic>();
            final props = (m['properties'] ?? {}) as Map<String, dynamic>;
            final geom = m['geometry'] as Map<String, dynamic>?;
            if (geom == null || geom['type'] != 'Point') continue;
            final coords = (geom['coordinates'] as List?) ?? const [];
            if (coords.length < 2) continue;
            final lon = (coords[0] as num).toDouble();
            final lat = (coords[1] as num).toDouble();
            final name =
                (props['name'] ?? props['NAME'] ?? props['Title'] ?? '')
                    .toString();
            final ident =
                (props['ident'] ??
                        props['IDENT'] ??
                        props['icao'] ??
                        props['id'])
                    ?.toString() ??
                '';
            final type = (props['type'] ?? props['TYPE'] ?? props['kind'])
                ?.toString();
            final freq = (props['freq'] ?? props['FREQ'] ?? props['frequency'])
                ?.toString();
            list.add(
              _Navaid(
                name: name,
                ident: ident,
                type: type,
                freq: freq,
                country: country,
                lat: lat,
                lon: lon,
              ),
            );
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _navaids
        ..clear()
        ..addAll(list);
    });
  }

  Future<DateTime?> _pickDateTime(
    BuildContext ctx, {
    required DateTime initial,
  }) async {
    final date = await showDatePicker(
      context: ctx,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null) return null;
    final time = await showTimePicker(
      // ignore: use_build_context_synchronously
      context: ctx,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _deleteFlightEntry(int idxOriginal) async {
    if (idxOriginal < 0 || idxOriginal >= _flightLog.length) return;
    final ok = await _confirmDeleteDialog(
      'Delete flight',
      'Delete this flight log entry?',
    );
    if (!ok) return;
    setState(() {
      _flightLog.removeAt(idxOriginal);
    });
    await _saveFlightLog();
  }

  Future<bool> _confirmDeleteDialog(String title, String content) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    return res == true;
  }

  void _setLandingTimeForFlight(int idxOriginal, DateTime end) {
    if (idxOriginal < 0 || idxOriginal >= _flightLog.length) return;
    final f = _flightLog[idxOriginal];
    final startStr = f['startTime'] as String?;
    final start = startStr != null ? DateTime.tryParse(startStr) : null;
    if (start == null) return;
    final duration = end.difference(start).inSeconds;
    final secs = duration < 0 ? 0 : duration;
    final hours = secs / 3600.0;
    final durationDec = (hours * 10).round() / 10.0;
    f['endTime'] = end.toIso8601String();
    f['durationSec'] = secs;
    f['durationDec'] = durationDec;
    _saveFlightLog();
  }

  Future<Directory> _ensureFlightsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/Flights');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _exportFlightToKml(Map<String, dynamic> f) async {
    try {
      final points = (f['points'] as List?)?.cast<List>() ?? const [];
      final name = (f['startTime'] ?? 'flight').toString().replaceAll(':', '-');
      final sb = StringBuffer();
      sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
      sb.writeln('<kml xmlns="http://www.opengis.net/kml/2.2"><Document>');
      sb.writeln('<name>$name</name>');
      final startLat = (f['startLat'] as num?)?.toDouble();
      final startLon = (f['startLon'] as num?)?.toDouble();
      final endLat = (f['endLat'] as num?)?.toDouble();
      final endLon = (f['endLon'] as num?)?.toDouble();
      // Compute decimal duration (hours, 1 decimal where 0.1 = 6 minutes)
      double durationDec = 0.0;
      final dnum = (f['durationDec'] as num?)?.toDouble();
      if (dnum != null) {
        durationDec = dnum;
      } else {
        final secsNum = (f['durationSec'] as num?)?.toInt();
        if (secsNum != null) {
          durationDec = ((secsNum / 3600.0) * 10).round() / 10.0;
        } else {
          final sStr = f['startTime'] as String?;
          final eStr = f['endTime'] as String?;
          if (sStr != null && eStr != null) {
            final s = DateTime.tryParse(sStr);
            final e = DateTime.tryParse(eStr);
            if (s != null && e != null) {
              final secs2 = e.difference(s).inSeconds;
              durationDec = ((secs2 / 3600.0) * 10).round() / 10.0;
            }
          }
        }
      }
      if (startLat != null && startLon != null) {
        sb.writeln(
          '<Placemark><name>Start</name><Point><coordinates>'
          '${startLon.toStringAsFixed(6)},${startLat.toStringAsFixed(6)},0'
          '</coordinates></Point></Placemark>',
        );
      }
      if (endLat != null && endLon != null) {
        sb.writeln(
          '<Placemark><name>End</name><Point><coordinates>'
          '${endLon.toStringAsFixed(6)},${endLat.toStringAsFixed(6)},0'
          '</coordinates></Point></Placemark>',
        );
      }
      if (points.isNotEmpty) {
        sb.writeln('<Placemark><name>Route</name><LineString><coordinates>');
        for (final e in points) {
          final lat = (e[0] as num).toDouble();
          final lon = (e[1] as num).toDouble();
          sb.writeln('${lon.toStringAsFixed(6)},${lat.toStringAsFixed(6)},0');
        }
        sb.writeln('</coordinates></LineString></Placemark>');
      }
      if (durationDec > 0.0) {
        sb.writeln(
          '<Placemark><name>Duration</name><description>Duration: ${durationDec.toStringAsFixed(1)} h</description></Placemark>',
        );
      }
      sb.writeln('</Document></kml>');
      final dir = await _ensureFlightsDir();
      final file = File('${dir.path}/$name.kml');
      await file.writeAsString(sb.toString());
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(content: Text('Exported KML to ${file.path}')),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Export KML failed: $e');
    }
  }

  // Show details for nearest places and coordinates
  void _showFlightDetailsDialog(Map<String, dynamic> f) {
    final sLat = (f['startLat'] as num?)?.toDouble();
    final sLon = (f['startLon'] as num?)?.toDouble();
    final eLat = (f['endLat'] as num?)?.toDouble();
    final eLon = (f['endLon'] as num?)?.toDouble();
    String toLine = _nearestOrCoords(sLat, sLon);
    String ldLine = _nearestOrCoords(eLat, eLon);
    // Compute decimal duration for display
    double durationDec = 0.0;
    final dnum = (f['durationDec'] as num?)?.toDouble();
    if (dnum != null) {
      durationDec = dnum;
    } else {
      final secsNum = (f['durationSec'] as num?)?.toInt();
      if (secsNum != null) {
        durationDec = ((secsNum / 3600.0) * 10).round() / 10.0;
      } else {
        final sStr = f['startTime'] as String?;
        final eStr = f['endTime'] as String?;
        if (sStr != null && eStr != null) {
          final s = DateTime.tryParse(sStr);
          final e = DateTime.tryParse(eStr);
          if (s != null && e != null) {
            final secs2 = e.difference(s).inSeconds;
            durationDec = ((secs2 / 3600.0) * 10).round() / 10.0;
          }
        }
      }
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Flight Details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('T/O: $toLine'),
            const SizedBox(height: 6),
            Text('LNDG: $ldLine'),
            const SizedBox(height: 6),
            if (durationDec > 0.0)
              Text('Duration: ${durationDec.toStringAsFixed(1)} h'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _nearestOrCoords(double? lat, double? lon) {
    if (lat == null || lon == null) return 'Coords: --';
    final pos = LatLng(lat, lon);
    final nearest = _nearestPlace(pos, 1.0);
    if (nearest != null) {
      return '${nearest['type']}: ${nearest['name']} (${(nearest['distanceNm'] as double).toStringAsFixed(2)} NM)';
    }
    return 'Coords: ${_toDms(lat, isLat: true)}, ${_toDms(lon, isLat: false)}';
  }

  Map<String, Object>? _nearestPlace(LatLng p, double radiusNm) {
    double bestNm = double.infinity;
    String? bestName;
    String? bestType;
    // Airports
    for (final a in _airports) {
      final dNm =
          _distanceMeters(
            p.latitude,
            p.longitude,
            a.position.latitude,
            a.position.longitude,
          ) /
          1852.0;
      if (dNm < bestNm) {
        bestNm = dNm;
        bestName = (a.icao != null && a.icao!.isNotEmpty) ? a.icao : a.name;
        bestType = 'Airport';
      }
    }
    // Waypoints
    for (final w in _waypoints) {
      final dNm =
          _distanceMeters(p.latitude, p.longitude, w.lat, w.lon) / 1852.0;
      if (dNm < bestNm) {
        bestNm = dNm;
        bestName = w.name;
        bestType = 'Waypoint';
      }
    }
    if (bestNm <= radiusNm && bestName != null && bestType != null) {
      return {'name': bestName, 'type': bestType, 'distanceNm': bestNm};
    }
    return null;
  }

  Future<void> _loadObstacles() async {
    final files = [
      'assets/obstacles/cy_obs.json',
      'assets/obstacles/gr_obs.geojson',
      'assets/obstacles/il_obs.geojson',
    ];
    final list = <_Obstacle>[];
    for (final file in files) {
      final country = file.contains('cy_')
          ? 'CY'
          : file.contains('gr_')
          ? 'GR'
          : file.contains('il_')
          ? 'IL'
          : 'CY';
      try {
        final text = await rootBundle.loadString(file);
        final data = jsonDecode(text);
        if (data is Map<String, dynamic> && data.containsKey('features')) {
          final features = (data['features'] as List?) ?? const [];
          for (final f in features) {
            try {
              final m = (f as Map).cast<String, dynamic>();
              final props = (m['properties'] ?? {}) as Map<String, dynamic>;
              final geom = m['geometry'] as Map<String, dynamic>?;
              if (geom == null || geom['type'] != 'Point') continue;
              final coords = (geom['coordinates'] as List?) ?? const [];
              if (coords.length < 2) continue;
              final lon = (coords[0] as num).toDouble();
              final lat = (coords[1] as num).toDouble();
              final name = (props['name'] ?? props['NAME'] ?? props['Title'])
                  ?.toString();
              final kind = (props['type'] ?? props['TYPE'] ?? props['kind'])
                  ?.toString();
              final hM =
                  (props['height_m'] as num?)?.toDouble() ??
                  (props['height'] as num?)?.toDouble() ??
                  (props['HGT'] as num?)?.toDouble();
              final hFt = hM != null ? hM * 3.28084 : null;
              list.add(
                _Obstacle(
                  country: country,
                  lat: lat,
                  lon: lon,
                  name: name ?? 'Obstacle',
                  kind: kind ?? 'Obstacle',
                  heightFeet: hFt,
                ),
              );
            } catch (_) {}
          }
        } else if (data is List) {
          for (final e in data) {
            try {
              final m = (e as Map).cast<String, dynamic>();
              num? latNum = (m['lat'] ?? m['latitude']) as num?;
              num? lonNum = (m['lon'] ?? m['longitude']) as num?;
              if (latNum == null || lonNum == null) {
                final geom = m['geometry'];
                if (geom is Map<String, dynamic> &&
                    (geom['type'] == 'Point') &&
                    geom['coordinates'] is List &&
                    (geom['coordinates'] as List).length >= 2) {
                  final coords = (geom['coordinates'] as List);
                  final lonV = (coords[0] as num?)?.toDouble();
                  final latV = (coords[1] as num?)?.toDouble();
                  if (latV != null && lonV != null) {
                    latNum = latV;
                    lonNum = lonV;
                  }
                }
              }
              if (latNum == null || lonNum == null) continue;

              double? hM =
                  (m['height_m'] as num?)?.toDouble() ??
                  (m['height'] as num?)?.toDouble();
              if (hM == null) {
                final h = m['height'];
                if (h is Map) {
                  final v = (h['value'] as num?)?.toDouble();
                  if (v != null) hM = v;
                }
              }
              final hFt = hM != null ? hM * 3.28084 : null;

              final name =
                  ((m['name'] ?? m['title'])?.toString() ?? 'Obstacle');
              final kindRaw = m['kind'] ?? m['type'];
              final kind = kindRaw is String ? kindRaw : 'Obstacle';

              list.add(
                _Obstacle(
                  country: country,
                  lat: latNum.toDouble(),
                  lon: lonNum.toDouble(),
                  name: name,
                  kind: kind,
                  heightFeet: hFt,
                ),
              );
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _obstacles
        ..clear()
        ..addAll(list);
    });
    if (kDebugMode) {
      final cy = list.where((o) => o.country == 'CY').length;
      final gr = list.where((o) => o.country == 'GR').length;
      final il = list.where((o) => o.country == 'IL').length;
      debugPrint('Obstacles loaded: total=${list.length} CY=$cy GR=$gr IL=$il');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Obstacles loaded: total=${list.length} CY=$cy GR=$gr IL=$il',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _loadReportingPointsCyprus() async {
    try {
      final text = await rootBundle.loadString(
        'assets/reporting_points/cy.ifrrpp.geojson',
      );
      final data = jsonDecode(text);
      final List<_ReportingPoint> list = [];
      if (data is Map<String, dynamic>) {
        final features = (data['features'] as List?) ?? const [];
        for (final f in features) {
          try {
            final m = (f as Map).cast<String, dynamic>();
            final props = (m['properties'] ?? {}) as Map<String, dynamic>;
            final name = (props['Field2'] ?? props['name'] ?? '').toString();
            final field7 = (props['Field7'] ?? '').toString();
            if (name.isEmpty || field7.isEmpty) continue;
            final coords = _parseField7LatLon(field7);
            if (coords == null) continue;
            // Legacy fields (routes/remarks) ignored in simplified model
            list.add(
              _ReportingPoint(
                name: name,
                lat: coords.$1,
                lon: coords.$2,
                country: 'CY',
              ),
            );
          } catch (_) {}
        }
      }
      if (!mounted) {
        return;
      }
      setState(() => _reportingPoints = list);
    } catch (_) {
      // ignore
    }
  }

  (double, double)? _parseField7LatLon(String raw) {
    final s = raw.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    if (s.isEmpty) return null;
    final parts = s.split(RegExp(r'\s+'));
    String? latTok;
    String? lonTok;
    for (final p in parts) {
      if (p.isEmpty) continue;
      if (p.endsWith('N') || p.endsWith('S')) latTok ??= p;
      if (p.endsWith('E') || p.endsWith('W')) lonTok ??= p;
    }
    if (latTok == null || lonTok == null) return null;
    final lat = _compactDmsTokenToDecimal(latTok, isLat: true);
    final lon = _compactDmsTokenToDecimal(lonTok, isLat: false);
    if (lat == null || lon == null) return null;
    return (lat, lon);
  }

  double? _compactDmsTokenToDecimal(String tok, {required bool isLat}) {
    if (tok.isEmpty) return null;
    final hemi = tok.substring(tok.length - 1).toUpperCase();
    final digits = tok.substring(0, tok.length - 1);
    final need = isLat ? 6 : 7; // DDMMSS or DDDMMSS
    final d = digits.padLeft(need, '0');
    final degLen = isLat ? 2 : 3;
    if (d.length < degLen + 4) return null;
    final deg = double.tryParse(d.substring(0, degLen)) ?? 0;
    final min = double.tryParse(d.substring(degLen, degLen + 2)) ?? 0;
    final sec = double.tryParse(d.substring(degLen + 2, degLen + 4)) ?? 0;
    double val = deg + (min / 60.0) + (sec / 3600.0);
    if (hemi == 'S' || hemi == 'W') val = -val;
    return val;
  }

  Future<void> _onAirportTap(_Airport apt) async {
    if (!mounted) return;
    _showAirportDetails(apt);
  }

  Future<String?> _fetchAvwx(String type, String icao) async {
    // Basic validation: require a non-placeholder token
    if (kAvwxApiToken.isEmpty || kAvwxApiToken.contains('DEMO_TOKEN')) {
      return 'Error: AVWX API token is not set. Please set kAvwxApiToken.';
    }
    final uri = Uri.parse('https://avwx.rest/api/$type/$icao');
    try {
      // Try Bearer scheme first (preferred by AVWX), include Accept header
      final res = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $kAvwxApiToken',
          'Accept': 'application/json',
        },
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return (data['raw'] as String?) ?? (data['sanitized'] as String?);
      }
      // If unauthorized, try Token scheme as a fallback
      if (res.statusCode == 401 || res.statusCode == 403) {
        final res2 = await http.get(
          uri,
          headers: {
            'Authorization': 'Token $kAvwxApiToken',
            'Accept': 'application/json',
          },
        );
        if (res2.statusCode == 200) {
          final data = jsonDecode(res2.body) as Map<String, dynamic>;
          return (data['raw'] as String?) ?? (data['sanitized'] as String?);
        }
        return 'Error: AVWX returned ${res2.statusCode}. ${res2.body}';
      }
      return 'Error: AVWX returned ${res.statusCode}. ${res.body}';
    } catch (e) {
      // On Flutter Web, CORS may block this request; surface the error
      return 'Network error: $e';
    }
  }

  void _showInfo(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAirportDetails(_Airport a) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          child: _buildAirportInfo(a),
        ),
      ),
    );
  }

  void _showNavaidDetails(_Navaid n) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.radio_button_checked,
                  color: Colors.cyanAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    n.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(n.country, style: const TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${n.lat.toStringAsFixed(5)}, ${n.lon.toStringAsFixed(5)}',
              style: const TextStyle(color: Colors.white70),
            ),
            if (n.ident.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Ident: ${n.ident}',
                style: const TextStyle(color: Colors.white),
              ),
            ],
            if ((n.type ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Type: ${n.type}',
                style: const TextStyle(color: Colors.white),
              ),
            ],
            if ((n.freq ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Frequency: ${n.freq}',
                style: const TextStyle(color: Colors.white),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _addToRoute(LatLng(n.lat, n.lon));
                  },
                  icon: const Icon(Icons.alt_route),
                  label: const Text('Add to Route'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _directTo(LatLng(n.lat, n.lon));
                  },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('Direct To'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showReportingPoint(_ReportingPoint rp) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.change_history, color: Colors.purpleAccent),
                const SizedBox(width: 8),
                Text(
                  rp.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(rp.country, style: const TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${rp.lat.toStringAsFixed(5)}, ${rp.lon.toStringAsFixed(5)}',
              style: const TextStyle(color: Colors.white70),
            ),
            // routes/remarks removed from simplified model
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _addToRoute(LatLng(rp.lat, rp.lon));
                  },
                  icon: const Icon(Icons.alt_route),
                  label: const Text('Add to Route'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _directTo(LatLng(rp.lat, rp.lon));
                  },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('Direct To'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAirportInfo(_Airport a) {
    final Map<String, dynamic> p = a.properties ?? const <String, dynamic>{};
    Map<String, dynamic>? elev = p['elevation'] is Map<String, dynamic>
        ? (p['elevation'] as Map<String, dynamic>)
        : null;
    final elevVal = (elev?['value'] as num?)?.toDouble();
    final elevMeters = elevVal;
    final elevFeet = elevMeters != null ? (elevMeters * 3.28084) : null;

    final freqs =
        (p['frequencies'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final runways =
        (p['runways'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          a.name,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (a.icao != null && a.icao!.isNotEmpty)
              Chip(
                label: Text(
                  'ICAO: ${a.icao}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            if (a.iata != null && a.iata!.isNotEmpty)
              Chip(
                label: Text(
                  'IATA: ${a.iata}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            if (p['country'] != null)
              Chip(
                label: Text(
                  'Country: ${p['country']}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            if (p['type'] != null)
              Chip(
                label: Text(
                  'Type: ${p['type']}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (elevMeters != null)
          Text(
            'Elevation: ${elevMeters.toStringAsFixed(0)} m${elevFeet != null ? ' (${elevFeet.toStringAsFixed(0)} ft)' : ''}',
            style: const TextStyle(color: Colors.white70),
          ),
        if (p['elevationGeoid'] is Map<String, dynamic>) ...[
          const SizedBox(height: 4),
          Text(
            'Elevation (HAE): ${p['elevationGeoid']['hae']}',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
        const SizedBox(height: 12),
        if (freqs.isNotEmpty) ...[
          const Text(
            'Frequencies',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          ...freqs.map((f) {
            final name = (f['name'] ?? '').toString();
            final value = (f['value'] ?? '').toString();
            final primary = (f['primary'] == true) ? ' (Primary)' : '';
            return Text(
              '- ${name.isNotEmpty ? '$name: ' : ''}$value$primary',
              style: const TextStyle(color: Colors.white70),
            );
          }),
          const SizedBox(height: 12),
        ],
        if (runways.isNotEmpty) ...[
          const Text(
            'Runways',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          ...runways.map((r) {
            final des = (r['designator'] ?? '').toString();
            final dim = r['dimension'] as Map<String, dynamic>?;
            final len = (dim?['length']?['value'] as num?)?.toDouble();
            final wid = (dim?['width']?['value'] as num?)?.toDouble();
            final lengthStr = len != null
                ? '${len.toStringAsFixed(0)} m'
                : 'n/a';
            final widthStr = wid != null
                ? '${wid.toStringAsFixed(0)} m'
                : 'n/a';
            return Text(
              '- RWY $des: $lengthStr x $widthStr',
              style: const TextStyle(color: Colors.white70),
            );
          }),
          const SizedBox(height: 12),
        ],
        // Optional: button to fetch METAR/TAF
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: a.icao == null || a.icao!.isEmpty
                ? null
                : () async {
                    final code = a.icao!.toUpperCase();
                    final metar = await _fetchAvwx('metar', code);
                    final taf = await _fetchAvwx('taf', code);
                    if (!mounted) return;
                    _showInfo(
                      '${a.name} ($code)',
                      'METAR:\n${metar ?? 'N/A'}\n\nTAF:\n${taf ?? 'N/A'}',
                    );
                  },
            icon: const Icon(Icons.cloud),
            label: const Text('Fetch METAR/TAF'),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _addToRoute(a.position);
              },
              icon: const Icon(Icons.alt_route),
              label: const Text('Add to Route'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _directTo(a.position);
              },
              icon: const Icon(Icons.center_focus_strong),
              label: const Text('Direct To'),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AW139 Cruise'),
        actions: [
          IconButton(
            tooltip: 'Restart location tracking',
            icon: const Icon(Icons.my_location),
            onPressed: () async {
              final sm = ScaffoldMessenger.of(context); // capture before awaits
              _stopLocationTracking(auto: false);
              setState(() {
                _locationDebugStatus = 'Restarting...';
                _locationError = null;
              });
              await Future.delayed(const Duration(milliseconds: 300));
              final ready = await _ensureLocationReady(
                openSettingsIfNeeded: true,
              );
              if (!mounted) return; // ensure safe context use after awaits
              if (ready) {
                _initLocation();
                sm.showSnackBar(
                  const SnackBar(
                    content: Text('Location tracking restarted'),
                    duration: Duration(seconds: 2),
                  ),
                );
              } else {
                sm.showSnackBar(
                  const SnackBar(
                    content: Text('Grant location permission (see top-left)'),
                    duration: Duration(seconds: 3),
                    backgroundColor: Colors.orange,
                  ),
                );
              }
            },
          ),
          IconButton(
            tooltip: 'Stop location tracking',
            icon: const Icon(Icons.location_disabled),
            onPressed: () => _stopLocationTracking(auto: false),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: _showInfoBar ? 56 : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_vertexEditMode) ...[
              // Save / Cancel for vertex edit mode
              FloatingActionButton.extended(
                heroTag: 'fab-vertex-save',
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                onPressed: _applyVertexEdit,
                icon: const Icon(Icons.save),
                label: const Text('Save area'),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.extended(
                heroTag: 'fab-vertex-cancel',
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.black,
                onPressed: _cancelVertexEdit,
                icon: const Icon(Icons.close),
                label: const Text('Cancel edit'),
              ),
              const SizedBox(height: 16),
            ],
            // Ruler toggle FAB
            FloatingActionButton.small(
              heroTag: 'fab-ruler',
              tooltip: _rulerActive
                  ? 'Disable ruler'
                  : 'Enable ruler (measure distance & bearing)',
              backgroundColor: _rulerActive
                  ? Colors.yellowAccent
                  : Colors.black87,
              foregroundColor: _rulerActive ? Colors.black : Colors.white,
              onPressed: _toggleRuler,
              child: const Icon(Icons.straighten),
            ),
            const SizedBox(height: 10),
            // Small FAB to toggle the info bar quickly
            FloatingActionButton.small(
              heroTag: 'fab-info',
              tooltip: _showInfoBar ? 'Hide info bar' : 'Show info bar',
              backgroundColor: _showInfoBar ? Colors.green : Colors.black87,
              foregroundColor: Colors.white,
              onPressed: () {
                setState(() {
                  _showInfoBar = !_showInfoBar;
                });
              },
              child: const Icon(Icons.info_outline),
            ),
            const SizedBox(height: 10),
            // Primary FAB: Save current position as MOT waypoint instantly
            FloatingActionButton(
              heroTag: 'fab-save-pos',
              tooltip: 'Save MOT waypoint (current position)',
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
              onPressed: _saveCurrentPosAsMot,
              child: const Icon(Icons.add_location_alt),
            ),
          ],
        ),
      ),
      body: Stack(
        key: _mapStackKey,
        children: [
          _nvgWrap(
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentPosition ?? _initialCenter,
                initialZoom: _mapZoom,
                onPositionChanged: (pos, hasGesture) {
                  // Track current zoom so auto-center preserves user's zoom level
                  _mapZoom = pos.zoom;
                  // When the user interacts with the map (pan/zoom), temporarily
                  // suppress auto-centering for a short period so the map does
                  // not fight the user's gestures. It will resume automatically.
                  if (hasGesture) {
                    _suppressAutoCenterFor(const Duration(seconds: 15));
                  }
                },
                onTap: (tap, latLng) {
                  // Treat taps as user interaction that should pause auto-centering
                  _suppressAutoCenterFor(const Duration(seconds: 15));
                  if (_draftPolygonMode) {
                    setState(() {
                      _draftPolygonPoints.add(latLng);
                    });
                  } else if (_draftLineMode) {
                    setState(() {
                      _draftLinePoints.add(latLng);
                    });
                  } else if (_vertexEditMode &&
                      _vertexEditSelectedVertex != null) {
                    // Move the selected vertex to tapped location
                    final vi = _vertexEditSelectedVertex!;
                    setState(() {
                      if (vi >= 0 && vi < _vertexEditPoints.length) {
                        _vertexEditPoints[vi] = latLng;
                        // Keep polygon ring closed if first/last vertex changed
                        if (vi == 0 && _vertexEditPoints.isNotEmpty) {
                          _vertexEditPoints[_vertexEditPoints.length - 1] =
                              latLng;
                        } else if (vi == _vertexEditPoints.length - 1 &&
                            _vertexEditPoints.isNotEmpty) {
                          _vertexEditPoints[0] = latLng;
                        }
                      }
                      _vertexEditSelectedVertex = null;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Vertex moved')),
                    );
                  } else if (_rulerActive) {
                    _handleRulerTap(latLng);
                  } else {
                    setState(() {
                      _selectedAirspaceIdx = null;
                      _mapZoom = _initialZoom;
                    });
                  }
                },
                onLongPress: (_, latLng) => _showLongPressMenu(latLng),
              ),
              children: [
                // (Holding debug layers removed)
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.aw139_cruise',
                ),
                if (_airports.isNotEmpty)
                  MarkerLayer(
                    markers: _airports
                        .where((a) {
                          final cc =
                              (a.properties?['countryCode'] as String?) ?? '';
                          return (cc == 'CY' && _showCyAirports) ||
                              (cc == 'GR' && _showGrAirports) ||
                              (cc == 'IL' && _showIlAirports);
                        })
                        .map(
                          (a) => Marker(
                            point: a.position,
                            width: 36,
                            height: 36,
                            child: GestureDetector(
                              onTap: () => _onAirportTap(a),
                              child: Tooltip(
                                message:
                                    '${a.name}${a.icao != null ? ' (${a.icao})' : ''}',
                                child: const Icon(
                                  Icons.local_airport,
                                  color: Colors.orangeAccent,
                                  size: 28,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                if (_reportingPoints.isNotEmpty)
                  MarkerLayer(
                    markers: _reportingPoints
                        .where(
                          (rp) =>
                              (rp.country == 'CY' && _showCyReportingPoints) ||
                              (rp.country == 'GR' && _showGrReportingPoints) ||
                              (rp.country == 'IL' && _showIlReportingPoints),
                        )
                        .map(
                          (rp) => Marker(
                            point: LatLng(rp.lat, rp.lon),
                            width: 80,
                            height: 56,
                            child: GestureDetector(
                              onTap: () => _showReportingPoint(rp),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Distinctive brightly colored diamond marker
                                  // IFR reporting point: solid black triangle (user preference)
                                  const Icon(
                                    Icons.change_history,
                                    color: Colors.black,
                                    size: 20,
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.blueGrey.shade900
                                          .withValues(alpha: 0.85),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: Colors.black,
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      rp.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                // Navaids per country
                if (_navaids.isNotEmpty)
                  MarkerLayer(
                    markers: _navaids
                        .where(
                          (n) =>
                              (n.country == 'CY' && _showCyNavaids) ||
                              (n.country == 'GR' && _showGrNavaids) ||
                              (n.country == 'IL' && _showIlNavaids),
                        )
                        .map((n) {
                          final t = (n.type ?? '').toUpperCase();
                          final Color color = t.contains('VOR')
                              ? Colors.purpleAccent
                              : t.contains('NDB')
                              ? Colors.blueAccent
                              : Colors.cyanAccent;
                          final label = n.ident.isNotEmpty ? n.ident : n.name;
                          return Marker(
                            point: LatLng(n.lat, n.lon),
                            width: 100,
                            height: 54,
                            child: GestureDetector(
                              onTap: () => _showNavaidDetails(n),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.radio_button_checked,
                                    color: color,
                                    size: 18,
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xCC000000),
                                      border: Border.all(color: Colors.white24),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      label,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        })
                        .toList(),
                  ),

                // Obstacles per country
                if (_obstacles.isNotEmpty)
                  MarkerLayer(
                    markers: _obstacles
                        .where(
                          (o) =>
                              (o.country == 'CY' && _showCyObstacles) ||
                              (o.country == 'GR' && _showGrObstacles) ||
                              (o.country == 'IL' && _showIlObstacles),
                        )
                        .map((o) {
                          final hFt = o.heightFeet?.round();
                          return Marker(
                            point: LatLng(o.lat, o.lon),
                            width: 48,
                            height: 40,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.redAccent,
                                  size: 20,
                                ),
                                const SizedBox(height: 2),
                                // Show only height if available; hide name to reduce clutter
                                if (hFt != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xCC000000),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '$hFt ft',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        })
                        .toList(),
                  ),

                if (_showWaypoints && _waypoints.isNotEmpty)
                  MarkerLayer(
                    markers: _waypoints.map((wp) {
                      // Choose a symbol widget for the waypoint type. For Helipad, show an "H" marker.
                      late final Widget symbol;
                      switch (wp.type) {
                        case 'MOT':
                          symbol = const Icon(
                            Icons.add_location_alt,
                            color: Colors.deepOrangeAccent,
                            size: 28,
                          );
                          break;
                        case 'Hospital':
                          symbol = const Icon(
                            Icons.local_hospital,
                            color: Colors.redAccent,
                            size: 28,
                          );
                          break;
                        case 'Helipad':
                          symbol = Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.lightBlueAccent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.black87,
                                width: 1,
                              ),
                              boxShadow: const [
                                BoxShadow(color: Colors.black54, blurRadius: 2),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'H',
                              style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          );
                          break;
                        case 'Dams':
                          symbol = const Icon(
                            Icons.water,
                            color: Colors.blueAccent,
                            size: 28,
                          );
                          break;
                        default:
                          symbol = const Icon(
                            Icons.place,
                            color: Colors.orangeAccent,
                            size: 28,
                          );
                      }
                      return Marker(
                        point: LatLng(wp.lat, wp.lon),
                        width: 160,
                        height: 60,
                        child: GestureDetector(
                          onTap: () => _showWaypointActions(wp),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              symbol,
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.50),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  wp.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                // Power lines: draw later in stack with outline for visibility
                // Saved areas: polygons/circles
                if (_savedAreas.any((a) => a.type != 'line'))
                  PolygonLayer(
                    polygons: _savedAreas
                        .asMap()
                        .entries
                        .where((e) => e.value.type != 'line')
                        .map((entry) {
                          final idx = entry.key;
                          final a = entry.value;
                          final pts =
                              (_vertexEditMode && _vertexEditAreaIndex == idx)
                              ? _vertexEditPoints
                              : a.points;
                          return Polygon(
                            points: pts,
                            color: _colorFromHex(a.fillColorHex),
                            borderStrokeWidth: 2.0,
                            borderColor: _colorFromHex(a.strokeColorHex),
                          );
                        })
                        .toList(),
                  ),
                // Saved areas: lines (draw with subtle outline for visibility)
                if (_showSavedAreaLines &&
                    _savedAreas.any((a) => a.type == 'line'))
                  PolylineLayer(
                    polylines: () {
                      final out = <Polyline>[];
                      for (final a in _savedAreas.where(
                        (a) => a.type == 'line' && a.points.length >= 2,
                      )) {
                        final col = _colorFromHex(a.strokeColorHex);
                        // Outline
                        out.add(
                          Polyline(
                            points: a.points,
                            color: Colors.white.withValues(alpha: 0.55),
                            strokeWidth: 5.0,
                          ),
                        );
                        // Main stroke
                        out.add(
                          Polyline(
                            points: a.points,
                            color: col,
                            strokeWidth: 3.0,
                          ),
                        );
                      }
                      return out;
                    }(),
                  ),
                // Imported layers: polygons
                if (_importedLayers.any(
                  (l) => l.visible && l.polygons.isNotEmpty,
                ))
                  PolygonLayer(
                    polygons: [
                      for (final l in _importedLayers)
                        if (l.visible)
                          for (final poly in l.polygons)
                            Polygon(
                              points: poly,
                              color: _colorFromHex(l.fillColorHex),
                              borderStrokeWidth: 2.0,
                              borderColor: _colorFromHex(l.strokeColorHex),
                            ),
                    ],
                  ),
                // Imported layers: polylines (with outline), excluding ones used as power lines
                if (_importedLayers.any(
                  (l) =>
                      l.visible && !l.useAsPowerLines && l.polylines.isNotEmpty,
                ))
                  PolylineLayer(
                    polylines: () {
                      final out = <Polyline>[];
                      for (final l in _importedLayers.where(
                        (l) => l.visible && !l.useAsPowerLines,
                      )) {
                        for (final line in l.polylines) {
                          out.add(
                            Polyline(
                              points: line,
                              color: Colors.white.withValues(alpha: 0.55),
                              strokeWidth: 5.0,
                            ),
                          );
                          out.add(
                            Polyline(
                              points: line,
                              color: _colorFromHex(l.strokeColorHex),
                              strokeWidth: 3.0,
                            ),
                          );
                        }
                      }
                      return out;
                    }(),
                  ),
                // Imported layers: points
                if (_importedLayers.any(
                  (l) => l.visible && l.points.isNotEmpty,
                ))
                  MarkerLayer(
                    markers: [
                      for (final l in _importedLayers)
                        if (l.visible)
                          for (final p in l.points)
                            Marker(
                              point: p,
                              width: 14,
                              height: 14,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _colorFromHex(l.strokeColorHex),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.black87,
                                    width: 1,
                                  ),
                                ),
                              ),
                            ),
                    ],
                  ),
                // Power lines (native + imported flagged as power lines): render after imported layers, with outline + core
                if (_showCyPowerLines && _gatherPowerLineSegments().isNotEmpty)
                  PolylineLayer(
                    polylines: () {
                      final out = <Polyline>[];
                      for (final line in _gatherPowerLineSegments()) {
                        out.add(
                          Polyline(
                            points: line,
                            color: Colors.white.withValues(alpha: 0.65),
                            strokeWidth: 6.0,
                          ),
                        );
                        out.add(
                          Polyline(
                            points: line,
                            color: Colors.black,
                            strokeWidth: 3.5,
                          ),
                        );
                      }
                      return out;
                    }(),
                  ),
                // Vertex edit handles (tap-to-move) for the active polygon
                if (_vertexEditMode &&
                    _vertexEditAreaIndex != null &&
                    _vertexEditPoints.length >= 3)
                  MarkerLayer(
                    markers: List<Marker>.generate(
                      // Exclude closing duplicate index (last)
                      _vertexEditPoints.isNotEmpty
                          ? math.max(0, _vertexEditPoints.length - 1)
                          : 0,
                      (i) => Marker(
                        point: _vertexEditPoints[i],
                        width: 28,
                        height: 28,
                        child: _buildDraggableVertexHandle(i),
                      ),
                    ),
                  ),
                if (_draftPolygonPoints.length >= 2)
                  PolygonLayer(
                    polygons: [
                      Polygon(
                        points: _draftPolygonPoints,
                        color: Colors.red.withValues(alpha: 0.15),
                        borderStrokeWidth: 2.0,
                        borderColor: Colors.redAccent,
                      ),
                    ],
                  ),
                if (_draftLinePoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      // Outline underlay for visibility
                      Polyline(
                        points: _draftLinePoints,
                        color: Colors.white.withValues(alpha: 0.55),
                        strokeWidth: 5.0,
                      ),
                      Polyline(
                        points: _draftLinePoints,
                        color: Colors.redAccent,
                        strokeWidth: 3.0,
                      ),
                    ],
                  ),
                // Ruler overlays: line and endpoints
                if (_rulerActive && _rulerStart != null && _rulerEnd != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: [_rulerStart!, _rulerEnd!],
                        color: Colors.yellowAccent,
                        strokeWidth: 3,
                      ),
                    ],
                  ),
                if (_rulerActive && _rulerStart != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _rulerStart!,
                        width: 36,
                        height: 36,
                        child: const Icon(
                          Icons.radio_button_unchecked,
                          color: Colors.yellowAccent,
                          size: 24,
                        ),
                      ),
                      if (_rulerEnd != null)
                        Marker(
                          point: _rulerEnd!,
                          width: 36,
                          height: 36,
                          child: const Icon(
                            Icons.location_on,
                            color: Colors.yellowAccent,
                            size: 28,
                          ),
                        ),
                    ],
                  ),
                if (_airspacePerimeters.isNotEmpty) ...[
                  PolylineLayer(
                    polylines: _airspacePerimeters
                        .asMap()
                        .entries
                        .where((e) {
                          final cc = (e.value['countryCode'] ?? '') as String;
                          return (cc == 'CY' && _showCyAirspace) ||
                              (cc == 'GR' && _showGrAirspace) ||
                              (cc == 'IL' && _showIlAirspace);
                        })
                        .map((entry) {
                          final idx = entry.key;
                          final asp = entry.value;
                          return Polyline(
                            points: asp['perimeter'] as List<LatLng>,
                            color: Colors.red.withValues(alpha: 0.7),
                            strokeWidth: _selectedAirspaceIdx == idx
                                ? 4.0
                                : 2.0,
                          );
                        })
                        .toList(),
                  ),
                  // Cloud density overlay (simple circular markers)
                  if (_showClouds && _cloudCells.isNotEmpty)
                    MarkerLayer(
                      markers: _cloudCells.map((cell) {
                        final rawCol = _cloudColorForDensity(cell.density);
                        final col = rawCol.withValues(
                          alpha: rawCol.a * _wxOpacity,
                        );
                        final label = _wxShowPercentLabels
                            ? (cell.density * 100).round().toString()
                            : '';
                        final size =
                            (28 + (_mapZoom.clamp(5.0, 13.0) - 5.0) * 1.5)
                                .clamp(20, 42)
                                .toDouble();
                        return Marker(
                          point: cell.pos,
                          width: size,
                          height: size,
                          child: Container(
                            decoration: BoxDecoration(
                              color: col,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3),
                                width: 1.2,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: label.isEmpty
                                ? null
                                : Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: size * 0.33,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                          ),
                        );
                      }).toList(),
                    ),
                  // Rain density overlay (yellow -> red gradient markers)
                  if (_showRain && _rainCells.isNotEmpty)
                    MarkerLayer(
                      markers: _rainCells.map((cell) {
                        final rawCol = _rainColorForDensity(cell.density);
                        final col = rawCol.withValues(
                          alpha: rawCol.a * _wxOpacity,
                        );
                        final label = _wxShowPercentLabels
                            ? (cell.density * 100).round().toString()
                            : '';
                        final size =
                            (28 + (_mapZoom.clamp(5.0, 13.0) - 5.0) * 1.5)
                                .clamp(20, 42)
                                .toDouble();
                        return Marker(
                          point: cell.pos,
                          width: size,
                          height: size,
                          child: Container(
                            decoration: BoxDecoration(
                              color: col,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.black.withValues(alpha: 0.35),
                                width: 1.2,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: label.isEmpty
                                ? null
                                : Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: size * 0.33,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black,
                                    ),
                                  ),
                          ),
                        );
                      }).toList(),
                    ),
                  // Wind overlay: arrows colored by speed (kts), rotated to wind coming-from direction
                  if (_showWind && _windCells.isNotEmpty)
                    MarkerLayer(
                      markers: _windCells.map((cell) {
                        final kts = cell.speedMs * 1.943844; // m/s -> knots
                        final baseCol = _windColorForSpeedKts(kts);
                        final col = baseCol.withValues(
                          alpha: baseCol.a * _wxOpacity,
                        );
                        final arrowSize =
                            (30 + (_mapZoom.clamp(5.0, 13.0) - 5.0) * 2)
                                .clamp(26, 52)
                                .toDouble();
                        // Estimate weather circle size (used for horizontal offset)
                        final wxSize =
                            (28 + (_mapZoom.clamp(5.0, 13.0) - 5.0) * 1.5)
                                .clamp(20, 42)
                                .toDouble();
                        const gap = 6.0; // pixels between circle and arrow
                        final hasWeather =
                            (_showClouds && _cloudCells.isNotEmpty) ||
                            (_showRain && _rainCells.isNotEmpty);
                        // Icons.navigation points north; rotate to wind FROM direction
                        final rotRad = cell.dirDeg * math.pi / 180.0;
                        if (!hasWeather) {
                          // Original centered arrow+label when no weather circles shown
                          return Marker(
                            point: cell.pos,
                            width: arrowSize,
                            height: arrowSize,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Transform.rotate(
                                  angle: rotRad,
                                  child: Icon(
                                    Icons.navigation,
                                    color: col,
                                    size: arrowSize * 0.75,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${kts.round()}kts',
                                    style: TextStyle(
                                      fontSize: arrowSize * 0.24,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        // When weather circles are shown, render the arrow to the right of the circle position
                        final totalWidth = wxSize + gap + arrowSize;
                        final totalHeight = math.max(
                          wxSize,
                          arrowSize + (arrowSize * 0.24) + 6,
                        );
                        return Marker(
                          point: cell.pos,
                          width: totalWidth,
                          height: totalHeight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Reserve space equal to the weather circle so the arrow appears "next to" it
                              SizedBox(width: wxSize, height: wxSize),
                              const SizedBox(width: gap),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Transform.rotate(
                                    angle: rotRad,
                                    child: Icon(
                                      Icons.navigation,
                                      color: col,
                                      size: arrowSize * 0.75,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.55,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '${kts.round()}kts',
                                      style: TextStyle(
                                        fontSize: arrowSize * 0.24,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  // Add airspace name labels at centroid
                  MarkerLayer(
                    markers: _airspacePerimeters
                        .asMap()
                        .entries
                        .where((entry) {
                          final cc =
                              (entry.value['countryCode'] ?? '') as String;
                          return (cc == 'CY' && _showCyAirspace) ||
                              (cc == 'GR' && _showGrAirspace) ||
                              (cc == 'IL' && _showIlAirspace);
                        })
                        .where(
                          (entry) =>
                              entry.value['name'] != null &&
                              (entry.value['perimeter'] as List).isNotEmpty,
                        )
                        .map((entry) {
                          final idx = entry.key;
                          final asp = entry.value;
                          final List<LatLng> pts =
                              asp['perimeter'] as List<LatLng>;
                          double lat = 0, lng = 0;
                          for (final pt in pts) {
                            lat += pt.latitude;
                            lng += pt.longitude;
                          }
                          lat /= pts.length;
                          lng /= pts.length;
                          final bool selected = _selectedAirspaceIdx == idx;
                          return Marker(
                            point: LatLng(lat, lng),
                            width: selected ? 140 : 90,
                            height: selected ? 36 : 22,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedAirspaceIdx = idx;
                                  _mapZoom = 13.0;
                                });
                              },
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Colors.transparent,
                                  border: Border.all(
                                    color: Colors.red,
                                    width: 2.0,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  asp['name'],
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold,
                                    fontSize: selected ? 13 : 10,
                                  ),
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          );
                        })
                        .toList(),
                  ),
                ],
                // Optional raster weather tiles disabled in favor of vector density markers
                // (Uncomment if you still want base tile overlays)
                // if (_showClouds) ...
                // if (_showRain) ...
                if (_showWind && _wxWindLevelFt == 0)
                  Opacity(
                    opacity: 0.8,
                    child: TileLayer(
                      urlTemplate:
                          'https://tile.openweathermap.org/map/wind_new/{z}/{x}/{y}.png?appid=$kOpenWeatherApiKey',
                    ),
                  ),
                if (_currentPosition != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _currentPosition!,
                        width: 30,
                        height: 30,
                        child: ColorFiltered(
                          colorFilter: _nvgMode
                              ? const ColorFilter.mode(
                                  Color(0xFF33AA33),
                                  BlendMode.modulate,
                                )
                              : const ColorFilter.mode(
                                  Colors.transparent,
                                  BlendMode.dst,
                                ),
                          child: _buildHelicopterMarker(),
                        ),
                      ),
                    ],
                  ),
                if (_flightStart != null &&
                    _flightEnd == null &&
                    _currentTrack.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _currentTrack,
                        color: Colors.greenAccent.withValues(alpha: 0.8),
                        strokeWidth: 4.0,
                      ),
                    ],
                  ),
                if (_selectedLogRoute != null && _selectedLogRoute!.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _selectedLogRoute!,
                        strokeWidth: 4,
                        color: Colors.lightGreenAccent.withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                // Preview search pattern (dashed)
                if (_previewPatternPoints.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _previewPatternPoints,
                        color: const Color(0xFFFF00FF),
                        strokeWidth: 3.0,
                        // Fallback dotted effect: reduce opacity & thinner width
                      ),
                    ],
                  ),
                // Persisted pattern overlays (each its own polyline)
                // Route polyline & numbered markers
                if (_routePoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _routePoints,
                        color: const Color(0xFFFF00FF),
                        strokeWidth: 4.0,
                      ),
                    ],
                  ),
                if (_routePoints.length >= 2)
                  MarkerLayer(markers: _buildRouteLegLabels()),
                if (_routePoints.isNotEmpty)
                  MarkerLayer(markers: _buildRouteMarkers()),
              ],
            ),
          ),
          // Live coordinates overlay while dragging a polygon vertex
          if (_vertexDragging && _vertexDragPos != null)
            Positioned(
              left: math.min(
                math.max(8.0, (_vertexDragLocalPos?.dx ?? 0) + 16),
                MediaQuery.of(context).size.width - 220,
              ),
              top: math.max(8.0, (_vertexDragLocalPos?.dy ?? 0) - 64),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.80),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orangeAccent),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 4),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _vertexDragIndex != null
                          ? 'Adjusting Vertex #$_vertexDragIndex'
                          : 'Adjusting Vertex',
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Lat: ${_toDms(_vertexDragPos!.latitude, isLat: true)}\nLon: ${_toDms(_vertexDragPos!.longitude, isLat: false)}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '(${_vertexDragPos!.latitude.toStringAsFixed(5)}, ${_vertexDragPos!.longitude.toStringAsFixed(5)})',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Location debug overlay (top-left) with permission button
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _nvgMode
                    ? (_locationError != null
                          ? const Color(0xFF4A1F1F).withValues(alpha: 0.95)
                          : (_currentPosition != null
                                ? const Color(
                                    0xFF0F3A1A,
                                  ).withValues(alpha: 0.85)
                                : const Color(
                                    0xFF3A3A12,
                                  ).withValues(alpha: 0.85)))
                    : (_locationError != null
                          ? Colors.red.withValues(alpha: 0.95)
                          : (_currentPosition != null
                                ? Colors.green.withValues(alpha: 0.90)
                                : Colors.orange.withValues(alpha: 0.90))),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _nvgMode ? const Color(0xFF33AA33) : Colors.white,
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _currentPosition != null
                            ? Icons.gps_fixed
                            : Icons.gps_off,
                        color: _nvgMode
                            ? const Color(0xFF6BFF6B)
                            : Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _locationDebugStatus,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  if (_locationError != null ||
                      (_locationPermission != null &&
                          (_locationPermission == LocationPermission.denied ||
                              _locationPermission ==
                                  LocationPermission.deniedForever))) ...[
                    const SizedBox(height: 6),
                    if (_locationError != null)
                      Text(
                        _locationError!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      Text(
                        _locationPermission == LocationPermission.deniedForever
                            ? 'Permission denied forever'
                            : 'Location permission not granted',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () async {
                        setState(() {
                          _locationDebugStatus = 'Requesting permission...';
                          _locationError = null;
                        });
                        var perm = await Geolocator.checkPermission();
                        if (perm == LocationPermission.denied) {
                          perm = await Geolocator.requestPermission();
                        }
                        if (perm == LocationPermission.deniedForever) {
                          setState(() {
                            _locationDebugStatus = 'Permission denied forever';
                            _locationError = 'Open Settings → Apps → AW139';
                          });
                          await Geolocator.openAppSettings();
                          return;
                        }
                        if (perm == LocationPermission.denied) {
                          setState(() {
                            _locationDebugStatus = 'Permission denied';
                            _locationError = 'Location access required';
                          });
                          return;
                        }
                        final servicesEnabled =
                            await Geolocator.isLocationServiceEnabled();
                        if (!servicesEnabled) {
                          setState(() {
                            _locationDebugStatus = 'GPS services disabled';
                            _locationError = 'Turn on device location';
                          });
                          await Geolocator.openLocationSettings();
                          return;
                        }
                        _initLocation();
                      },
                      icon: const Icon(Icons.location_on, size: 16),
                      label: const Text(
                        'GRANT LOCATION',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _nvgMode
                            ? const Color(0xFF255F25)
                            : Colors.white,
                        foregroundColor: _nvgMode
                            ? const Color(0xFF6BFF6B)
                            : Colors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ] else if (_currentPosition == null &&
                      _locationError == null &&
                      _locationPermission != null &&
                      (_locationPermission == LocationPermission.always ||
                          _locationPermission ==
                              LocationPermission.whileInUse)) ...[
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final ready = await _ensureLocationReady(
                          openSettingsIfNeeded: true,
                        );
                        if (ready) {
                          _initLocation();
                        }
                      },
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text(
                        'START TRACKING',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ],
                  if (_lastPositionUpdate != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Last: ${DateTime.now().difference(_lastPositionUpdate!).inSeconds}s ago',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_rulerActive && _rulerStart != null)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.yellowAccent),
                  ),
                  child: Builder(
                    builder: (_) {
                      String text;
                      if (_rulerEnd == null) {
                        text = 'Ruler: tap second point';
                      } else {
                        final distM = _geo.as(
                          LengthUnit.Meter,
                          _rulerStart!,
                          _rulerEnd!,
                        );
                        final distNm = distM / 1852.0;
                        final brg = _bearingDegrees(_rulerStart!, _rulerEnd!);
                        final recip = (brg + 180) % 360;
                        text =
                            '${distNm.toStringAsFixed(2)} nm  BRG ${_fmt3(brg)}° / R ${_fmt3(recip)}°';
                      }
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              text,
                              style: const TextStyle(
                                color: Colors.yellowAccent,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.fade,
                              softWrap: false,
                            ),
                          ),
                          if (_rulerEnd != null) ...[
                            const SizedBox(width: 12),
                            TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: Colors.blueGrey.shade700,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                              onPressed: _addRulerEndToRoute,
                              child: const Text(
                                'Add leg',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          // Top-left flight toggle button (T/O ⇄ LNDG)
          Positioned(
            top: 8,
            left: 8,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.black87,
                          foregroundColor:
                              (_flightStart != null && _flightEnd == null)
                              ? Colors.lightBlueAccent
                              : Colors.orangeAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: (_flightStart != null && _flightEnd == null)
                            ? _stopFlightTimer
                            : _startFlightTimer,
                        icon: Icon(
                          (_flightStart != null && _flightEnd == null)
                              ? Icons.flight_land
                              : Icons.flight_takeoff,
                          size: 18,
                        ),
                        label: Text(
                          (_flightStart != null && _flightEnd == null)
                              ? 'LNDG'
                              : 'T/O',
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.black87,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _openWarnSettings,
                        icon: const Icon(Icons.warning_amber_rounded, size: 18),
                        label: const Text('Warnings'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.black87,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _openInfoBarSettings,
                        icon: const Icon(Icons.info_outline, size: 18),
                        label: const Text('Info Bar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Top-right overlay menu (replaces inner AppBar menu)
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 4),
                    ],
                  ),
                  child: _buildOverlayMenu(),
                ),
              ),
            ),
          ),
          if (_showInfoBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: _nvgMode
                    ? const Color(0xFF0D1F0D).withValues(alpha: 0.95)
                    : Colors.black.withValues(alpha: 0.92),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Track moved to leftmost position for prominence
                    if (_infoShowTrk)
                      GestureDetector(
                        onLongPress: () => _toggleInfoItem('trk'),
                        child: _InfoItem(label: 'TRK', value: _formatTrack()),
                      ),
                    if (_infoShowEtaOrAgl)
                      GestureDetector(
                        onLongPress: () => _toggleInfoItem('etaagl'),
                        child: (_infoAglReplaceEte
                            ? _InfoItem(label: 'AGL', value: _formatAgl())
                            : _InfoItem(label: 'ETA', value: _formatEta())),
                      ),
                    if (_infoShowEte)
                      GestureDetector(
                        onLongPress: () => _toggleInfoItem('ete'),
                        child: _InfoItem(
                          label: 'ETE',
                          value: _remainingEte() != null
                              ? _fmtDuration(_remainingEte()!)
                              : '--',
                        ),
                      ),
                    // Replace ETE with remaining route ETE if available
                    //_InfoItem(label: 'ETE', value: '--'),
                    if (_infoShowDist)
                      GestureDetector(
                        onLongPress: () => _toggleInfoItem('dist'),
                        child: _InfoItem(
                          label: 'Dist',
                          value: _routePoints.length >= 2
                              ? '${_routeDistanceNm().toStringAsFixed(1)} nm'
                              : '--',
                        ),
                      ),
                    if (_infoShowAlt)
                      GestureDetector(
                        onTap: _openAltSettings,
                        onLongPress: () => _toggleInfoItem('alt'),
                        child: _InfoItem(
                          label: _altSource == _AltSource.gps
                              ? 'GPS ALT'
                              : 'BARO ALT',
                          value: _infoShowAglNextToAlt
                              ? '${_altitudeFeetString()} (${_formatAgl()})'
                              : _altitudeFeetString(),
                        ),
                      ),
                    if (_infoShowGs)
                      GestureDetector(
                        onLongPress: () => _toggleInfoItem('gs'),
                        child: _InfoItem(label: 'GS', value: _formatGs()),
                      ),
                    if (_infoShowFlight)
                      GestureDetector(
                        onLongPress: () => _toggleInfoItem('flight'),
                        child: _InfoItem(
                          label: 'Flight Time',
                          value: _formatFlightTime(),
                        ),
                      ),
                    if (_infoShowPos)
                      GestureDetector(
                        onTap: _saveCurrentPosAsMot,
                        onLongPress: () => _toggleInfoItem('pos'),
                        child: _InfoItem(
                          label: 'Pos',
                          value: _currentPosition != null
                              ? (_posDms
                                    ? '${_toDms(_currentPosition!.latitude, isLat: true)}, ${_toDms(_currentPosition!.longitude, isLat: false)}'
                                    : '${_currentPosition!.latitude.toStringAsFixed(5)}, ${_currentPosition!.longitude.toStringAsFixed(5)}')
                              : '--',
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _saveCurrentPosAsMot() {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Current position unavailable')),
      );
      return;
    }
    final now = DateTime.now();
    final name =
        'MOT ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final wp = _Waypoint(
      id: now.microsecondsSinceEpoch.toString(),
      name: name,
      lat: _currentPosition!.latitude,
      lon: _currentPosition!.longitude,
      altMeters: _currentAltitudeM,
      type: 'MOT',
      createdAt: now,
    );
    _addWaypoint(wp);
  }

  String _altitudeFeetString() {
    double? meters;
    if (_altSource == _AltSource.gps) {
      meters = _currentAltitudeM;
    } else {
      meters = _baroAltitudeM;
    }
    if (meters == null) return '--';
    return '${(meters * 3.28084).round()} ft';
  }

  // Helicopter map marker (simple silhouette with heading rotation if track-up enabled)
  Widget _buildHelicopterMarker() {
    final headingRad = _headingUp ? _currentHeadingDeg * math.pi / 180.0 : 0.0;
    // Increase marker scale in night/NVG for visibility
    double scale = 1.0;
    if (_nvgMode) {
      scale = 1.0 + 0.35 * _nvgIntensity.clamp(0.2, 1.0);
    } else if (_nightMode) {
      // Make helicopter larger in night mode for visibility
      scale = 1.5;
    }
    return Transform.rotate(
      angle: headingRad,
      child: CustomPaint(
        size: Size(42 * scale, 42 * scale),
        painter: _HelicopterPainter(
          nightMode: _nightMode,
          nvgMode: _nvgMode,
          nvgIntensity: _nvgIntensity,
          scale: scale,
        ),
      ),
    );
  }

  Widget _buildAltRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  void _openAltSettings() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final qnhCtl = TextEditingController(text: _qnhHpa.toStringAsFixed(1));
        double? gpsAltFt = _currentAltitudeM != null
            ? _currentAltitudeM! * 3.28084
            : null;
        double? baroAltFt = _baroAltitudeM != null
            ? _baroAltitudeM! * 3.28084
            : null;
        return StatefulBuilder(
          builder: (ctx, setSB) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 18,
                  right: 18,
                  top: 18,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Altitude / Pressure',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _altSource == _AltSource.gps
                                  ? Colors.blueAccent
                                  : const Color(0xFF2A2A2A),
                            ),
                            onPressed: () {
                              setSB(() => _altSource = _AltSource.gps);
                              _stopBarometer();
                              _saveAltSettings();
                            },
                            child: const Text('GPS'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _altSource == _AltSource.baro
                                  ? Colors.orangeAccent
                                  : const Color(0xFF2A2A2A),
                            ),
                            onPressed: () async {
                              setSB(() => _altSource = _AltSource.baro);
                              await _startBarometer();
                              _saveAltSettings();
                            },
                            child: const Text('BARO'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Live Data',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildAltRow(
                            'GPS Alt',
                            gpsAltFt != null ? '${gpsAltFt.round()} ft' : '--',
                          ),
                          _buildAltRow(
                            'Baro Alt',
                            baroAltFt != null
                                ? '${baroAltFt.round()} ft'
                                : '--',
                          ),
                          _buildAltRow(
                            'Pressure',
                            _baroPressureHpa != null
                                ? '${_baroPressureHpa!.toStringAsFixed(1)} hPa'
                                : '--',
                          ),
                          _buildAltRow(
                            'Source',
                            _altSource == _AltSource.gps ? 'GPS' : 'BARO',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'QNH',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 8),
                              Switch(
                                value: _qnhAuto,
                                onChanged: (v) => setSB(() => _qnhAuto = v),
                              ),
                              Text(_qnhAuto ? 'AUTO (STD)' : 'Manual'),
                            ],
                          ),
                          if (!_qnhAuto)
                            TextField(
                              controller: qnhCtl,
                              decoration: const InputDecoration(
                                labelText: 'QNH (hPa)',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                            ),
                          if (_altSource == _AltSource.baro)
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Text(
                                'Barometric altitude uses ICAO std formula relative to QNH.',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Close'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () {
                            if (!_qnhAuto) {
                              final v = double.tryParse(qnhCtl.text);
                              if (v != null && v > 800 && v < 1100) {
                                _qnhHpa = v;
                              }
                            } else {
                              _qnhHpa = 1013.25;
                            }
                            _recomputeBaroAltitude();
                            setState(() {});
                            _saveAltSettings();
                            Navigator.of(ctx).pop();
                          },
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openWarnSettings() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        final alt1Ctl = TextEditingController(text: _altWarn1Ft.toString());
        final alt2Ctl = TextEditingController(text: _altWarn2Ft.toString());
        final spdCtl = TextEditingController(
          text: _speedWarnKts.toStringAsFixed(0),
        );
        bool altOn = _altWarnsEnabled;
        bool spdOn = _speedWarnEnabled;
        bool ttsOn = _ttsEnabled;
        bool aglOn = _useAglForWarns;
        bool aglReplaceEte = _infoAglReplaceEte;
        // Voice alerts (merged here so Warnings lives next to the T/O button)
        bool pl = _powerLineVoiceAlert;
        bool rel = _voiceRelativeBearing;
        bool obst = _obstacleVoiceAlert;
        double cone = _obstacleConeDeg;
        double w1 = _obstacleWarn1Nm;
        double w2 = _obstacleWarn2Nm;
        int topFt = _obstacleTopBandFt;
        String? err;
        return StatefulBuilder(
          builder: (ctx, setSB) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Warning Settings',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Altitude warnings'),
                      value: altOn,
                      onChanged: (v) => setSB(() => altOn = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Speed warning'),
                      value: spdOn,
                      onChanged: (v) => setSB(() => spdOn = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Voice (TTS)'),
                      value: ttsOn,
                      onChanged: (v) => setSB(() => ttsOn = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Use AGL for warnings'),
                      subtitle: const Text(
                        'Requires internet to fetch terrain',
                      ),
                      value: aglOn,
                      onChanged: (v) => setSB(() => aglOn = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Replace ETA with AGL in info bar'),
                      subtitle: const Text('Shows AGL instead of ETE'),
                      value: aglReplaceEte,
                      onChanged: (v) => setSB(() => aglReplaceEte = v),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: alt1Ctl,
                            decoration: const InputDecoration(
                              labelText: 'Altitude 1 (ft)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: alt2Ctl,
                            decoration: const InputDecoration(
                              labelText: 'Altitude 2 (ft)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: false,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: spdCtl,
                      decoration: const InputDecoration(
                        labelText: 'Speed warn (kts)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: false,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Voice Alerts',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: pl,
                      onChanged: (v) => setSB(() => pl = v),
                      title: const Text(
                        'Power lines (live 1.0→0.0 nm every 0.2 nm)',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: rel,
                      onChanged: (v) => setSB(() => rel = v),
                      title: const Text(
                        'Use relative bearing wording (left/right/ahead)',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      value: obst,
                      onChanged: (v) => setSB(() => obst = v),
                      title: const Text(
                        'Obstacles',
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (obst) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0, bottom: 2.0),
                        child: Row(
                          children: [
                            const Text(
                              'Cone',
                              style: TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Slider(
                                min: 10,
                                max: 90,
                                divisions: 8,
                                label: '${cone.round()}°',
                                value: cone,
                                onChanged: (v) =>
                                    setSB(() => cone = v.roundToDouble()),
                              ),
                            ),
                            SizedBox(
                              width: 54,
                              child: Text(
                                '${cone.round()}°',
                                textAlign: TextAlign.end,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2.0, bottom: 2.0),
                        child: Row(
                          children: [
                            const Text(
                              'Warn 1',
                              style: TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Slider(
                                min: 0.3,
                                max: 2.0,
                                divisions: 17,
                                label: '${w1.toStringAsFixed(1)} nm',
                                value: w1,
                                onChanged: (v) => setSB(() {
                                  w1 = double.parse(v.toStringAsFixed(1));
                                  if (w1 < w2) w2 = w1;
                                }),
                              ),
                            ),
                            SizedBox(
                              width: 64,
                              child: Text(
                                '${w1.toStringAsFixed(1)} nm',
                                textAlign: TextAlign.end,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2.0, bottom: 2.0),
                        child: Row(
                          children: [
                            const Text(
                              'Warn 2',
                              style: TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Slider(
                                min: 0.2,
                                max: 1.5,
                                divisions: 13,
                                label: '${w2.toStringAsFixed(1)} nm',
                                value: w2,
                                onChanged: (v) => setSB(() {
                                  w2 = double.parse(v.toStringAsFixed(1));
                                  if (w2 > w1) w1 = w2;
                                }),
                              ),
                            ),
                            SizedBox(
                              width: 64,
                              child: Text(
                                '${w2.toStringAsFixed(1)} nm',
                                textAlign: TextAlign.end,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2.0, bottom: 6.0),
                        child: Row(
                          children: [
                            const Text(
                              '+/- Top',
                              style: TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Slider(
                                min: 100,
                                max: 1000,
                                divisions: 18,
                                label: '$topFt ft',
                                value: topFt.toDouble(),
                                onChanged: (v) =>
                                    setSB(() => topFt = v.round()),
                              ),
                            ),
                            SizedBox(
                              width: 64,
                              child: Text(
                                '$topFt ft',
                                textAlign: TextAlign.end,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (err != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        err!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () async {
                            final a1 = int.tryParse(alt1Ctl.text.trim());
                            final a2 = int.tryParse(alt2Ctl.text.trim());
                            final sk = double.tryParse(spdCtl.text.trim());
                            if (a1 == null || a1 <= 0) {
                              setSB(
                                () => err = 'Enter a valid Altitude 1 (ft).',
                              );
                              return;
                            }
                            if (a2 == null || a2 <= 0) {
                              setSB(
                                () => err = 'Enter a valid Altitude 2 (ft).',
                              );
                              return;
                            }
                            if (sk == null || sk <= 0) {
                              setSB(() => err = 'Enter a valid Speed (kts).');
                              return;
                            }
                            setState(() {
                              _altWarn1Ft = a1;
                              _altWarn2Ft = a2;
                              _speedWarnKts = sk;
                              _altWarnsEnabled = altOn;
                              _speedWarnEnabled = spdOn;
                              _ttsEnabled = ttsOn;
                              _useAglForWarns = aglOn;
                              _infoAglReplaceEte = aglReplaceEte;
                              _powerLineVoiceAlert = pl;
                              _voiceRelativeBearing = rel;
                              _obstacleVoiceAlert = obst;
                              _obstacleConeDeg = cone;
                              _obstacleWarn1Nm = w1;
                              _obstacleWarn2Nm = w2;
                              _obstacleTopBandFt = topFt;
                            });
                            try {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setInt('alt_warn1_ft', _altWarn1Ft);
                              await prefs.setInt('alt_warn2_ft', _altWarn2Ft);
                              await prefs.setDouble(
                                'speed_warn_kts',
                                _speedWarnKts,
                              );
                              await prefs.setBool(
                                'alt_warns_enabled',
                                _altWarnsEnabled,
                              );
                              await prefs.setBool(
                                'speed_warn_enabled',
                                _speedWarnEnabled,
                              );
                              await prefs.setBool('tts_enabled', _ttsEnabled);
                              await prefs.setBool(
                                'use_agl_for_warns',
                                _useAglForWarns,
                              );
                              await prefs.setBool(
                                'info_agl_replace_ete',
                                _infoAglReplaceEte,
                              );
                              // Persist voice alert settings (obstacles, relative bearing, power-lines)
                              await _saveObstacleVoiceSettings();
                            } catch (_) {}
                            if (mounted) Navigator.of(context).pop();
                          },
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadAltSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final src = prefs.getString('alt_source');
      if (src == 'baro') {
        _altSource = _AltSource.baro;
      } else if (src == 'gps')
        // ignore: curly_braces_in_flow_control_structures
        _altSource = _AltSource.gps;
      _qnhAuto = prefs.getBool('qnh_auto') ?? _qnhAuto;
      final qnh = prefs.getDouble('qnh_hpa');
      if (qnh != null && qnh > 800 && qnh < 1100) _qnhHpa = qnh;
      _recomputeBaroAltitude();
      if (mounted) setState(() {});
      // If BARO is selected on startup, begin listening to pressure
      if (_altSource == _AltSource.baro) {
        unawaited(_startBarometer());
      }
    } catch (_) {}
  }

  Future<void> _saveAltSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'alt_source',
        _altSource == _AltSource.baro ? 'baro' : 'gps',
      );
      await prefs.setBool('qnh_auto', _qnhAuto);
      await prefs.setDouble('qnh_hpa', _qnhHpa);
    } catch (_) {}
  }

  Future<void> _loadWarnSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _altWarn1Ft = prefs.getInt('alt_warn1_ft') ?? _altWarn1Ft;
      _altWarn2Ft = prefs.getInt('alt_warn2_ft') ?? _altWarn2Ft;
      _speedWarnKts = prefs.getDouble('speed_warn_kts') ?? _speedWarnKts;
      _altWarnsEnabled = prefs.getBool('alt_warns_enabled') ?? _altWarnsEnabled;
      _speedWarnEnabled =
          prefs.getBool('speed_warn_enabled') ?? _speedWarnEnabled;
      _ttsEnabled = prefs.getBool('tts_enabled') ?? _ttsEnabled;
      _useAglForWarns = prefs.getBool('use_agl_for_warns') ?? _useAglForWarns;
      _infoAglReplaceEte =
          prefs.getBool('info_agl_replace_ete') ?? _infoAglReplaceEte;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadInfoBarSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _infoShowTrk = prefs.getBool('info_show_trk') ?? _infoShowTrk;
      _infoShowEtaOrAgl =
          prefs.getBool('info_show_etaagl') ?? _infoShowEtaOrAgl;
      _infoShowEte = prefs.getBool('info_show_ete') ?? _infoShowEte;
      _infoShowDist = prefs.getBool('info_show_dist') ?? _infoShowDist;
      _infoShowAlt = prefs.getBool('info_show_alt') ?? _infoShowAlt;
      _infoShowFlight = prefs.getBool('info_show_flight') ?? _infoShowFlight;
      _infoShowPos = prefs.getBool('info_show_pos') ?? _infoShowPos;
      _infoShowGs = prefs.getBool('info_show_gs') ?? _infoShowGs;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _saveInfoBarSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('info_show_trk', _infoShowTrk);
      await prefs.setBool('info_show_etaagl', _infoShowEtaOrAgl);
      await prefs.setBool('info_show_ete', _infoShowEte);
      await prefs.setBool('info_show_dist', _infoShowDist);
      await prefs.setBool('info_show_alt', _infoShowAlt);
      await prefs.setBool('info_show_flight', _infoShowFlight);
      await prefs.setBool('info_show_pos', _infoShowPos);
      await prefs.setBool('info_show_gs', _infoShowGs);
      _infoShowAglNextToAlt =
          prefs.getBool('info_show_agl_next_to_alt') ?? _infoShowAglNextToAlt;
      await prefs.setBool('info_agl_replace_ete', _infoAglReplaceEte);
      await prefs.setBool('info_show_agl_next_to_alt', _infoShowAglNextToAlt);
    } catch (_) {}
  }

  Future<void> _loadObstacleVoiceSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _voiceRelativeBearing =
          prefs.getBool('voice_relative_bearing') ?? _voiceRelativeBearing;
      _powerLineVoiceAlert =
          prefs.getBool('pl_voice_enabled') ?? _powerLineVoiceAlert;
      _obstacleVoiceAlert =
          prefs.getBool('obst_voice_enabled') ?? _obstacleVoiceAlert;
      _obstacleConeDeg = prefs.getDouble('obst_cone_deg') ?? _obstacleConeDeg;
      _obstacleWarn1Nm = prefs.getDouble('obst_warn1_nm') ?? _obstacleWarn1Nm;
      _obstacleWarn2Nm = prefs.getDouble('obst_warn2_nm') ?? _obstacleWarn2Nm;
      _obstacleTopBandFt =
          prefs.getInt('obst_top_band_ft') ?? _obstacleTopBandFt;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _saveObstacleVoiceSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('voice_relative_bearing', _voiceRelativeBearing);
      await prefs.setBool('pl_voice_enabled', _powerLineVoiceAlert);
      await prefs.setBool('obst_voice_enabled', _obstacleVoiceAlert);
      await prefs.setDouble('obst_cone_deg', _obstacleConeDeg);
      await prefs.setDouble('obst_warn1_nm', _obstacleWarn1Nm);
      await prefs.setDouble('obst_warn2_nm', _obstacleWarn2Nm);
      await prefs.setInt('obst_top_band_ft', _obstacleTopBandFt);
    } catch (_) {}
  }

  void _openInfoBarSettings() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        bool sTrk = _infoShowTrk;
        bool sEtaAgl = _infoShowEtaOrAgl;
        bool sEte = _infoShowEte;
        bool sDist = _infoShowDist;
        bool sAlt = _infoShowAlt;
        bool sFlight = _infoShowFlight;
        bool sPos = _infoShowPos;
        bool sGs = _infoShowGs;
        bool aglReplace = _infoAglReplaceEte;
        return StatefulBuilder(
          builder: (ctx, setSB) => SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Info Bar Settings',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show TRK'),
                    value: sTrk,
                    onChanged: (v) => setSB(() => sTrk = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show ETA / AGL slot'),
                    subtitle: const Text('Toggle which appears below'),
                    value: sEtaAgl,
                    onChanged: (v) => setSB(() => sEtaAgl = v),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12.0),
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show AGL instead of ETA'),
                      value: aglReplace,
                      onChanged: (v) => setSB(() => aglReplace = v),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show ETE'),
                    value: sEte,
                    onChanged: (v) => setSB(() => sEte = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show Distance'),
                    value: sDist,
                    onChanged: (v) => setSB(() => sDist = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show Altitude'),
                    value: sAlt,
                    onChanged: (v) => setSB(() => sAlt = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show Ground Speed (GS)'),
                    value: sGs,
                    onChanged: (v) => setSB(() => sGs = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show Flight Time'),
                    value: sFlight,
                    onChanged: (v) => setSB(() => sFlight = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show Position'),
                    value: sPos,
                    onChanged: (v) => setSB(() => sPos = v),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          setState(() {
                            _infoShowTrk = sTrk;
                            _infoShowEtaOrAgl = sEtaAgl;
                            _infoShowEte = sEte;
                            _infoShowDist = sDist;
                            _infoShowAlt = sAlt;
                            _infoShowFlight = sFlight;
                            _infoShowPos = sPos;
                            _infoShowGs = sGs;
                            _infoAglReplaceEte = aglReplace;
                          });
                          await _saveInfoBarSettings();
                          if (mounted) Navigator.of(context).pop();
                        },
                        child: const Text('Apply'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _recomputeBaroAltitude() {
    if (_baroPressureHpa == null) {
      _baroAltitudeM = null;
      return;
    }
    // Simple ICAO standard atmosphere approximation: h = 44330*(1 - (P/QNH)^(0.1903))
    final ratio = _baroPressureHpa! / _qnhHpa;
    _baroAltitudeM = 44330.0 * (1 - math.pow(ratio, 0.1903));
  }

  Future<void> _startBarometer() async {
    try {
      await _baroSub?.cancel();
      _baroSub = _pressureChannel.receiveBroadcastStream().listen(
        (dynamic e) {
          double? p;
          if (e is num) {
            final v = e.toDouble();
            if (v > 100 && v < 1100) {
              p = v; // treat as hPa
            } else if (v > 10000 && v < 110000) {
              p = v / 100.0; // Pa -> hPa
            }
          } else if (e is Map) {
            final raw = e['pressure'] ?? e['hpa'] ?? e['hectopascals'];
            if (raw is num) p = raw.toDouble();
          }
          if (p != null && p.isFinite && p > 100 && p < 1100) {
            _baroPressureHpa = p;
            _recomputeBaroAltitude();
            if (mounted) setState(() {});
          }
        },
        onError: (_) {
          _baroPressureHpa = null;
          _baroAltitudeM = null;
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Barometer start failed: $e');
    }
  }

  void _stopBarometer() {
    _baroSub?.cancel();
    _baroSub = null;
  }

  // Ground elevation helpers for AGL calculations
  void _ensureGroundElevation(LatLng pos) async {
    if (!_useAglForWarns || _elevFetchInFlight) return;
    final now = DateTime.now();
    // If recent failures occurred, avoid retrying too frequently
    if (_groundElevFailedAt != null &&
        now.difference(_groundElevFailedAt!).inSeconds < _elevFailCooldownSec) {
      return;
    }
    bool needRefresh = false;
    if (_groundElevPos == null || _groundElevFetchedAt == null) {
      needRefresh = true;
    } else {
      final movedM = _geo.as(LengthUnit.Meter, _groundElevPos!, pos);
      if (movedM > 300) needRefresh = true;
      if (now.difference(_groundElevFetchedAt!).inSeconds > 60) {
        needRefresh = true;
      }
    }
    if (!needRefresh) return;
    _elevFetchInFlight = true;
    try {
      final m = await _fetchGroundElevation(pos);
      if (m != null && mounted) {
        setState(() {
          _groundElevM = m;
          _groundElevPos = pos;
          _groundElevFetchedAt = now;
          _groundElevFailedAt = null;
        });
      } else {
        // Failed to fetch elevation — set failure timestamp and notify user (rate-limited)
        _groundElevFailedAt = now;
        if (mounted) {
          final last = _lastElevWarnAt;
          if (last == null || now.difference(last).inSeconds > 60) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Elevation service unavailable — using MSL (AGL temporarily disabled)',
                ),
                duration: Duration(seconds: 3),
              ),
            );
            _lastElevWarnAt = now;
          }
        }
      }
    } finally {
      _elevFetchInFlight = false;
    }
  }

  Future<double?> _fetchGroundElevation(LatLng pos) async {
    try {
      final uri = Uri.parse(
        'https://api.open-elevation.com/api/v1/lookup?locations='
        '${pos.latitude},${pos.longitude}',
      );
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final results = data['results'];
        if (results is List && results.isNotEmpty) {
          final elev = (results[0]['elevation'] as num?)?.toDouble();
          if (elev != null && elev.isFinite) return elev;
        }
      }
    } catch (_) {}
    return null;
  }

  // Fetch a small grid of OpenWeather current conditions around the map center
  // and populate vector overlays for clouds and rain using density-based colors.
  Future<void> _refreshWeatherOverlays() async {
    final center = _currentPosition ?? _initialCenter;
    // Rate limit to avoid accidental spamming
    final now = DateTime.now();
    if (_lastWxFetch != null && now.difference(_lastWxFetch!).inSeconds < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please wait a moment before refreshing again'),
        ),
      );
      return;
    }

    final n = _wxGridSide.clamp(3, 9);
    final samples = n * n;
    if (samples > 81) {
      // safety cap
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Grid too dense; capping to 9x9')),
      );
    }
    final radiusKm = _wxRadiusKm.clamp(10.0, 500.0);
    final latRad = center.latitude * math.pi / 180.0;
    final kmPerDegLat = 111.32;
    final kmPerDegLon = math.max(1e-6, 111.32 * math.cos(latRad));
    // Skip refresh if parameters unchanged and movement is tiny (<5km) within 20s
    if (_lastWxCenter != null &&
        _lastWxRadiusKm == radiusKm &&
        _lastWxGridSide == n &&
        _lastWxWindLevelFt == _wxWindLevelFt &&
        _lastWxFetch != null &&
        now.difference(_lastWxFetch!).inSeconds < 20) {
      final movedMeters = _geo.as(LengthUnit.Meter, _lastWxCenter!, center);
      if (movedMeters < 5000) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('WX unchanged (center moved <5 km).')),
        );
        return;
      }
    }

    final cellsCloud = <_WeatherCell>[];
    final cellsRain = <_WeatherCell>[];
    final futures = <Future<void>>[];
    final cellsWind = <_WindCell>[];
    for (int yi = 0; yi < n; yi++) {
      final fy = n == 1 ? 0.0 : (yi / (n - 1)) * 2.0 - 1.0; // -1..1
      for (int xi = 0; xi < n; xi++) {
        final fx = n == 1 ? 0.0 : (xi / (n - 1)) * 2.0 - 1.0; // -1..1
        final dLatDeg = (fy * radiusKm) / kmPerDegLat;
        final dLonDeg = (fx * radiusKm) / kmPerDegLon;
        final lat = (center.latitude + dLatDeg).clamp(-89.9, 89.9);
        final lon = (center.longitude + dLonDeg).clamp(-179.9, 179.9);
        futures.add(() async {
          try {
            // For now, always fetch surface winds from OpenWeather. If a winds-aloft
            // provider is configured in the future, branch here based on _wxWindLevelFt.
            final uri = Uri.parse(
              'https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=$kOpenWeatherApiKey&units=metric',
            );
            final res = await http.get(uri);
            if (res.statusCode == 200) {
              final data = jsonDecode(res.body) as Map<String, dynamic>;
              final clouds =
                  ((data['clouds'] as Map?)?['all'] as num?)?.toDouble() ??
                  0.0; // 0..100
              final rainMm =
                  ((data['rain'] as Map?)?['1h'] as num?)?.toDouble() ??
                  0.0; // mm in last 1h
              final cloudDensity = (clouds / 100.0).clamp(0.0, 1.0);
              final rainDensity = (rainMm / 10.0).clamp(0.0, 1.0); // soft cap
              final pos = LatLng(lat, lon);
              // Collect thread-safely via setState later; here local lists, with simple lock via microtask ordering
              cellsCloud.add(_WeatherCell(pos, cloudDensity));
              if (rainDensity > 0) {
                cellsRain.add(_WeatherCell(pos, rainDensity));
              }
              double spMs = 0.0;
              double dir = 0.0;
              if (_wxWindLevelFt > 0) {
                final aloft = await _fetchWindAloftAt(
                  lat: lat,
                  lon: lon,
                  feetLevel: _wxWindLevelFt,
                );
                if (aloft != null) {
                  spMs = aloft['speedMs'] ?? 0.0;
                  dir = aloft['dirDeg'] ?? 0.0;
                }
              }
              if (spMs == 0.0) {
                final wind = data['wind'] as Map?;
                spMs = (wind?['speed'] as num?)?.toDouble() ?? 0.0;
                dir = (wind?['deg'] as num?)?.toDouble() ?? 0.0;
              }
              if (spMs > 0) cellsWind.add(_WindCell(pos, spMs, dir));
            }
          } catch (_) {
            // ignore
          }
        }());
      }
    }
    await Future.wait(futures);
    _lastWxFetch = now;
    _lastWxCenter = center;
    _lastWxRadiusKm = radiusKm;
    _lastWxGridSide = n;
    _lastWxWindLevelFt = _wxWindLevelFt;
    if (!mounted) return;
    setState(() {
      _cloudCells
        ..clear()
        ..addAll(cellsCloud);
      _rainCells
        ..clear()
        ..addAll(cellsRain);
      _windCells
        ..clear()
        ..addAll(cellsWind);
      if (cellsCloud.isNotEmpty) _showClouds = true;
      if (cellsRain.isNotEmpty) _showRain = true;
      if (cellsWind.isNotEmpty) _showWind = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'WX updated: ${cellsCloud.length} cloud, ${cellsRain.length} rain, ${cellsWind.length} wind (~${(radiusKm).round()} km, ${n}x$n)',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatAgl() {
    // Prefer current altitude from selected source
    final metersSrc = _altSource == _AltSource.gps
        ? _currentAltitudeM
        : _baroAltitudeM;
    if (metersSrc == null) return '--';
    double? aglM;
    if (_groundElevM != null) {
      aglM = metersSrc - _groundElevM!;
    } else {
      // If no terrain yet, opportunistically schedule fetch; show placeholder
      final p = _currentPosition;
      if (p != null) {
        // fire-and-forget; UI will update when fetch completes
        _ensureGroundElevation(p);
      }
      return '--';
    }
    final aglFt = (aglM * 3.28084).clamp(-5000.0, 200000.0);
    if (!aglFt.isFinite) return '--';
    final v = aglFt.round();
    return '$v ft';
  }

  String _formatGs() {
    final kts = _currentGpsSpeedKts;
    if (kts == null || !kts.isFinite) return '--';
    return '${kts.round()} kts';
  }

  void _toggleInfoItem(String key) {
    String label = key;
    setState(() {
      switch (key) {
        case 'trk':
          _infoShowTrk = !_infoShowTrk;
          label = 'TRK';
          break;
        case 'etaagl':
          _infoShowEtaOrAgl = !_infoShowEtaOrAgl;
          label = 'ETA/AGL';
          break;
        case 'ete':
          _infoShowEte = !_infoShowEte;
          label = 'ETE';
          break;
        case 'dist':
          _infoShowDist = !_infoShowDist;
          label = 'Dist';
          break;
        case 'alt':
          _infoShowAlt = !_infoShowAlt;
          label = 'Alt';
          break;
        case 'gs':
          _infoShowGs = !_infoShowGs;
          label = 'GS';
          break;
        case 'flight':
          _infoShowFlight = !_infoShowFlight;
          label = 'Flight Time';
          break;
        case 'pos':
          _infoShowPos = !_infoShowPos;
          label = 'Pos';
          break;
        default:
          break;
      }
    });
    // Persist and notify
    unawaited(_saveInfoBarSettings());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label ${_infoLabelState(key) ? 'shown' : 'hidden'}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  bool _infoLabelState(String key) {
    switch (key) {
      case 'trk':
        return _infoShowTrk;
      case 'etaagl':
        return _infoShowEtaOrAgl;
      case 'ete':
        return _infoShowEte;
      case 'dist':
        return _infoShowDist;
      case 'alt':
        return _infoShowAlt;
      case 'gs':
        return _infoShowGs;
      case 'flight':
        return _infoShowFlight;
      case 'pos':
        return _infoShowPos;
      default:
        return false;
    }
  }

  // Long-press context menu: Save Waypoint, Add to Route, Direct To
  void _showLongPressMenu(LatLng latLng) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.touch_app, color: Colors.white70),
                    const SizedBox(width: 8),
                    Text(
                      'Map Action',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                Text(
                  'Lat: ${_toDms(latLng.latitude, isLat: true)}\nLon: ${_toDms(latLng.longitude, isLat: false)}',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _showSaveWaypointDialog(latLng);
                      },
                      icon: const Icon(Icons.bookmark_add),
                      label: const Text('Save Waypoint'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurpleAccent.shade200,
                      ),
                      onPressed: () {
                        setState(() => _routePoints.add(latLng));
                        Navigator.of(ctx).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Point added to route')),
                        );
                      },
                      icon: const Icon(Icons.alt_route),
                      label: const Text('Add to Route'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.pinkAccent.shade200,
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _directTo(latLng);
                      },
                      icon: const Icon(Icons.center_focus_strong),
                      label: const Text('Direct To'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_routePoints.isNotEmpty)
                  Text(
                    'Route points: ${_routePoints.length}',
                    style: const TextStyle(color: Colors.white54),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadWaypoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('waypoints');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final list = decoded
            .map((e) => _Waypoint.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
        if (!mounted) return;
        setState(() {
          _waypoints
            ..clear()
            ..addAll(list);
          _sortWaypoints();
        });
      }
    } catch (_) {}
  }

  // === Saved Areas persistence ===
  Future<void> _loadSavedAreas() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('saved_areas');
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => _SavedArea.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() {
        _savedAreas.clear();
        _savedAreas.addAll(list);
      });
    } catch (_) {}
  }

  Future<void> _loadImportedLayers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('imported_layers');
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List<dynamic>)
          .map(
            (e) => _ImportedLayer.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _importedLayers
          ..clear()
          ..addAll(list);
      });
    } catch (_) {}
  }

  Future<void> _persistImportedLayers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _importedLayers.map((e) => e.toJson()).toList();
      await prefs.setString('imported_layers', jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _importLayerFromFile() async {
    final typeGroup = XTypeGroup(
      label: 'Map Layers',
      extensions: const ['gpx', 'kml', 'csv'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final nameDefault = file.name.replaceAll(
      RegExp(r'\.(gpx|kml)$', caseSensitive: false),
      '',
    );
    final bytes = await file.readAsBytes();
    if (!mounted) return; // avoid using context after async gap
    final text = String.fromCharCodes(bytes);
    final lower = file.name.toLowerCase();
    _ImportedLayer? layer;
    try {
      if (lower.endsWith('.gpx')) {
        layer = _parseGpxToLayer(text, nameDefault);
      } else if (lower.endsWith('.kml')) {
        layer = _parseKmlToLayer(text, nameDefault);
      } else if (lower.endsWith('.csv')) {
        layer = _parseCsvToLayer(text, nameDefault);
      }
    } catch (_) {}
    if (layer == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to import layer')));
      return;
    }
    // Optional rename
    final nameCtl = TextEditingController(text: layer.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Layer'),
        content: TextField(
          controller: nameCtl,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return; // ensure widget still alive before using context/state
    }
    if (ok != true) return;
    final newLayer = _ImportedLayer(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: nameCtl.text.trim().isEmpty ? layer.name : nameCtl.text.trim(),
      polylines: layer.polylines,
      polygons: layer.polygons,
      points: layer.points,
      visible: true,
      useAsPowerLines: false,
      strokeColorHex: 'FF000000',
      fillColorHex: '33000000',
      createdAt: DateTime.now(),
    );
    setState(() => _importedLayers.add(newLayer));
    await _persistImportedLayers();
    if (!mounted) return;
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Imported "${newLayer.name}"')));
  }

  _ImportedLayer? _parseGpxToLayer(String gpx, String name) {
    try {
      final doc = xml.XmlDocument.parse(gpx);
      final polylines = <List<LatLng>>[];
      final polygons = <List<LatLng>>[]; // GPX has no polygons by spec
      final points = <LatLng>[];
      for (final trk in doc.findAllElements('trk')) {
        for (final seg in trk.findAllElements('trkseg')) {
          final pts = <LatLng>[];
          for (final pt in seg.findAllElements('trkpt')) {
            final lat = double.tryParse(pt.getAttribute('lat') ?? '');
            final lon = double.tryParse(pt.getAttribute('lon') ?? '');
            if (lat != null && lon != null) pts.add(LatLng(lat, lon));
          }
          if (pts.length >= 2) polylines.add(pts);
        }
      }
      for (final rte in doc.findAllElements('rte')) {
        final pts = <LatLng>[];
        for (final pt in rte.findAllElements('rtept')) {
          final lat = double.tryParse(pt.getAttribute('lat') ?? '');
          final lon = double.tryParse(pt.getAttribute('lon') ?? '');
          if (lat != null && lon != null) pts.add(LatLng(lat, lon));
        }
        if (pts.length >= 2) polylines.add(pts);
      }
      for (final w in doc.findAllElements('wpt')) {
        final lat = double.tryParse(w.getAttribute('lat') ?? '');
        final lon = double.tryParse(w.getAttribute('lon') ?? '');
        if (lat != null && lon != null) points.add(LatLng(lat, lon));
      }
      if (polylines.isEmpty && points.isEmpty) return null;
      return _ImportedLayer(
        id: 'tmp',
        name: name,
        polylines: polylines,
        polygons: polygons,
        points: points,
        visible: true,
        useAsPowerLines: name.toLowerCase().contains('power'),
        createdAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  _ImportedLayer? _parseKmlToLayer(String kml, String name) {
    try {
      final doc = xml.XmlDocument.parse(kml);
      final polylines = <List<LatLng>>[];
      final polygons = <List<LatLng>>[];
      final points = <LatLng>[];
      List<LatLng> parseCoords(String text) {
        final parts = text.trim().split(RegExp(r'\s+'));
        final pts = <LatLng>[];
        for (final p in parts) {
          final xyz = p.split(',');
          if (xyz.length >= 2) {
            final lon = double.tryParse(xyz[0]);
            final lat = double.tryParse(xyz[1]);
            if (lat != null && lon != null) pts.add(LatLng(lat, lon));
          }
        }
        return pts;
      }

      for (final pm in doc.findAllElements('Placemark')) {
        // Points
        for (final p in pm.findAllElements('Point')) {
          final coords = p
              .findAllElements('coordinates')
              .map((e) => e.innerText)
              .firstWhere((e) => e.isNotEmpty, orElse: () => '');
          if (coords.isNotEmpty) {
            final pts = parseCoords(coords);
            if (pts.isNotEmpty) points.add(pts.first);
          }
        }
        // LineStrings
        for (final ls in pm.findAllElements('LineString')) {
          final coords = ls
              .findAllElements('coordinates')
              .map((e) => e.innerText)
              .firstWhere((e) => e.isNotEmpty, orElse: () => '');
          final pts = parseCoords(coords);
          if (pts.length >= 2) polylines.add(pts);
        }
        // Polygons: use outerBoundaryIs -> LinearRing
        for (final pg in pm.findAllElements('Polygon')) {
          final outer = pg
              .findAllElements('outerBoundaryIs')
              .expand((e) => e.findAllElements('LinearRing'));
          for (final ring in outer) {
            final coords = ring
                .findAllElements('coordinates')
                .map((e) => e.innerText)
                .firstWhere((e) => e.isNotEmpty, orElse: () => '');
            final pts = parseCoords(coords);
            if (pts.length >= 3) {
              if (pts.first != pts.last) pts.add(pts.first);
              polygons.add(pts);
            }
          }
        }
      }
      if (polylines.isEmpty && polygons.isEmpty && points.isEmpty) return null;
      return _ImportedLayer(
        id: 'tmp',
        name: name,
        polylines: polylines,
        polygons: polygons,
        points: points,
        visible: true,
        useAsPowerLines: name.toLowerCase().contains('power'),
        createdAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  _ImportedLayer? _parseCsvToLayer(String csv, String name) {
    try {
      final lines = csv
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (lines.isEmpty) return null;
      // detect separator (comma or semicolon)
      final first = lines.first;
      final sep = first.contains(',') ? ',' : (first.contains(';') ? ';' : ',');
      final headers = first
          .split(sep)
          .map((s) => s.trim().toLowerCase())
          .toList();
      final latIdx = headers.indexWhere((h) => h.contains('lat'));
      final lonIdx = headers.indexWhere(
        (h) => h.contains('lon') || h.contains('lng') || h.contains('long'),
      );
      // final nameIdx = headers.indexWhere((h) => h.contains('name') || h.contains('label') || h.contains('desc'));
      final points = <LatLng>[];
      // If header contains lat/lon, parse rows after header; otherwise try simple two-column CSV
      final start = (latIdx >= 0 && lonIdx >= 0) ? 1 : 0;
      for (int i = start; i < lines.length; i++) {
        final row = lines[i];
        final cols = row
            .split(sep)
            .map((s) => s.trim().replaceAll(RegExp(r'^"|"$'), ''))
            .toList();
        double? lat;
        double? lon;
        if (latIdx >= 0 &&
            lonIdx >= 0 &&
            cols.length > math.max(latIdx, lonIdx)) {
          lat = double.tryParse(cols[latIdx]);
          lon = double.tryParse(cols[lonIdx]);
        } else if (cols.length >= 2) {
          lat = double.tryParse(cols[0]);
          lon = double.tryParse(cols[1]);
        }
        if (lat != null && lon != null) points.add(LatLng(lat, lon));
      }
      if (points.isEmpty) return null;
      // Treat as a polyline if more than one point
      final polylines = points.length >= 2 ? [points] : <List<LatLng>>[];
      final pts = points.length == 1 ? points : <LatLng>[];
      return _ImportedLayer(
        id: 'tmp',
        name: name,
        polylines: polylines,
        polygons: const [],
        points: pts,
        visible: true,
        useAsPowerLines: name.toLowerCase().contains('power'),
        createdAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _openImportsManager() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, controller) {
          return StatefulBuilder(
            builder: (inner, setSB) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      const Text(
                        'Imports',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () async {
                          await _importLayerFromFile();
                          setSB(() {});
                        },
                        icon: const Icon(
                          Icons.download,
                          color: Colors.orangeAccent,
                        ),
                        label: const Text(
                          'Import GPX/KML/CSV',
                          style: TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.white24),
                Expanded(
                  child: _importedLayers.isEmpty
                      ? const Center(
                          child: Text(
                            'No imported layers',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : ListView.builder(
                          controller: controller,
                          itemCount: _importedLayers.length,
                          itemBuilder: (_, i) {
                            final l = _importedLayers[i];
                            final polys = l.polygons.length;
                            final lines = l.polylines.length;
                            final pts = l.points.length;
                            return CheckboxListTile(
                              value: l.visible,
                              onChanged: (v) async {
                                setState(() {
                                  _importedLayers[i] = _ImportedLayer(
                                    id: l.id,
                                    name: l.name,
                                    polylines: l.polylines,
                                    polygons: l.polygons,
                                    points: l.points,
                                    visible: v ?? true,
                                    useAsPowerLines: l.useAsPowerLines,
                                    createdAt: l.createdAt,
                                  );
                                });
                                setSB(() {});
                                await _persistImportedLayers();
                              },
                              title: Text(
                                l.name,
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                '$lines lines • $polys polygons • $pts points${l.useAsPowerLines ? ' • power-lines' : ''}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                              secondary: PopupMenuButton<String>(
                                tooltip: 'Actions',
                                icon: const Icon(
                                  Icons.more_vert,
                                  color: Colors.white70,
                                ),
                                onSelected: (v) async {
                                  if (v == 'center') {
                                    Navigator.of(ctx).pop();
                                    _centerOnImportedLayer(l);
                                  } else if (v == 'rename') {
                                    final ctl = TextEditingController(
                                      text: l.name,
                                    );
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (d) => AlertDialog(
                                        title: const Text('Rename Layer'),
                                        content: TextField(
                                          controller: ctl,
                                          decoration: const InputDecoration(
                                            labelText: 'Name',
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(d, false),
                                            child: const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(d, true),
                                            child: const Text('Save'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      setState(() {
                                        _importedLayers[i] = _ImportedLayer(
                                          id: l.id,
                                          name: ctl.text.trim().isEmpty
                                              ? l.name
                                              : ctl.text.trim(),
                                          polylines: l.polylines,
                                          polygons: l.polygons,
                                          points: l.points,
                                          visible: l.visible,
                                          useAsPowerLines: l.useAsPowerLines,
                                          createdAt: l.createdAt,
                                        );
                                      });
                                      setSB(() {});
                                      await _persistImportedLayers();
                                    }
                                  } else if (v == 'recolor') {
                                    Color stroke = _colorFromHex(
                                      l.strokeColorHex,
                                    );
                                    Color fill = _colorFromHex(l.fillColorHex);
                                    String toHex(Color c) => c
                                        .toARGB32()
                                        .toRadixString(16)
                                        .padLeft(8, '0')
                                        .toUpperCase();
                                    final strokeCtl = TextEditingController(
                                      text: toHex(stroke),
                                    );
                                    final fillCtl = TextEditingController(
                                      text: toHex(fill),
                                    );
                                    String? err;
                                    Color? parseHexStrict(String s) {
                                      final cleaned = s
                                          .trim()
                                          .replaceAll('#', '')
                                          .toUpperCase();
                                      final re = RegExp(
                                        r'^[0-9A-F]{6}([0-9A-F]{2})?$',
                                      );
                                      if (!re.hasMatch(cleaned)) return null;
                                      final hex = cleaned.length == 6
                                          ? 'FF$cleaned'
                                          : cleaned;
                                      final v = int.tryParse(hex, radix: 16);
                                      if (v == null) return null;
                                      return Color(v);
                                    }

                                    final presets = <Color>[
                                      Colors.black,
                                      Colors.redAccent,
                                      Colors.orangeAccent,
                                      Colors.yellowAccent,
                                      Colors.greenAccent,
                                      Colors.cyanAccent,
                                      Colors.lightBlueAccent,
                                      Colors.blueAccent,
                                      Colors.purpleAccent,
                                      Colors.pinkAccent,
                                    ];
                                    await showDialog<void>(
                                      context: context,
                                      builder: (dctx) {
                                        return StatefulBuilder(
                                          builder: (dctx, setDSB) => AlertDialog(
                                            title: const Text('Recolor Layer'),
                                            content: SingleChildScrollView(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  const Text(
                                                    'Stroke/Fill (hex) — accepts RRGGBB or AARRGGBB',
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: TextField(
                                                          controller: strokeCtl,
                                                          decoration:
                                                              const InputDecoration(
                                                                labelText:
                                                                    'Stroke hex',
                                                                isDense: true,
                                                              ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Container(
                                                        width: 26,
                                                        height: 26,
                                                        decoration:
                                                            BoxDecoration(
                                                              color: stroke,
                                                              shape: BoxShape
                                                                  .circle,
                                                              border: Border.all(
                                                                color: Colors
                                                                    .white24,
                                                              ),
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: TextField(
                                                          controller: fillCtl,
                                                          decoration:
                                                              const InputDecoration(
                                                                labelText:
                                                                    'Fill hex',
                                                                isDense: true,
                                                              ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Container(
                                                        width: 26,
                                                        height: 26,
                                                        decoration:
                                                            BoxDecoration(
                                                              color: fill,
                                                              shape: BoxShape
                                                                  .circle,
                                                              border: Border.all(
                                                                color: Colors
                                                                    .white24,
                                                              ),
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 6),
                                                  TextButton.icon(
                                                    onPressed: () {
                                                      fill = stroke.withValues(
                                                        alpha: 0.18,
                                                      );
                                                      fillCtl.text = toHex(
                                                        fill,
                                                      );
                                                      setDSB(() {});
                                                    },
                                                    icon: const Icon(
                                                      Icons.auto_fix_high,
                                                      color:
                                                          Colors.orangeAccent,
                                                    ),
                                                    label: const Text(
                                                      'Derive fill from stroke',
                                                      style: TextStyle(
                                                        color:
                                                            Colors.orangeAccent,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  const Text('Quick presets'),
                                                  const SizedBox(height: 4),
                                                  Wrap(
                                                    spacing: 8,
                                                    runSpacing: 8,
                                                    children: presets.map((c) {
                                                      final selected =
                                                          c.toARGB32() ==
                                                          stroke.toARGB32();
                                                      return GestureDetector(
                                                        onTap: () {
                                                          stroke = c;
                                                          strokeCtl.text =
                                                              toHex(stroke);
                                                          setDSB(() {});
                                                        },
                                                        child: Container(
                                                          width: 32,
                                                          height: 32,
                                                          decoration: BoxDecoration(
                                                            color: c,
                                                            shape:
                                                                BoxShape.circle,
                                                            border: Border.all(
                                                              color: selected
                                                                  ? Colors.white
                                                                  : Colors
                                                                        .black54,
                                                              width: selected
                                                                  ? 3
                                                                  : 1,
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    }).toList(),
                                                  ),
                                                  if (err != null) ...[
                                                    const SizedBox(height: 8),
                                                    Text(
                                                      err!,
                                                      style: const TextStyle(
                                                        color: Colors.redAccent,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(dctx).pop(),
                                                child: const Text('Close'),
                                              ),
                                              FilledButton(
                                                onPressed: () {
                                                  final sCol = parseHexStrict(
                                                    strokeCtl.text,
                                                  );
                                                  final fCol = parseHexStrict(
                                                    fillCtl.text,
                                                  );
                                                  if (sCol == null) {
                                                    setDSB(
                                                      () => err =
                                                          'Invalid stroke hex. Use RRGGBB or AARRGGBB.',
                                                    );
                                                    return;
                                                  }
                                                  if (fCol == null) {
                                                    setDSB(
                                                      () => err =
                                                          'Invalid fill hex. Use RRGGBB or AARRGGBB.',
                                                    );
                                                    return;
                                                  }
                                                  stroke = sCol;
                                                  fill = fCol;
                                                  Navigator.of(dctx).pop();
                                                  setState(() {
                                                    _importedLayers[i] =
                                                        _ImportedLayer(
                                                          id: l.id,
                                                          name: l.name,
                                                          polylines:
                                                              l.polylines,
                                                          polygons: l.polygons,
                                                          points: l.points,
                                                          visible: l.visible,
                                                          strokeColorHex: toHex(
                                                            stroke,
                                                          ),
                                                          fillColorHex: toHex(
                                                            fill,
                                                          ),
                                                          useAsPowerLines:
                                                              l.useAsPowerLines,
                                                          createdAt:
                                                              l.createdAt,
                                                        );
                                                  });
                                                  setSB(() {});
                                                  _persistImportedLayers();
                                                },
                                                child: const Text('Apply'),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    );
                                  } else if (v == 'toggle_pl') {
                                    setState(() {
                                      _importedLayers[i] = _ImportedLayer(
                                        id: l.id,
                                        name: l.name,
                                        polylines: l.polylines,
                                        polygons: l.polygons,
                                        points: l.points,
                                        visible: l.visible,
                                        useAsPowerLines: !l.useAsPowerLines,
                                        strokeColorHex: l.strokeColorHex,
                                        fillColorHex: l.fillColorHex,
                                        createdAt: l.createdAt,
                                      );
                                    });
                                    setSB(() {});
                                    await _persistImportedLayers();
                                  } else if (v == 'delete') {
                                    final ok = await _confirmDeleteDialog(
                                      'Delete imported layer',
                                      'Delete layer "${l.name}"?',
                                    );
                                    if (!ok) return;
                                    setState(() {
                                      _importedLayers.removeAt(i);
                                    });
                                    setSB(() {});
                                    await _persistImportedLayers();
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'center',
                                    child: Text('Center on Layer'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'recolor',
                                    child: Text('Recolor'),
                                  ),
                                  PopupMenuItem(
                                    value: 'toggle_pl',
                                    child: Text(
                                      l.useAsPowerLines
                                          ? 'Stop using for power-line warnings'
                                          : 'Use for power-line warnings',
                                    ),
                                  ),
                                  const PopupMenuDivider(),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _centerOnImportedLayer(_ImportedLayer l) {
    final pts = <LatLng>[];
    for (final seg in l.polylines) {
      pts.addAll(seg);
    }
    for (final poly in l.polygons) {
      pts.addAll(poly);
    }
    pts.addAll(l.points);
    if (pts.isEmpty) return;
    double minLat = pts.first.latitude,
        maxLat = pts.first.latitude,
        minLon = pts.first.longitude,
        maxLon = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    final center = LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
    _mapController.move(center, 11.0);
  }

  Future<void> _persistSavedAreas() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _savedAreas.map((e) => e.toJson()).toList();
      await prefs.setString('saved_areas', jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _createCircleAreaPrompt() async {
    final defaultCenter = _currentPosition ?? _initialCenter;
    final nameCtl = TextEditingController(
      text:
          'Circle ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    final radiusCtl = TextEditingController(text: '1.0');
    final latCtl = TextEditingController(
      text: _toDms(defaultCenter.latitude, isLat: true),
    );
    final lonCtl = TextEditingController(
      text: _toDms(defaultCenter.longitude, isLat: false),
    );
    Color stroke = Colors.redAccent;
    Color fill = Colors.redAccent.withValues(alpha: 0.35);
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Circle Area'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: latCtl,
              decoration: const InputDecoration(
                labelText: 'Latitude (DMS or decimal)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: lonCtl,
              decoration: const InputDecoration(
                labelText: 'Longitude (DMS or decimal)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: radiusCtl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Radius (nm)'),
            ),
            const SizedBox(height: 12),
            const Text('Color', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: presets.map((c) {
                final selected = c.toARGB32() == stroke.toARGB32();
                return GestureDetector(
                  onTap: () {
                    stroke = c;
                    fill = c.withValues(alpha: 0.35);
                    (ctx as Element).markNeedsBuild();
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.black54,
                        width: selected ? 3 : 1,
                      ),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 3),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (!mounted) return; // safe after async dialog
      final lat = _parseDms(latCtl.text, isLat: true);
      final lon = _parseDms(lonCtl.text, isLat: false);
      if (lat == null || lon == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter valid coordinates (DMS or decimal)'),
          ),
        );
        return;
      }
      final center = LatLng(lat, lon);
      final rNm = double.tryParse(radiusCtl.text.trim());
      if (rNm == null || rNm <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Enter a valid radius')));
        return;
      }
      // Generate circle polygon (72 points ~ 5° spacing)
      final pts = <LatLng>[];
      for (int ang = 0; ang < 360; ang += 5) {
        pts.add(_offsetNM(center, rNm, ang.toDouble()));
      }
      // Close loop
      if (pts.isNotEmpty) pts.add(pts.first);
      final area = _SavedArea(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: nameCtl.text.trim().isEmpty ? 'Circle' : nameCtl.text.trim(),
        type: 'circle',
        centerLat: center.latitude,
        centerLon: center.longitude,
        radiusNm: rNm,
        points: pts,
        createdAt: DateTime.now(),
        strokeColorHex: colorToHex(stroke),
        fillColorHex: colorToHex(fill),
      );
      setState(() => _savedAreas.add(area));
      await _persistSavedAreas();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Created area "${area.name}"')));
    }
  }

  void _togglePolygonDraft() {
    setState(() {
      if (_draftPolygonMode) {
        _draftPolygonMode = false;
        _draftPolygonPoints.clear();
      } else {
        _draftPolygonMode = true;
        _draftPolygonPoints.clear();
        // Ensure mutually exclusive with line drafting
        if (_draftLineMode) {
          _draftLineMode = false;
          _draftLinePoints.clear();
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _draftPolygonMode
              ? 'Polygon draft: tap at least 3 points'
              : 'Draft cancelled',
        ),
      ),
    );
  }

  void _toggleLineDraft() {
    setState(() {
      if (_draftLineMode) {
        _draftLineMode = false;
        _draftLinePoints.clear();
      } else {
        _draftLineMode = true;
        _draftLinePoints.clear();
        // Ensure mutually exclusive with polygon drafting
        if (_draftPolygonMode) {
          _draftPolygonMode = false;
          _draftPolygonPoints.clear();
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _draftLineMode
              ? 'Line draft: tap at least 2 points'
              : 'Draft cancelled',
        ),
      ),
    );
  }

  Future<void> _finishPolygonDraft() async {
    if (_draftPolygonPoints.length < 3) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add at least 3 points')));
      return;
    }
    final nameCtl = TextEditingController(
      text:
          'Area ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    Color stroke = Colors.redAccent;
    Color fill = Colors.redAccent.withValues(alpha: 0.35);
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Polygon'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            const Text('Color', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: presets.map((c) {
                final selected = c.toARGB32() == stroke.toARGB32();
                return GestureDetector(
                  onTap: () {
                    stroke = c;
                    fill = c.withValues(alpha: 0.35);
                    (ctx as Element).markNeedsBuild();
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.black54,
                        width: selected ? 3 : 1,
                      ),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 3),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final pts = List<LatLng>.from(_draftPolygonPoints);
      if (pts.first != pts.last) pts.add(pts.first);
      final area = _SavedArea(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: nameCtl.text.trim().isEmpty ? 'Area' : nameCtl.text.trim(),
        type: 'polygon',
        centerLat: null,
        centerLon: null,
        radiusNm: null,
        points: pts,
        createdAt: DateTime.now(),
        strokeColorHex: colorToHex(stroke),
        fillColorHex: colorToHex(fill),
      );
      setState(() {
        _savedAreas.add(area);
        _draftPolygonMode = false;
        _draftPolygonPoints.clear();
      });
      await _persistSavedAreas();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved area "${area.name}"')));
    }
  }

  Future<void> _finishLineDraft() async {
    if (_draftLinePoints.length < 2) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add at least 2 points')));
      return;
    }
    final nameCtl = TextEditingController(
      text:
          'Line ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    Color stroke = Colors.orangeAccent;
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
      Colors.black,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Line'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            const Text('Color', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: presets.map((c) {
                final selected = c.toARGB32() == stroke.toARGB32();
                return GestureDetector(
                  onTap: () {
                    stroke = c;
                    (ctx as Element).markNeedsBuild();
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.black54,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final area = _SavedArea(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: nameCtl.text.trim().isEmpty ? 'Line' : nameCtl.text.trim(),
        type: 'line',
        centerLat: null,
        centerLon: null,
        radiusNm: null,
        points: List<LatLng>.from(_draftLinePoints),
        createdAt: DateTime.now(),
        strokeColorHex: colorToHex(stroke),
        fillColorHex: '00000000',
      );
      setState(() {
        _savedAreas.add(area);
        _draftLineMode = false;
        _draftLinePoints.clear();
      });
      await _persistSavedAreas();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved line "${area.name}"')));
    }
  }

  Future<void> _createLineManualPrompt() async {
    final nameCtl = TextEditingController(
      text:
          'Line ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    final coordsCtl = TextEditingController(
      text:
          '34°56\'12"N 33°37\'06"E\n34°56\'30"N 33°37\'40"E\n34°56\'05"N 33°37\'55"E',
    );
    Color stroke = Colors.orangeAccent;
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
      Colors.black,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    String? error;
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSB) => AlertDialog(
          title: const Text('Manual Line'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: coordsCtl,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText:
                        'Coordinates (one per line: LAT LON in DMS or decimal) ',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Color',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: presets.map((c) {
                    final selected = c.toARGB32() == stroke.toARGB32();
                    return GestureDetector(
                      onTap: () {
                        stroke = c;
                        setSB(() {});
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.black54,
                            width: selected ? 3 : 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final lines = coordsCtl.text
                    .split(RegExp(r'\r?\n'))
                    .where((l) => l.trim().isNotEmpty)
                    .toList();
                final pts = <LatLng>[];
                for (final line in lines) {
                  final parts = line
                      .trim()
                      .split(RegExp(r'[;,]'))
                      .expand((e) => e.split(RegExp(r'\s+')))
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList();
                  double? lat;
                  double? lon;
                  for (int s = 1; s < parts.length; s++) {
                    lat = _parseDms(parts.take(s).join(' '), isLat: true);
                    lon = _parseDms(parts.skip(s).join(' '), isLat: false);
                    if (lat != null && lon != null) break;
                  }
                  if (lat == null || lon == null) {
                    setSB(() => error = 'Failed to parse line: "$line"');
                    return;
                  }
                  pts.add(LatLng(lat, lon));
                }
                if (pts.length < 2) {
                  setSB(() => error = 'Need at least 2 points');
                  return;
                }
                Navigator.of(ctx).pop(true);
                final area = _SavedArea(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  name: nameCtl.text.trim().isEmpty
                      ? 'Line'
                      : nameCtl.text.trim(),
                  type: 'line',
                  centerLat: null,
                  centerLon: null,
                  radiusNm: null,
                  points: pts,
                  createdAt: DateTime.now(),
                  strokeColorHex: colorToHex(stroke),
                  fillColorHex: '00000000',
                );
                setState(() {
                  _savedAreas.add(area);
                });
                _persistSavedAreas();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Created line "${area.name}"')),
                );
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editLineAreaPrompt(_SavedArea area, int index) async {
    final ptsLines = area.points
        .map(
          (p) =>
              '${_toDms(p.latitude, isLat: true)} ${_toDms(p.longitude, isLat: false)}',
        )
        .join('\n');
    final nameCtl = TextEditingController(text: area.name);
    final coordsCtl = TextEditingController(text: ptsLines);
    Color stroke = _colorFromHex(area.strokeColorHex);
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
      Colors.black,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    String? error;
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSB) => AlertDialog(
          title: const Text('Edit Line'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: coordsCtl,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Coordinates (editable) LAT LON per line',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Color',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: presets.map((c) {
                    final selected = c.toARGB32() == stroke.toARGB32();
                    return GestureDetector(
                      onTap: () {
                        stroke = c;
                        setSB(() {});
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.black54,
                            width: selected ? 3 : 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final lines = coordsCtl.text
                    .split(RegExp(r'\r?\n'))
                    .where((l) => l.trim().isNotEmpty)
                    .toList();
                final pts = <LatLng>[];
                for (final line in lines) {
                  final parts = line
                      .trim()
                      .split(RegExp(r'[;,]'))
                      .expand((e) => e.split(RegExp(r'\s+')))
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList();
                  double? lat;
                  double? lon;
                  for (int s = 1; s < parts.length; s++) {
                    lat = _parseDms(parts.take(s).join(' '), isLat: true);
                    lon = _parseDms(parts.skip(s).join(' '), isLat: false);
                    if (lat != null && lon != null) break;
                  }
                  if (lat == null || lon == null) {
                    setSB(() => error = 'Bad line: "$line"');
                    return;
                  }
                  pts.add(LatLng(lat, lon));
                }
                if (pts.length < 2) {
                  setSB(() => error = 'Need at least 2 points');
                  return;
                }
                Navigator.of(ctx).pop(true);
                setState(() {
                  _savedAreas[index] = _SavedArea(
                    id: area.id,
                    name: nameCtl.text.trim().isEmpty
                        ? area.name
                        : nameCtl.text.trim(),
                    type: 'line',
                    centerLat: null,
                    centerLon: null,
                    radiusNm: null,
                    points: pts,
                    createdAt: area.createdAt,
                    strokeColorHex: colorToHex(stroke),
                    fillColorHex: '00000000',
                  );
                });
                _persistSavedAreas();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Line updated')));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAreasManager() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, controller) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Areas',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_draftLineMode)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          children: const [
                            Icon(
                              Icons.info_outline,
                              color: Colors.orangeAccent,
                              size: 18,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Line draft active — tap Finish to save',
                              style: TextStyle(color: Colors.orangeAccent),
                            ),
                          ],
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_savedAreas.isNotEmpty)
                          TextButton.icon(
                            onPressed: _exportAreasKml,
                            icon: const Icon(
                              Icons.file_present,
                              color: Colors.lightBlueAccent,
                            ),
                            label: const Text(
                              'Export KML',
                              style: TextStyle(color: Colors.lightBlueAccent),
                            ),
                          ),
                        if (_savedAreas.isNotEmpty)
                          TextButton.icon(
                            onPressed: _exportAreasGpx,
                            icon: const Icon(
                              Icons.file_present,
                              color: Colors.greenAccent,
                            ),
                            label: const Text(
                              'Export GPX',
                              style: TextStyle(color: Colors.greenAccent),
                            ),
                          ),
                        if (!_draftPolygonMode && !_draftLineMode)
                          TextButton.icon(
                            onPressed: _createCircleAreaPrompt,
                            icon: const Icon(
                              Icons.circle_outlined,
                              color: Colors.orangeAccent,
                            ),
                            label: const Text(
                              'New Circle',
                              style: TextStyle(color: Colors.orangeAccent),
                            ),
                          ),
                        TextButton.icon(
                          onPressed: _draftPolygonMode
                              ? _finishPolygonDraft
                              : _togglePolygonDraft,
                          icon: Icon(
                            _draftPolygonMode
                                ? Icons.check
                                : Icons.hexagon_outlined,
                            color: Colors.orangeAccent,
                          ),
                          label: Text(
                            _draftPolygonMode ? 'Finish' : 'New Polygon',
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _createPolygonManualPrompt,
                          icon: const Icon(
                            Icons.edit_location_alt,
                            color: Colors.orangeAccent,
                          ),
                          label: const Text(
                            'Manual Polygon',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _draftLineMode
                              ? _finishLineDraft
                              : _toggleLineDraft,
                          icon: Icon(
                            _draftLineMode ? Icons.check : Icons.timeline,
                            color: Colors.orangeAccent,
                          ),
                          label: Text(
                            _draftLineMode ? 'Finish' : 'New Line',
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _createLineManualPrompt,
                          icon: const Icon(
                            Icons.border_style,
                            color: Colors.orangeAccent,
                          ),
                          label: const Text(
                            'Manual Line',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              Expanded(
                child: _savedAreas.isEmpty
                    ? const Center(
                        child: Text(
                          'No areas saved',
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : ListView.builder(
                        controller: controller,
                        itemCount: _savedAreas.length,
                        itemBuilder: (_, i) {
                          final a = _savedAreas[i];
                          final summary = a.type == 'circle'
                              ? 'Circle • ${a.radiusNm?.toStringAsFixed(1)} nm'
                              : (a.type == 'line'
                                    ? 'Line • ${a.points.length} pts'
                                    : 'Polygon • ${a.points.length} pts');
                          return ListTile(
                            title: Text(
                              a.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              summary,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              // Center map on center or first point
                              if (a.centerLat != null && a.centerLon != null) {
                                _mapController.move(
                                  LatLng(a.centerLat!, a.centerLon!),
                                  12.0,
                                );
                              } else if (a.points.isNotEmpty) {
                                _mapController.move(a.points.first, 12.0);
                              }
                            },
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Actions',
                              icon: const Icon(
                                Icons.more_vert,
                                color: Colors.white70,
                              ),
                              onSelected: (v) async {
                                if (v == 'rename') {
                                  final ctl = TextEditingController(
                                    text: a.name,
                                  );
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (dctx) => AlertDialog(
                                      title: const Text('Rename Area'),
                                      content: TextField(
                                        controller: ctl,
                                        decoration: const InputDecoration(
                                          labelText: 'Name',
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(dctx).pop(false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.of(dctx).pop(true),
                                          child: const Text('Save'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    setState(() {
                                      _savedAreas[i] = _SavedArea(
                                        id: a.id,
                                        name: ctl.text.trim().isEmpty
                                            ? a.name
                                            : ctl.text.trim(),
                                        type: a.type,
                                        centerLat: a.centerLat,
                                        centerLon: a.centerLon,
                                        radiusNm: a.radiusNm,
                                        points: a.points,
                                        createdAt: a.createdAt,
                                      );
                                    });
                                    await _persistSavedAreas();
                                  }
                                } else if (v == 'recolor') {
                                  Color stroke = _colorFromHex(
                                    a.strokeColorHex,
                                  );
                                  Color fill = _colorFromHex(a.fillColorHex);
                                  final presets = <Color>[
                                    Colors.redAccent,
                                    Colors.orangeAccent,
                                    Colors.yellowAccent,
                                    Colors.greenAccent,
                                    Colors.cyanAccent,
                                    Colors.lightBlueAccent,
                                    Colors.blueAccent,
                                    Colors.purpleAccent,
                                    Colors.pinkAccent,
                                    Colors.black,
                                  ];
                                  await showDialog<void>(
                                    context: context,
                                    builder: (dctx) {
                                      return AlertDialog(
                                        title: const Text('Recolor Area'),
                                        content: Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: presets.map((c) {
                                            final selected =
                                                c.toARGB32() ==
                                                stroke.toARGB32();
                                            return GestureDetector(
                                              onTap: () {
                                                stroke = c;
                                                fill = c.withValues(
                                                  alpha: 0.35,
                                                );
                                                (dctx as Element)
                                                    .markNeedsBuild();
                                              },
                                              child: Container(
                                                width: 32,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color: c,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: selected
                                                        ? Colors.white
                                                        : Colors.black54,
                                                    width: selected ? 3 : 1,
                                                  ),
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(dctx).pop(),
                                            child: const Text('Close'),
                                          ),
                                          FilledButton(
                                            onPressed: () {
                                              Navigator.of(dctx).pop();
                                              String toHex(Color c) => c
                                                  .toARGB32()
                                                  .toRadixString(16)
                                                  .padLeft(8, '0')
                                                  .toUpperCase();
                                              setState(() {
                                                _savedAreas[i] = _SavedArea(
                                                  id: a.id,
                                                  name: a.name,
                                                  type: a.type,
                                                  centerLat: a.centerLat,
                                                  centerLon: a.centerLon,
                                                  radiusNm: a.radiusNm,
                                                  points: a.points,
                                                  createdAt: a.createdAt,
                                                  strokeColorHex: toHex(stroke),
                                                  fillColorHex: toHex(fill),
                                                );
                                              });
                                              _persistSavedAreas();
                                            },
                                            child: const Text('Apply'),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                                } else if (v == 'edit') {
                                  if (a.type == 'circle') {
                                    await _editCircleAreaPrompt(a, i);
                                  } else if (a.type == 'polygon') {
                                    await _editPolygonAreaPrompt(a, i);
                                  } else if (a.type == 'line') {
                                    await _editLineAreaPrompt(a, i);
                                  }
                                } else if (v == 'delete') {
                                  final ok = await _confirmDeleteDialog(
                                    'Delete area',
                                    'Delete area "${a.name}"?',
                                  );
                                  if (!ok) return;
                                  setState(() {
                                    _savedAreas.removeAt(i);
                                  });
                                  await _persistSavedAreas();
                                } else if (v == 'vertex_edit') {
                                  if (a.type == 'polygon') {
                                    setState(() {
                                      _vertexEditMode = true;
                                      _vertexEditAreaIndex = i;
                                      _vertexEditPoints
                                        ..clear()
                                        ..addAll(a.points);
                                      _vertexEditSelectedVertex = null;
                                    });
                                    Navigator.of(ctx).pop();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Vertex edit: tap a handle, then tap new map location',
                                        ),
                                        duration: const Duration(seconds: 4),
                                      ),
                                    );
                                  }
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Text('Rename'),
                                ),
                                const PopupMenuItem(
                                  value: 'recolor',
                                  child: Text('Recolor'),
                                ),
                                if (a.type == 'circle')
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit (center/radius)'),
                                  )
                                else
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit (points/colors)'),
                                  ),
                                if (a.type == 'polygon')
                                  const PopupMenuItem(
                                    value: 'vertex_edit',
                                    child: Text('Edit Vertices (map)'),
                                  ),
                                const PopupMenuDivider(),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  // === Areas export ===
  Future<void> _exportAreasKml() async {
    if (_savedAreas.isEmpty) return;
    // KML with one Document and multiple Placemarks (Polygons or LineStrings)
    String colorKml(String aarrggbb) {
      // KML uses aabbggrr
      final s = aarrggbb.replaceAll('#', '');
      if (s.length != 8) return '7d0000ff';
      final aa = s.substring(0, 2);
      final rr = s.substring(2, 4);
      final gg = s.substring(4, 6);
      final bb = s.substring(6, 8);
      return '$aa$bb$gg$rr';
    }

    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
    sb.writeln('<Document>');
    for (final a in _savedAreas) {
      final fill = colorKml(a.fillColorHex);
      final stroke = colorKml(a.strokeColorHex);
      sb.writeln('<Placemark>');
      sb.writeln('<name>${_xmlEscape(a.name)}</name>');
      sb.writeln('<Style>');
      sb.writeln(
        '<LineStyle><color>$stroke</color><width>2</width></LineStyle>',
      );
      sb.writeln('<PolyStyle><color>$fill</color></PolyStyle>');
      sb.writeln('</Style>');
      if (a.type == 'line') {
        sb.writeln('<LineString><tessellate>1</tessellate><coordinates>');
        for (final p in a.points) {
          sb.writeln('${p.longitude},${p.latitude},0');
        }
        sb.writeln('</coordinates></LineString>');
      } else {
        sb.writeln('<Polygon><outerBoundaryIs><LinearRing><coordinates>');
        for (final p in a.points) {
          sb.writeln('${p.longitude},${p.latitude},0');
        }
        sb.writeln('</coordinates></LinearRing></outerBoundaryIs></Polygon>');
      }
      sb.writeln('</Placemark>');
    }
    sb.writeln('</Document></kml>');
    final name = 'areas_${DateTime.now().millisecondsSinceEpoch}.kml';
    try {
      final x = XFile.fromData(
        const Utf8Encoder().convert(sb.toString()),
        name: name,
        mimeType: 'application/vnd.google-earth.kml+xml',
      );
      await x.saveTo(name);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('KML exported: $name')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('KML export failed: $e')));
      }
    }
  }

  Future<void> _exportAreasGpx() async {
    if (_savedAreas.isEmpty) return;
    // Represent each area as a track made of its polygon ring
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln(
      '<gpx version="1.1" creator="AW139Cruise" xmlns="http://www.topografix.com/GPX/1/1">',
    );
    for (final a in _savedAreas) {
      sb.writeln('<trk>');
      sb.writeln('<name>${_xmlEscape(a.name)}</name>');
      sb.writeln('<trkseg>');
      for (final p in a.points) {
        sb.writeln('<trkpt lat="${p.latitude}" lon="${p.longitude}"></trkpt>');
      }
      sb.writeln('</trkseg>');
      sb.writeln('</trk>');
    }
    sb.writeln('</gpx>');
    final name = 'areas_${DateTime.now().millisecondsSinceEpoch}.gpx';
    try {
      final x = XFile.fromData(
        const Utf8Encoder().convert(sb.toString()),
        name: name,
        mimeType: 'application/gpx+xml',
      );
      await x.saveTo(name);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('GPX exported: $name')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('GPX export failed: $e')));
      }
    }
  }

  Future<void> _editCircleAreaPrompt(_SavedArea area, int index) async {
    // Prefill with existing center/radius; fall back to centroid of points if needed
    final center = (area.centerLat != null && area.centerLon != null)
        ? LatLng(area.centerLat!, area.centerLon!)
        : (area.points.isNotEmpty
              ? area.points.first
              : (_currentPosition ?? _initialCenter));
    final nameCtl = TextEditingController(text: area.name);
    final radiusCtl = TextEditingController(
      text: (area.radiusNm ?? 1.0).toStringAsFixed(2),
    );
    final latCtl = TextEditingController(
      text: _toDms(center.latitude, isLat: true),
    );
    final lonCtl = TextEditingController(
      text: _toDms(center.longitude, isLat: false),
    );
    Color stroke = _colorFromHex(area.strokeColorHex);
    Color fill = _colorFromHex(area.fillColorHex);
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Circle Area'),
        content: SingleChildScrollView(
          padding: const EdgeInsets.only(right: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: latCtl,
                decoration: const InputDecoration(
                  labelText: 'Latitude (DMS or decimal)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: lonCtl,
                decoration: const InputDecoration(
                  labelText: 'Longitude (DMS or decimal)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: radiusCtl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Radius (nm)'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Color',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: presets.map((c) {
                  final selected = c.toARGB32() == stroke.toARGB32();
                  return GestureDetector(
                    onTap: () {
                      stroke = c;
                      fill = c.withValues(alpha: 0.35);
                      (ctx as Element).markNeedsBuild();
                    },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? Colors.white : Colors.black54,
                          width: selected ? 3 : 1,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final lat = _parseDms(latCtl.text, isLat: true);
      final lon = _parseDms(lonCtl.text, isLat: false);
      final rNm = double.tryParse(radiusCtl.text.trim());
      if (lat == null || lon == null || rNm == null || rNm <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid inputs')));
        return;
      }
      final newCenter = LatLng(lat, lon);
      // Rebuild circle points
      final pts = <LatLng>[];
      for (int ang = 0; ang < 360; ang += 5) {
        pts.add(_offsetNM(newCenter, rNm, ang.toDouble()));
      }
      if (pts.isNotEmpty) pts.add(pts.first);
      setState(() {
        _savedAreas[index] = _SavedArea(
          id: area.id,
          name: nameCtl.text.trim().isEmpty ? area.name : nameCtl.text.trim(),
          type: 'circle',
          centerLat: newCenter.latitude,
          centerLon: newCenter.longitude,
          radiusNm: rNm,
          points: pts,
          createdAt: area.createdAt,
          strokeColorHex: colorToHex(stroke),
          fillColorHex: colorToHex(fill),
        );
      });
      await _persistSavedAreas();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Circle updated')));
    }
  }

  Future<void> _createPolygonManualPrompt() async {
    final nameCtl = TextEditingController(
      text:
          'Area ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    final coordsCtl = TextEditingController(
      text:
          '34°56\'12"N 33°37\'06"E\n34°56\'30"N 33°37\'40"E\n34°56\'05"N 33°37\'55"E',
    );
    Color stroke = Colors.orangeAccent;
    Color fill = Colors.orangeAccent.withValues(alpha: 0.35);
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    String? error;
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSB) => AlertDialog(
          title: const Text('Manual Polygon'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: coordsCtl,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText:
                        'Coordinates (one per line: LAT LON in DMS or decimal) ',
                    hintText:
                        'Example:\n34 56 12 N 33 37 06 E\n34.9367 33.6183\n34°56\'05"N 33°37\'55"E',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Color',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: presets.map((c) {
                    final selected = c.toARGB32() == stroke.toARGB32();
                    return GestureDetector(
                      onTap: () {
                        stroke = c;
                        fill = c.withValues(alpha: 0.35);
                        setSB(() {});
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.black54,
                            width: selected ? 3 : 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                // Parse coordinates
                final lines = coordsCtl.text
                    .split(RegExp(r'\r?\n'))
                    .where((l) => l.trim().isNotEmpty)
                    .toList();
                final pts = <LatLng>[];
                for (final line in lines) {
                  final parts = line
                      .trim()
                      .split(RegExp(r'[;,]'))
                      .expand((e) => e.split(RegExp(r'\s+')))
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList();
                  // Attempt to split into lat sequence and lon sequence by detecting hemisphere letters or count
                  // Strategy: scan tokens until we can parse a latitude; remaining tokens parse as longitude.
                  String latStr = '';
                  String lonStr = '';
                  // Simple heuristic: find midpoint to split
                  final mid = (parts.length / 2).floor();
                  latStr = parts.take(mid).join(' ');
                  lonStr = parts.skip(mid).join(' ');
                  double? lat = _parseDms(latStr, isLat: true);
                  double? lon = _parseDms(lonStr, isLat: false);
                  // Fallback: try all possible splits
                  if (lat == null || lon == null) {
                    for (int s = 1; s < parts.length; s++) {
                      latStr = parts.take(s).join(' ');
                      lonStr = parts.skip(s).join(' ');
                      lat = _parseDms(latStr, isLat: true);
                      lon = _parseDms(lonStr, isLat: false);
                      if (lat != null && lon != null) break;
                    }
                  }
                  if (lat == null || lon == null) {
                    setSB(() => error = 'Failed to parse line: "$line"');
                    return; // abort save
                  }
                  pts.add(LatLng(lat, lon));
                }
                if (pts.length < 3) {
                  setSB(() => error = 'Need at least 3 valid points');
                  return;
                }
                Navigator.of(ctx).pop(true);
                // Close handled after dialog result
                final closed = List<LatLng>.from(pts);
                if (closed.first != closed.last) closed.add(closed.first);
                final area = _SavedArea(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  name: nameCtl.text.trim().isEmpty
                      ? 'Area'
                      : nameCtl.text.trim(),
                  type: 'polygon',
                  centerLat: null,
                  centerLon: null,
                  radiusNm: null,
                  points: closed,
                  createdAt: DateTime.now(),
                  strokeColorHex: colorToHex(stroke),
                  fillColorHex: colorToHex(fill),
                );
                setState(() {
                  _savedAreas.add(area);
                });
                _persistSavedAreas();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Created area "${area.name}"')),
                );
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPolygonAreaPrompt(_SavedArea area, int index) async {
    // Represent existing points in multi-line editable text
    final ptsLines = area.points
        .where(
          (p) => area.points.isEmpty || p != area.points.last,
        ) // skip duplicate closing point
        .map(
          (p) =>
              '${_toDms(p.latitude, isLat: true)} ${_toDms(p.longitude, isLat: false)}',
        )
        .join('\n');
    final nameCtl = TextEditingController(text: area.name);
    final coordsCtl = TextEditingController(text: ptsLines);
    Color stroke = _colorFromHex(area.strokeColorHex);
    Color fill = _colorFromHex(area.fillColorHex);
    final presets = <Color>[
      Colors.redAccent,
      Colors.orangeAccent,
      Colors.yellowAccent,
      Colors.greenAccent,
      Colors.cyanAccent,
      Colors.lightBlueAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.pinkAccent,
    ];
    String colorToHex(Color c) =>
        c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    String? error;
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSB) => AlertDialog(
          title: const Text('Edit Polygon'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: coordsCtl,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Coordinates (editable) LAT LON per line',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Color',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: presets.map((c) {
                    final selected = c.toARGB32() == stroke.toARGB32();
                    return GestureDetector(
                      onTap: () {
                        stroke = c;
                        fill = c.withValues(alpha: 0.35);
                        setSB(() {});
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.black54,
                            width: selected ? 3 : 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final lines = coordsCtl.text
                    .split(RegExp(r'\r?\n'))
                    .where((l) => l.trim().isNotEmpty)
                    .toList();
                final pts = <LatLng>[];
                for (final line in lines) {
                  final parts = line
                      .trim()
                      .split(RegExp(r'[;,]'))
                      .expand((e) => e.split(RegExp(r'\s+')))
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList();
                  if (parts.length < 2) {
                    setSB(() => error = 'Bad line: "$line"');
                    return;
                  }
                  // Try all splits
                  double? lat;
                  double? lon;
                  for (int s = 1; s < parts.length; s++) {
                    lat = _parseDms(parts.take(s).join(' '), isLat: true);
                    lon = _parseDms(parts.skip(s).join(' '), isLat: false);
                    if (lat != null && lon != null) break;
                  }
                  if (lat == null || lon == null) {
                    setSB(() => error = 'Failed to parse line: "$line"');
                    return;
                  }
                  pts.add(LatLng(lat, lon));
                }
                if (pts.length < 3) {
                  setSB(() => error = 'Need at least 3 points');
                  return;
                }
                Navigator.of(ctx).pop(true);
                final closed = List<LatLng>.from(pts);
                if (closed.first != closed.last) closed.add(closed.first);
                setState(() {
                  _savedAreas[index] = _SavedArea(
                    id: area.id,
                    name: nameCtl.text.trim().isEmpty
                        ? area.name
                        : nameCtl.text.trim(),
                    type: 'polygon',
                    centerLat: null,
                    centerLon: null,
                    radiusNm: null,
                    points: closed,
                    createdAt: area.createdAt,
                    strokeColorHex: colorToHex(stroke),
                    fillColorHex: colorToHex(fill),
                  );
                });
                _persistSavedAreas();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Polygon updated')),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _sortWaypoints() {
    _waypoints.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  Future<void> _persistWaypoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _waypoints.map((e) => e.toJson()).toList();
      await prefs.setString('waypoints', jsonEncode(list));
    } catch (_) {}
  }

  // === Saved Routes library (separate from the current working route) ===
  Future<void> _loadSavedRoutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('saved_routes');
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => _SavedRoute.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() {
        _savedRoutes
          ..clear()
          ..addAll(list);
        _sortSavedRoutes();
      });
    } catch (_) {}
  }

  Future<void> _persistSavedRoutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _savedRoutes.map((e) => e.toJson()).toList();
      await prefs.setString('saved_routes', jsonEncode(list));
    } catch (_) {}
  }

  void _sortSavedRoutes() {
    _savedRoutes.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  Future<void> _saveCurrentRouteAsPrompt() async {
    if (_routePoints.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add at least two points to save a route'),
        ),
      );
      return;
    }
    final nameCtl = TextEditingController(
      text:
          'Route ${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Current Route'),
        content: TextField(
          controller: nameCtl,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final route = _SavedRoute(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: nameCtl.text.trim().isEmpty ? 'Route' : nameCtl.text.trim(),
        points: List<LatLng>.from(_routePoints),
        createdAt: DateTime.now(),
      );
      setState(() {
        _savedRoutes.add(route);
        _sortSavedRoutes();
      });
      await _persistSavedRoutes();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved route "${route.name}"')));
      }
    }
  }

  Future<void> _importSavedRouteJson() async {
    try {
      final typeGroup = const XTypeGroup(label: 'JSON', extensions: ['json']);
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;
      final contents = await file.readAsString();
      final decoded = jsonDecode(contents) as Map<String, dynamic>;
      final pts = (decoded['points'] as List?)?.cast<Map<String, dynamic>>();
      if (pts == null || pts.isEmpty) throw 'Invalid route file';
      final newPoints = <LatLng>[];
      for (final p in pts) {
        final lat = (p['lat'] as num?)?.toDouble();
        final lon = (p['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        newPoints.add(LatLng(lat, lon));
      }
      if (newPoints.length < 2) throw 'No valid points';
      final defName = (decoded['name'] as String?) ?? 'Imported Route';
      final nameCtl = TextEditingController(text: defName);
      final ok = await showDialog<bool>(
        // ignore: use_build_context_synchronously
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import as Saved Route'),
          content: TextField(
            controller: nameCtl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (ok == true) {
        final r = _SavedRoute(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: nameCtl.text.trim().isEmpty ? defName : nameCtl.text.trim(),
          points: newPoints,
          createdAt: DateTime.now(),
        );
        setState(() {
          _savedRoutes.add(r);
          _sortSavedRoutes();
        });
        await _persistSavedRoutes();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Imported route "${r.name}"')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<void> _exportSavedRouteJson(_SavedRoute r) async {
    final data = {
      'generated': DateTime.now().toIso8601String(),
      'name': r.name,
      'points': r.points
          .map((p) => {'lat': p.latitude, 'lon': p.longitude})
          .toList(),
    };
    final jsonStr = jsonEncode(data);
    final bytes = const Utf8Encoder().convert(jsonStr);
    final fileName =
        '${r.name.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.json';
    try {
      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'application/json',
      );
      await xFile.saveTo(fileName);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Route exported: $fileName')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _exportSavedRouteGpx(_SavedRoute r) async {
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln(
      '<gpx version="1.1" creator="AW139Cruise" xmlns="http://www.topografix.com/GPX/1/1">',
    );
    sb.writeln('  <trk><name>${r.name}</name><trkseg>');
    for (final p in r.points) {
      sb.writeln(
        '    <trkpt lat="${p.latitude}" lon="${p.longitude}"></trkpt>',
      );
    }
    sb.writeln('  </trkseg></trk></gpx>');
    final gpxBytes = const Utf8Encoder().convert(sb.toString());
    final gpxName =
        '${r.name.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.gpx';
    try {
      final xFile = XFile.fromData(
        gpxBytes,
        name: gpxName,
        mimeType: 'application/gpx+xml',
      );
      await xFile.saveTo(gpxName);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('GPX exported: $gpxName')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('GPX export failed: $e')));
      }
    }
  }

  void _applySavedRoute(_SavedRoute r, {bool append = false}) {
    setState(() {
      if (!append) _routePoints.clear();
      _routePoints.addAll(r.points);
      _activeLegIndex = 0;
    });
    _persistRoute();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          append ? 'Appended route "${r.name}"' : 'Loaded route "${r.name}"',
        ),
      ),
    );
    if (r.points.isNotEmpty) {
      _mapController.move(r.points.first, 11.0);
    }
  }

  Future<void> _renameSavedRoute(_SavedRoute r) async {
    final ctl = TextEditingController(text: r.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Route'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(labelText: 'Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    if (ok == true) {
      final newName = ctl.text.trim();
      if (newName.isNotEmpty) {
        setState(() {
          final idx = _savedRoutes.indexOf(r);
          if (idx >= 0) {
            _savedRoutes[idx] = _SavedRoute(
              id: r.id,
              name: newName,
              points: r.points,
              createdAt: r.createdAt,
            );
            _sortSavedRoutes();
          }
        });
        await _persistSavedRoutes();
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Renamed to "$newName"')));
      }
    }
  }

  Future<void> _bulkExportRoutesGpx() async {
    if (_savedRoutes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No saved routes to export')),
      );
      return;
    }
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln(
      '<gpx version="1.1" creator="AW139Cruise" xmlns="http://www.topografix.com/GPX/1/1">',
    );
    for (final r in _savedRoutes) {
      sb.writeln('  <trk><name>${r.name}</name><trkseg>');
      for (final p in r.points) {
        sb.writeln(
          '    <trkpt lat="${p.latitude}" lon="${p.longitude}"></trkpt>',
        );
      }
      sb.writeln('  </trkseg></trk>');
    }
    sb.writeln('</gpx>');
    final bytes = const Utf8Encoder().convert(sb.toString());
    final fileName =
        'routes_library_${DateTime.now().millisecondsSinceEpoch}.gpx';
    try {
      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'application/gpx+xml',
      );
      await xFile.saveTo(fileName);
      if (!mounted) return; // ensure context still valid after async gap
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported GPX: $fileName')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Bulk GPX export failed: $e')));
    }
  }

  Future<void> _bulkExportRoutesKml() async {
    if (_savedRoutes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No saved routes to export')),
      );
      return;
    }
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln('<kml xmlns="http://www.opengis.net/kml/2.2"><Document>');
    sb.writeln('<name>Saved Routes ${DateTime.now().toIso8601String()}</name>');
    for (final r in _savedRoutes) {
      sb.writeln(
        '<Placemark><name>${r.name}</name><LineString><tessellate>1</tessellate><coordinates>',
      );
      final coordSb = StringBuffer();
      for (final p in r.points) {
        coordSb.write('${p.longitude},${p.latitude},0 ');
      }
      sb.writeln(coordSb.toString().trim());
      sb.writeln('</coordinates></LineString></Placemark>');
    }
    sb.writeln('</Document></kml>');
    final bytes = const Utf8Encoder().convert(sb.toString());
    final fileName =
        'routes_library_${DateTime.now().millisecondsSinceEpoch}.kml';
    try {
      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'application/vnd.google-earth.kml+xml',
      );
      await xFile.saveTo(fileName);
      if (!mounted) return; // guard after async gap
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported KML: $fileName')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Bulk KML export failed: $e')));
    }
  }

  Future<void> _bulkImportRoutesFile() async {
    try {
      // Use minimal, explicit groups (some platforms reject wildcard '*').
      final typeGroupGpx = const XTypeGroup(label: 'GPX', extensions: ['gpx']);
      final typeGroupKml = const XTypeGroup(label: 'KML', extensions: ['kml']);
      XFile? file = await openFile(
        acceptedTypeGroups: [typeGroupGpx, typeGroupKml],
      );
      // Fallback: if user cannot select (grayed out) try without any filters
      if (file == null) {
        file = await openFile(); // unfiltered picker (all files)
        if (file == null) return;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Using fallback picker (all file types)'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      final contents = await file.readAsString();
      final name = file.name.toLowerCase();
      final newRoutes = <_SavedRoute>[];
      int importedWaypoints = 0; // track waypoint-only imports

      final isGpx = name.endsWith('.gpx') || contents.contains('<gpx');
      // KML detection handled in branch below; no separate flag needed.

      if (isGpx) {
        final doc = xml.XmlDocument.parse(contents);

        // Helper to extract points with namespace tolerance
        List<LatLng> extractPoints(Iterable<xml.XmlElement> ptElements) {
          final pts = <LatLng>[];
          for (final pt in ptElements) {
            final latAttr = pt.getAttribute('lat');
            final lonAttr = pt.getAttribute('lon');
            if (latAttr == null || lonAttr == null) continue;
            final lat = double.tryParse(latAttr);
            final lon = double.tryParse(lonAttr);
            if (lat == null || lon == null) continue;
            pts.add(LatLng(lat, lon));
          }
          return pts;
        }

        void addRouteIfValid(String rName, List<LatLng> pts) {
          if (pts.length >= 2) {
            newRoutes.add(
              _SavedRoute(
                id:
                    DateTime.now().microsecondsSinceEpoch.toString() +
                    pts.length.toString(),
                name: rName.isNotEmpty ? rName : 'Route',
                points: pts,
                createdAt: DateTime.now(),
              ),
            );
          }
        }

        // 1) Try tracks <trk><trkseg><trkpt>
        for (final trk in doc.findAllElements('trk')) {
          final rName = trk.findElements('name').isNotEmpty
              ? (trk.findElements('name').first.value?.trim() ?? 'Track')
              : 'Track';
          final pts = <LatLng>[];
          for (final seg in trk.findAllElements('trkseg')) {
            pts.addAll(extractPoints(seg.findAllElements('trkpt')));
          }
          addRouteIfValid(rName, pts);
        }

        // 2) Try routes <rte><rtept>
        for (final rte in doc.findAllElements('rte')) {
          final rName = rte.findElements('name').isNotEmpty
              ? (rte.findElements('name').first.value?.trim() ?? 'Route')
              : 'Route';
          final pts = extractPoints(rte.findAllElements('rtept'));
          addRouteIfValid(rName, pts);
        }

        // 3) Waypoints <wpt>: import ONLY as individual markers (no auto route)
        final wptElements = doc.findAllElements('wpt');
        if (wptElements.isNotEmpty) {
          final newWpts = <_Waypoint>[];
          for (final w in wptElements) {
            final latAttr = w.getAttribute('lat');
            final lonAttr = w.getAttribute('lon');
            if (latAttr == null || lonAttr == null) continue;
            final lat = double.tryParse(latAttr);
            final lon = double.tryParse(lonAttr);
            if (lat == null || lon == null) continue;
            final eleText = w.findElements('ele').isNotEmpty
                ? w.findElements('ele').first.value?.trim()
                : null;
            final ele = eleText != null ? double.tryParse(eleText) : null;
            final nameText = w.findElements('name').isNotEmpty
                ? (w.findElements('name').first.value?.trim() ?? 'WPT')
                : 'WPT';
            newWpts.add(
              _Waypoint(
                id:
                    DateTime.now().microsecondsSinceEpoch.toString() +
                    importedWaypoints.toString(),
                name: nameText,
                lat: lat,
                lon: lon,
                altMeters: ele,
                type: 'Imported',
                createdAt: DateTime.now(),
              ),
            );
            importedWaypoints++;
          }
          if (newWpts.isNotEmpty) {
            setState(() {
              _waypoints.addAll(newWpts);
              _sortWaypoints();
            });
            await _persistWaypoints();
          }
        }
      } else if (name.endsWith('.kml')) {
        final doc = xml.XmlDocument.parse(contents);
        for (final placemark in doc.findAllElements('Placemark')) {
          final rName = placemark.findElements('name').isNotEmpty
              ? (placemark.findElements('name').first.value?.trim() ?? 'Route')
              : 'Route';
          final coordsEl = placemark.findAllElements('coordinates').isNotEmpty
              ? placemark.findAllElements('coordinates').first
              : null;
          if (coordsEl == null) continue;
          final raw = (coordsEl.value ?? '').trim();
          final tokens = raw.split(RegExp(r'\s+'));
          final pts = <LatLng>[];
          for (final t in tokens) {
            if (t.isEmpty) continue;
            final parts = t.split(',');
            if (parts.length < 2) continue;
            final lon = double.tryParse(parts[0]);
            final lat = double.tryParse(parts[1]);
            if (lat == null || lon == null) continue;
            pts.add(LatLng(lat, lon));
          }
          if (pts.length >= 2) {
            newRoutes.add(
              _SavedRoute(
                id:
                    DateTime.now().microsecondsSinceEpoch.toString() +
                    pts.length.toString(),
                name: rName,
                points: pts,
                createdAt: DateTime.now(),
              ),
            );
          }
        }
      } else {
        throw 'Unsupported file type. Please select a .gpx or .kml file.';
      }
      if (newRoutes.isEmpty && importedWaypoints == 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No valid routes found in file'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      setState(() {
        _savedRoutes.addAll(newRoutes);
        _sortSavedRoutes();
      });
      await _persistSavedRoutes();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '\u2713 Imported ${newRoutes.length} routes${importedWaypoints > 0 ? ' & $importedWaypoints waypoints' : ''}',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // === Route persistence (auto-save current route) ===
  Future<void> _persistRoute() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'points': _routePoints
            .map((p) => {'lat': p.latitude, 'lon': p.longitude})
            .toList(),
        'activeLegIndex': _activeLegIndex,
        'groundSpeedKts': _groundSpeedKts,
      };
      await prefs.setString('route_current', jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _loadRoute() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('route_current');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final pts = (decoded['points'] as List?)?.cast<Map<String, dynamic>>();
      if (pts == null) return;
      final newPoints = <LatLng>[];
      for (final p in pts) {
        final lat = (p['lat'] as num?)?.toDouble();
        final lon = (p['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        newPoints.add(LatLng(lat, lon));
      }
      if (!mounted) return;
      setState(() {
        _routePoints
          ..clear()
          ..addAll(newPoints);
        _activeLegIndex =
            (decoded['activeLegIndex'] as int?)?.clamp(
              0,
              _routePoints.length - 1,
            ) ??
            0;
        _groundSpeedKts =
            (decoded['groundSpeedKts'] as num?)?.toDouble() ?? _groundSpeedKts;
      });
    } catch (_) {}
  }

  void _addWaypoint(_Waypoint wp, {bool silent = false}) {
    setState(() {
      _waypoints.add(wp);
      _sortWaypoints();
    });
    _persistWaypoints();
    if (!silent) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved waypoint "${wp.name}"')));
    }
  }

  Future<void> _editWaypoint(int index) async {
    if (index < 0 || index >= _waypoints.length) return;
    final wp = _waypoints[index];
    final nameController = TextEditingController(text: wp.name);
    final altController = TextEditingController(
      text: wp.altMeters != null
          ? (wp.altMeters! * 3.28084).round().toString()
          : '',
    );
    String wptType = wp.type;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Waypoint'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            Text('Lat: ${wp.lat.toStringAsFixed(6)}'),
            Text('Lon: ${wp.lon.toStringAsFixed(6)}'),
            const SizedBox(height: 12),
            TextField(
              controller: altController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Altitude (ft, optional)',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Type:', style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 12),
                StatefulBuilder(
                  builder: (context, setSB) => DropdownButton<String>(
                    value: wptType,
                    dropdownColor: const Color(0xFF1E1E1E),
                    items: const [
                      DropdownMenuItem(value: 'User', child: Text('User')),
                      DropdownMenuItem(value: 'MOT', child: Text('MOT')),
                      DropdownMenuItem(
                        value: 'Hospital',
                        child: Text('Hospital'),
                      ),
                      DropdownMenuItem(
                        value: 'Helipad',
                        child: Text('Helipad'),
                      ),
                      DropdownMenuItem(value: 'Dams', child: Text('Dams')),
                    ],
                    onChanged: (v) => setSB(() => wptType = v ?? wptType),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == true) {
      setState(() {
        _waypoints[index] = _Waypoint(
          id: wp.id,
          name: nameController.text.trim().isEmpty
              ? wp.name
              : nameController.text.trim(),
          lat: wp.lat,
          lon: wp.lon,
          altMeters: () {
            final ft = double.tryParse(altController.text.trim());
            return ft != null ? ft * 0.3048 : null;
          }(),
          type: wptType,
          createdAt: wp.createdAt,
        );
        _sortWaypoints();
      });
      await _persistWaypoints();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Waypoint updated')));
      }
    }
  }

  Future<void> _showSaveWaypointDialog(LatLng latLng) async {
    final controller = TextEditingController(
      text:
          'WPT ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    final altController = TextEditingController();
    String wptType = 'User';

    // Prefill elevation from service if available (convert m -> ft for UI)
    try {
      final elev = await _fetchElevation(latLng.latitude, latLng.longitude);
      if (elev != null) {
        final elevFt = (elev * 3.28084).round();
        altController.text = elevFt.toString();
      }
    } catch (_) {}
    if (!mounted) return;
    // Pre-compute nearest airports in the inferred FIR (or nearest-airport country fallback)
    final nearestAirports = _nearestAirportsInFIR(latLng, 2);
    final firCode = nearestAirports.isNotEmpty
        ? ((nearestAirports.first.properties?['countryCode'] as String?) ?? '')
        : '';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Save Waypoint'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              Text('Lat: ${_toDms(latLng.latitude, isLat: true)}'),
              Text('Lon: ${_toDms(latLng.longitude, isLat: false)}'),
              if (nearestAirports.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Nearest airports${firCode.isNotEmpty ? ' (FIR: $firCode)' : ''}:',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 4),
                for (final a in nearestAirports)
                  Text(
                    _formatAirportRadialDistance(a, latLng),
                    style: const TextStyle(color: Colors.white70),
                  ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: altController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Altitude (ft, optional)',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Type:', style: TextStyle(color: Colors.white70)),
                  const SizedBox(width: 12),
                  StatefulBuilder(
                    builder: (context, setSB) => DropdownButton<String>(
                      value: wptType,
                      dropdownColor: const Color(0xFF1E1E1E),
                      items: const [
                        DropdownMenuItem(value: 'User', child: Text('User')),
                        DropdownMenuItem(value: 'MOT', child: Text('MOT')),
                        DropdownMenuItem(
                          value: 'Hospital',
                          child: Text('Hospital'),
                        ),
                        DropdownMenuItem(
                          value: 'Helipad',
                          child: Text('Helipad'),
                        ),
                        DropdownMenuItem(value: 'Dams', child: Text('Dams')),
                      ],
                      onChanged: (v) => setSB(() => wptType = v ?? 'User'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result == true) {
      if (!mounted) return; // avoid using context after async gap
      final now = DateTime.now();
      final wp = _Waypoint(
        id: now.microsecondsSinceEpoch.toString(),
        name: controller.text.trim().isEmpty
            ? 'WPT ${now.hour}:${now.minute}'
            : controller.text.trim(),
        lat: latLng.latitude,
        lon: latLng.longitude,
        altMeters: (() {
          final ft = double.tryParse(altController.text.trim());
          return ft != null ? ft * 0.3048 : null;
        })(),
        type: wptType,
        createdAt: now,
      );
      _addWaypoint(wp);
    }
  }

  // Compute initial true bearing in degrees from 'from' to 'to' (0..360)
  double _bearingDeg(LatLng from, LatLng to) {
    final lat1 = from.latitude * math.pi / 180.0;
    final lat2 = to.latitude * math.pi / 180.0;
    final dLon = (to.longitude - from.longitude) * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final brng = math.atan2(y, x) * 180.0 / math.pi;
    return _normalize360(brng);
  }

  // Find the point's FIR country using airspace polygons when available; otherwise
  // fall back to the nearest airport's country. Then return closest N airports in that FIR.
  List<_Airport> _nearestAirportsInFIR(LatLng p, int count) {
    String? country = _countryForPoint(p);
    // Fallback: country of nearest airport overall
    if (country == null && _airports.isNotEmpty) {
      _airports.sort((a, b) {
        final da = _geo.as(LengthUnit.Meter, a.position, p);
        final db = _geo.as(LengthUnit.Meter, b.position, p);
        return da.compareTo(db);
      });
      country = (_airports.first.properties?['countryCode'] as String?) ?? '';
    }
    // Special case: For Cyprus, always show LCLK and LCPH radials
    if ((country ?? '').toUpperCase() == 'CY') {
      final wanted = <String>{'LCLK', 'LCPH'};
      final list = _airports
          .where((a) => wanted.contains((a.icao ?? '').toUpperCase()))
          .toList();
      // Sort by distance to the point so the closer appears first
      list.sort((a, b) {
        final da = _geo.as(LengthUnit.Meter, a.position, p);
        final db = _geo.as(LengthUnit.Meter, b.position, p);
        return da.compareTo(db);
      });
      // Respect requested count if smaller than available
      if (list.length > count) return list.sublist(0, count);
      return list;
    }
    final List<_Airport> pool = country == null || country.isEmpty
        ? List<_Airport>.from(_airports)
        : _airports
              .where(
                (a) => (a.properties?['countryCode'] as String?) == country,
              )
              .toList();
    pool.sort((a, b) {
      final da = _geo.as(LengthUnit.Meter, a.position, p);
      final db = _geo.as(LengthUnit.Meter, b.position, p);
      return da.compareTo(db);
    });
    if (pool.length > count) {
      return pool.sublist(0, count);
    }
    return pool;
  }

  // Determine if a point lies inside any known airspace perimeter, and return that country's code
  String? _countryForPoint(LatLng p) {
    for (final asp in _airspacePerimeters) {
      try {
        final cc = (asp['countryCode'] ?? '') as String;
        final perim = (asp['perimeter'] as List).cast<LatLng>();
        if (perim.isNotEmpty && _pointInPolygon(p, perim)) {
          return cc;
        }
      } catch (_) {}
    }
    return null;
  }

  // Ray-casting algorithm for point-in-polygon (non-self-intersecting)
  bool _pointInPolygon(LatLng pt, List<LatLng> poly) {
    bool inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i].longitude, yi = poly[i].latitude;
      final xj = poly[j].longitude, yj = poly[j].latitude;
      final bool intersect =
          ((yi > pt.latitude) != (yj > pt.latitude)) &&
          (pt.longitude <
              (xj - xi) * (pt.latitude - yi) / (yj - yi + 0.0) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  String _formatAirportRadialDistance(_Airport a, LatLng p) {
    final brg = _bearingDeg(a.position, p);
    final radial = brg.round() % 360;
    final radialStr = radial.toString().padLeft(3, '0');
    final dMeters = _geo.as(LengthUnit.Meter, a.position, p);
    final dNm = dMeters / 1852.0;
    final id = (a.icao != null && a.icao!.isNotEmpty) ? a.icao! : a.name;
    return '$id  $radialStr° / ${dNm.toStringAsFixed(1)} nm';
  }

  Future<double?> _fetchElevation(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://api.open-elevation.com/api/v1/lookup?locations=$lat,$lon',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final e = results.first as Map<String, dynamic>;
          final elev = (e['elevation'] as num?)?.toDouble();
          return elev;
        }
      }
    } catch (_) {}
    return null;
  }

  void _openWaypointsFolder({bool initialShowRoutes = false}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, controller) {
          bool showRoutes = initialShowRoutes;
          return StatefulBuilder(
            builder: (innerCtx, setInner) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: () =>
                                  setInner(() => showRoutes = false),
                              style: TextButton.styleFrom(
                                foregroundColor: showRoutes
                                    ? Colors.white70
                                    : Colors.orangeAccent,
                              ),
                              child: const Text('Waypoints'),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () =>
                                  setInner(() => showRoutes = true),
                              style: TextButton.styleFrom(
                                foregroundColor: showRoutes
                                    ? Colors.orangeAccent
                                    : Colors.white70,
                              ),
                              child: const Text('Routes'),
                            ),
                          ],
                        ),
                      ),
                      if (!showRoutes) ...[
                        TextButton.icon(
                          onPressed: _exportWaypointsMenu,
                          icon: const Icon(
                            Icons.upload_file,
                            color: Colors.orangeAccent,
                          ),
                          label: const Text(
                            'Export',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _importWaypoints,
                          icon: const Icon(
                            Icons.download,
                            color: Colors.orangeAccent,
                          ),
                          label: const Text(
                            'Import',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _showAddWaypointDialog,
                          icon: const Icon(
                            Icons.add,
                            color: Colors.orangeAccent,
                          ),
                          label: const Text(
                            'Add',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                      ] else ...[
                        TextButton.icon(
                          onPressed: _saveCurrentRouteAsPrompt,
                          icon: const Icon(
                            Icons.save,
                            color: Colors.orangeAccent,
                          ),
                          label: const Text(
                            'Save Current',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _importSavedRouteJson,
                          icon: const Icon(
                            Icons.download,
                            color: Colors.orangeAccent,
                          ),
                          label: const Text(
                            'Import',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                        const SizedBox(width: 8),
                        PopupMenuButton<String>(
                          tooltip: 'Bulk actions',
                          icon: const Icon(
                            Icons.more_horiz,
                            color: Colors.orangeAccent,
                          ),
                          onSelected: (v) {
                            if (v == 'bulk_export_gpx') {
                              _bulkExportRoutesGpx();
                            } else if (v == 'bulk_export_kml') {
                              _bulkExportRoutesKml();
                            } else if (v == 'bulk_import') {
                              _bulkImportRoutesFile();
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'bulk_export_gpx',
                              child: Text('Export All GPX'),
                            ),
                            PopupMenuItem(
                              value: 'bulk_export_kml',
                              child: Text('Export All KML'),
                            ),
                            PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'bulk_import',
                              child: Text('Import GPX/KML Library'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.white24),
                Expanded(
                  child: showRoutes
                      ? (_savedRoutes.isEmpty
                            ? const Center(
                                child: Text(
                                  'No saved routes yet',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              )
                            : ListView.builder(
                                controller: controller,
                                itemCount: _savedRoutes.length,
                                itemBuilder: (_, i) {
                                  final r = _savedRoutes[i];
                                  final lenNm = () {
                                    double meters = 0;
                                    for (int k = 1; k < r.points.length; k++) {
                                      meters += _geo.as(
                                        LengthUnit.Meter,
                                        r.points[k - 1],
                                        r.points[k],
                                      );
                                    }
                                    return meters / 1852.0;
                                  }();
                                  return ListTile(
                                    title: Text(
                                      r.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${r.points.length} pts • ${lenNm.toStringAsFixed(lenNm < 10 ? 2 : 0)} nm',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                    ),
                                    onTap: () {
                                      Navigator.of(ctx).pop();
                                      _applySavedRoute(r);
                                    },
                                    trailing: PopupMenuButton<String>(
                                      tooltip: 'Actions',
                                      icon: const Icon(
                                        Icons.more_vert,
                                        color: Colors.white70,
                                      ),
                                      onSelected: (v) async {
                                        if (v == 'load') {
                                          Navigator.of(ctx).pop();
                                          _applySavedRoute(r);
                                        } else if (v == 'append') {
                                          Navigator.of(ctx).pop();
                                          _applySavedRoute(r, append: true);
                                        } else if (v == 'rename') {
                                          _renameSavedRoute(r);
                                        } else if (v == 'export_json') {
                                          _exportSavedRouteJson(r);
                                        } else if (v == 'export_gpx') {
                                          _exportSavedRouteGpx(r);
                                        } else if (v == 'delete') {
                                          final ok = await _confirmDeleteDialog(
                                            'Delete saved route',
                                            'Delete route "${r.name}"?',
                                          );
                                          if (!ok) return;
                                          setInner(() {
                                            _savedRoutes.removeAt(i);
                                          });
                                          await _persistSavedRoutes();
                                        }
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'load',
                                          child: Text('Load'),
                                        ),
                                        PopupMenuItem(
                                          value: 'append',
                                          child: Text('Append'),
                                        ),
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Text('Rename'),
                                        ),
                                        PopupMenuDivider(),
                                        PopupMenuItem(
                                          value: 'export_json',
                                          child: Text('Export JSON'),
                                        ),
                                        PopupMenuItem(
                                          value: 'export_gpx',
                                          child: Text('Export GPX'),
                                        ),
                                        PopupMenuDivider(),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ))
                      : (_waypoints.isEmpty
                            ? const Center(
                                child: Text(
                                  'No waypoints saved yet',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              )
                            : ListView.builder(
                                controller: controller,
                                itemCount: _waypoints.length,
                                itemBuilder: (_, i) {
                                  final wp = _waypoints[i];
                                  return Dismissible(
                                    key: ValueKey(wp.id),
                                    direction: DismissDirection.endToStart,
                                    background: Container(
                                      color: Colors.redAccent.withValues(
                                        alpha: 0.2,
                                      ),
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      child: const Icon(
                                        Icons.delete,
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                    confirmDismiss: (dir) async {
                                      return await _confirmDeleteDialog(
                                        'Delete waypoint',
                                        'Delete waypoint "${wp.name}"?',
                                      );
                                    },
                                    onDismissed: (dir) async {
                                      setInner(() {
                                        _waypoints.removeAt(i);
                                      });
                                      await _persistWaypoints();
                                    },
                                    child: ListTile(
                                      leading: wp.type == 'Helipad'
                                          ? Container(
                                              width: 28,
                                              height: 28,
                                              decoration: BoxDecoration(
                                                color: Colors.lightBlueAccent,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.black87,
                                                  width: 1,
                                                ),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Colors.black54,
                                                    blurRadius: 2,
                                                  ),
                                                ],
                                              ),
                                              alignment: Alignment.center,
                                              child: const Text(
                                                'H',
                                                style: TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 16,
                                                ),
                                              ),
                                            )
                                          : Icon(
                                              wp.type == 'Hospital'
                                                  ? Icons.local_hospital
                                                  : wp.type == 'Dams'
                                                  ? Icons.water
                                                  : wp.type == 'MOT'
                                                  ? Icons.add_location_alt
                                                  : Icons.place,
                                              color: wp.type == 'Hospital'
                                                  ? Colors.redAccent
                                                  : wp.type == 'Dams'
                                                  ? Colors.blueAccent
                                                  : wp.type == 'MOT'
                                                  ? Colors.deepOrangeAccent
                                                  : Colors.orangeAccent,
                                            ),
                                      title: Text(
                                        wp.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${_toDms(wp.lat, isLat: true)}, ${_toDms(wp.lon, isLat: false)}'
                                        '${wp.altMeters != null ? ' • ${((wp.altMeters ?? 0) * 3.28084).round()} ft' : ''}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                      onTap: () {
                                        Navigator.of(ctx).pop();
                                        _showWaypointActions(wp);
                                      },
                                      trailing: PopupMenuButton<String>(
                                        tooltip: 'Actions',
                                        icon: const Icon(
                                          Icons.more_vert,
                                          color: Colors.white70,
                                        ),
                                        onSelected: (v) async {
                                          if (v == 'copy_dms') {
                                            final text =
                                                '${_toDms(wp.lat, isLat: true)}, ${_toDms(wp.lon, isLat: false)}';
                                            Clipboard.setData(
                                              ClipboardData(text: text),
                                            );
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Copied DMS to clipboard',
                                                ),
                                              ),
                                            );
                                          } else if (v == 'copy_dec') {
                                            final text =
                                                '${wp.lat.toStringAsFixed(6)}, ${wp.lon.toStringAsFixed(6)}';
                                            Clipboard.setData(
                                              ClipboardData(text: text),
                                            );
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Copied decimal coords to clipboard',
                                                ),
                                              ),
                                            );
                                          } else if (v == 'edit') {
                                            _editWaypoint(i);
                                          } else if (v == 'delete') {
                                            final ok = await _confirmDeleteDialog(
                                              'Delete waypoint',
                                              'Delete waypoint "${wp.name}"?',
                                            );
                                            if (!ok) return;
                                            setInner(() {
                                              _waypoints.removeAt(i);
                                            });
                                            await _persistWaypoints();
                                          }
                                        },
                                        itemBuilder: (context) => const [
                                          PopupMenuItem(
                                            value: 'copy_dms',
                                            child: Text('Copy DMS'),
                                          ),
                                          PopupMenuItem(
                                            value: 'copy_dec',
                                            child: Text('Copy Decimal'),
                                          ),
                                          PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Edit'),
                                          ),
                                          PopupMenuDivider(),
                                          PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              )),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ===== DMS helpers =====
  String _toDms(double value, {required bool isLat}) {
    final hemi = (isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W'));
    final abs = value.abs();
    final d = abs.floor();
    final remMin = (abs - d) * 60.0;
    final m = remMin.floor();
    final s = (remMin - m) * 60.0;
    final dd = isLat ? d.clamp(0, 90) : d.clamp(0, 180);
    return '${dd.toString().padLeft(isLat ? 2 : 3, '0')}°${m.toString().padLeft(2, '0')}'
        "'${s.toStringAsFixed(1).padLeft(4, '0')}\" $hemi";
  }

  double? _parseDms(String input, {required bool isLat}) {
    if (input.trim().isEmpty) return null;
    String s = input.trim().toUpperCase();
    // Extract hemisphere if present
    String? hemi;
    final hemiMatch = RegExp(r'[NSEW]').firstMatch(s);
    if (hemiMatch != null) {
      hemi = hemiMatch.group(0);
      s = s.replaceAll(RegExp(r'[NSEW]'), '');
    }
    // Replace common separators with spaces
    s = s
        .replaceAll('°', ' ')
        .replaceAll("'", ' ')
        .replaceAll('"', ' ')
        .replaceAll(':', ' ')
        .replaceAll(',', ' ');
    // Collapse whitespace
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Tokenize numeric parts
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
      deg = nums[0]; // Allow decimal degrees as fallback
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
    // Apply sign from hemisphere or from negative degrees
    if ((hemi == 'S' && isLat) || (hemi == 'W' && !isLat) || deg < 0) {
      val = -val;
    }
    // Range check
    if (isLat) {
      if (val < -90 || val > 90) return null;
    } else {
      if (val < -180 || val > 180) return null;
    }
    return val;
  }

  Future<void> _showAddWaypointDialog() async {
    final nameController = TextEditingController();
    final latController = TextEditingController();
    final lonController = TextEditingController();
    final altController = TextEditingController();
    String wptType = 'User';
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateSB) {
            return AlertDialog(
              title: const Text('Add Waypoint'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: latController,
                    decoration: const InputDecoration(
                      labelText:
                          'Latitude (DMS, e.g. 34°56\'12"N or 34 56 12 N)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: altController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Altitude (ft, optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        'Type:',
                        style: TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: wptType,
                        dropdownColor: const Color(0xFF1E1E1E),
                        items: const [
                          DropdownMenuItem(value: 'User', child: Text('User')),
                          DropdownMenuItem(value: 'MOT', child: Text('MOT')),
                          DropdownMenuItem(
                            value: 'Hospital',
                            child: Text('Hospital'),
                          ),
                          DropdownMenuItem(
                            value: 'Helipad',
                            child: Text('Helipad'),
                          ),
                        ],
                        onChanged: (v) =>
                            setStateSB(() => wptType = v ?? 'User'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: lonController,
                    decoration: const InputDecoration(
                      labelText:
                          'Longitude (DMS, e.g. 33°37\'06"E or 33 37 06 E)',
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    final lat = _parseDms(latController.text, isLat: true);
                    final lon = _parseDms(lonController.text, isLat: false);
                    if (name.isEmpty) {
                      setStateSB(() => error = 'Please enter a name.');
                      return;
                    }
                    if (lat == null) {
                      setStateSB(() => error = 'Invalid latitude (DMS).');
                      return;
                    }
                    if (lon == null) {
                      setStateSB(() => error = 'Invalid longitude (DMS).');
                      return;
                    }
                    final now = DateTime.now();
                    final wp = _Waypoint(
                      id: now.microsecondsSinceEpoch.toString(),
                      name: name,
                      lat: lat,
                      lon: lon,
                      altMeters: (() {
                        final ft = double.tryParse(altController.text.trim());
                        return ft != null ? ft * 0.3048 : null;
                      })(),
                      type: wptType,
                      createdAt: now,
                    );
                    _addWaypoint(wp, silent: true);
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok == true) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Waypoint added')));
    }
  }

  // ===== Export / Import =====
  Future<Directory> _ensureExportDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/Waypoints');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _exportWaypointsMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.data_object,
                color: Colors.orangeAccent,
              ),
              title: const Text(
                'Export as JSON',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(context, 'json'),
            ),
            ListTile(
              leading: const Icon(Icons.timeline, color: Colors.orangeAccent),
              title: const Text(
                'Export as GPX',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(context, 'gpx'),
            ),
            ListTile(
              leading: const Icon(Icons.public, color: Colors.orangeAccent),
              title: const Text(
                'Export as KML',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(context, 'kml'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await _exportWaypoints(choice);
  }

  Future<void> _exportWaypoints(String fmt) async {
    if (_waypoints.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No waypoints to export')));
      return;
    }
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    String ext = 'json';
    String content = '';
    if (fmt == 'json') {
      ext = 'json';
      content = jsonEncode(_waypoints.map((e) => e.toJson()).toList());
    } else if (fmt == 'gpx') {
      ext = 'gpx';
      final sb = StringBuffer();
      sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
      sb.writeln(
        '<gpx version="1.1" creator="AW139" xmlns="http://www.topografix.com/GPX/1/1">',
      );
      for (final w in _waypoints) {
        sb.write('<wpt lat="${w.lat}" lon="${w.lon}">');
        if (w.altMeters != null) {
          sb.write('<ele>${w.altMeters}</ele>');
        }
        sb.writeln('<name>${_xmlEscape(w.name)}</name></wpt>');
      }
      sb.writeln('</gpx>');
      content = sb.toString();
    } else if (fmt == 'kml') {
      ext = 'kml';
      final sb = StringBuffer();
      sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
      sb.writeln('<kml xmlns="http://www.opengis.net/kml/2.2"><Document>');
      for (final w in _waypoints) {
        final alt = w.altMeters != null ? w.altMeters!.toString() : '0';
        sb.writeln(
          '<Placemark>'
          '<name>${_xmlEscape(w.name)}</name>'
          '<Point><coordinates>${w.lon},${w.lat},$alt</coordinates></Point>'
          '</Placemark>',
        );
      }
      sb.writeln('</Document></kml>');
      content = sb.toString();
    }
    final dir = await _ensureExportDir();
    final file = File('${dir.path}/waypoints-$ts.$ext');
    await file.writeAsString(content);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Exported to ${file.path}')));
  }

  String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<void> _importWaypoints() async {
    final typeGroup = XTypeGroup(
      label: 'Waypoints',
      extensions: const ['json', 'gpx', 'kml'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final text = String.fromCharCodes(bytes);
    final nameLower = file.name.toLowerCase();
    if (nameLower.endsWith('.json')) {
      try {
        final data = jsonDecode(text);
        if (data is List) {
          for (final e in data) {
            final m = (e as Map).cast<String, dynamic>();
            if (m.containsKey('lat') && m.containsKey('lon')) {
              final wp = _Waypoint.fromJson(m);
              _waypoints.add(wp);
            }
          }
          setState(() {
            _sortWaypoints();
          });
          await _persistWaypoints();
          _persistRoute(); // ensure route snapshot unaffected (no-op) but keeps consistency
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Imported JSON waypoints')),
          );
        }
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to import JSON')));
      }
    } else if (nameLower.endsWith('.gpx')) {
      try {
        final doc = xml.XmlDocument.parse(text);
        final wpts = doc.findAllElements('wpt');
        for (final w in wpts) {
          final lat = double.tryParse(w.getAttribute('lat') ?? '');
          final lon = double.tryParse(w.getAttribute('lon') ?? '');
          if (lat == null || lon == null) continue;
          final name = w.getElement('name')?.innerText ?? 'WPT';
          final eleText = w.getElement('ele')?.innerText;
          final altM = eleText != null ? double.tryParse(eleText) : null;
          _waypoints.add(
            _Waypoint(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              name: name,
              lat: lat,
              lon: lon,
              altMeters: altM,
              createdAt: DateTime.now(),
            ),
          );
        }
        setState(() {
          _sortWaypoints();
        });
        await _persistWaypoints();
        _persistRoute();
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Imported GPX waypoints')));
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to import GPX')));
      }
    } else if (nameLower.endsWith('.kml')) {
      try {
        final doc = xml.XmlDocument.parse(text);
        final placemarks = doc.findAllElements('Placemark');
        for (final p in placemarks) {
          final name = p.getElement('name')?.innerText ?? 'WPT';
          final coordsText = p
              .findAllElements('coordinates')
              .map((e) => e.innerText)
              .firstWhere((e) => e.isNotEmpty, orElse: () => '');
          if (coordsText.isEmpty) continue;
          final first = coordsText.trim().split(RegExp('\\s+')).first;
          final parts = first.split(',');
          if (parts.length < 2) continue;
          final lon = double.tryParse(parts[0]);
          final lat = double.tryParse(parts[1]);
          final altM = parts.length >= 3 ? double.tryParse(parts[2]) : null;
          if (lat == null || lon == null) continue;
          _waypoints.add(
            _Waypoint(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              name: name,
              lat: lat,
              lon: lon,
              altMeters: altM,
              createdAt: DateTime.now(),
            ),
          );
        }
        setState(() {
          _sortWaypoints();
        });
        await _persistWaypoints();
        _persistRoute();
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Imported KML waypoints')));
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to import KML')));
      }
    }
  }
}

// Small UI helper for the info bar
class _InfoItem extends StatelessWidget {
  final String label;
  final String value;
  const _InfoItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.orangeAccent,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}

extension _FlightTimeFormat on _MovingMapScreenState {
  String _formatFlightTime() {
    if (_flightStart == null) return '--';
    final end = _flightEnd ?? DateTime.now();
    final d = end.difference(_flightStart!);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${s}s';
  }
}

// Custom painter for helicopter marker
class _HelicopterPainter extends CustomPainter {
  final bool nightMode;
  final bool nvgMode;
  final double nvgIntensity;
  final double scale;

  _HelicopterPainter({
    this.nightMode = false,
    this.nvgMode = false,
    this.nvgIntensity = 1.0,
    this.scale = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Base colors: change for NVG (bright green) and Night (high-contrast cyan)
    Color fillColor = Colors.blueAccent;
    Color strokeColor = Colors.white70;
    double strokeWidth = 2.0 * (scale);

    if (nvgMode) {
      // NVG: strong green, brightness depends on intensity
      final g = (200 + (55 * nvgIntensity)).clamp(0, 255).toInt();
      fillColor = Color.fromARGB(255, 0, g, 0);
      strokeColor = Color.fromARGB(255, 160, 255, 160);
      strokeWidth = 2.5 * (1.0 + 0.6 * nvgIntensity) * scale;
    } else if (nightMode) {
      // Night: darker fill with a bright outline and halo to reduce glare but remain visible
      fillColor = const Color.fromARGB(
        255,
        12,
        30,
        30,
      ); // very dark teal/near-black
      strokeColor = const Color.fromARGB(
        255,
        180,
        255,
        230,
      ); // bright cyan outline
      strokeWidth = 4.2 * scale;
    }

    final bodyPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = strokeColor
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Fuselage body (scaled)
    final bodyWidth = 14.0 * scale;
    final bodyHeight = 26.0 * scale;
    final bodyRect = Rect.fromCenter(
      center: center.translate(0, 4 * scale),
      width: bodyWidth,
      height: bodyHeight,
    );
    final rad = Radius.circular(6 * scale);
    final rrect = RRect.fromRectAndCorners(
      bodyRect,
      topLeft: rad,
      topRight: rad,
      bottomLeft: rad,
      bottomRight: rad,
    );
    canvas.drawRRect(rrect, bodyPaint);
    canvas.drawRRect(rrect, stroke);

    // Tail boom (triangle)
    final tailPath = ui.Path()
      ..moveTo(center.dx, bodyRect.top + 2 * scale)
      ..lineTo(center.dx - 3 * scale, bodyRect.top - 18 * scale)
      ..lineTo(center.dx + 3 * scale, bodyRect.top - 18 * scale)
      ..close();
    canvas.drawPath(tailPath, bodyPaint);
    canvas.drawPath(tailPath, stroke);

    // Rotor ring
    final rotorCenter = center.translate(0, bodyRect.top - 20 * scale);
    final rotorRadius = 16.0 * scale;
    final rotorPaint = Paint()
      ..color = (nvgMode ? Color.fromARGB(200, 200, 255, 200) : Colors.white54)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (1.5 * scale).clamp(1.0, 4.0);
    canvas.drawCircle(rotorCenter, rotorRadius, rotorPaint);

    // Rotor blades (cross)
    canvas.drawLine(
      rotorCenter.translate(-rotorRadius, 0),
      rotorCenter.translate(rotorRadius, 0),
      rotorPaint,
    );
    canvas.drawLine(
      rotorCenter.translate(0, -rotorRadius),
      rotorCenter.translate(0, rotorRadius),
      rotorPaint,
    );

    // Nose arrow for heading
    final nosePath = ui.Path()
      ..moveTo(center.dx, bodyRect.bottom + 5 * scale)
      ..lineTo(center.dx - 5 * scale, bodyRect.bottom - 2 * scale)
      ..lineTo(center.dx + 5 * scale, bodyRect.bottom - 2 * scale)
      ..close();
    canvas.drawPath(nosePath, bodyPaint);
    canvas.drawPath(nosePath, stroke);

    // Add a stronger glow/halo in NVG/night for extra visibility
    if (nvgMode || nightMode) {
      // Glow paint with blur for a soft halo. Night uses brighter cyan/white halo but dark fill.
      final glowPaint = Paint()
        ..color = (nvgMode
            ? Color.fromARGB(
                (180 * nvgIntensity).toInt().clamp(80, 255),
                0,
                220,
                0,
              )
            : const Color.fromARGB(200, 180, 255, 230))
        ..style = PaintingStyle.fill
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10.0 * scale);
      canvas.drawCircle(center, (rotorRadius + 9 * scale), glowPaint);

      // Outer halo ring (bright rim) to separate from background — higher alpha for night mode
      final halo = Paint()
        ..color = (nvgMode
            ? Colors.white.withAlpha(80)
            : Colors.white.withAlpha(180))
        ..style = PaintingStyle.stroke
        ..strokeWidth = (3.0 * scale).clamp(1.0, 8.0)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5.0 * scale);
      canvas.drawCircle(center, (rotorRadius + 13 * scale), halo);
    }
  }

  @override
  bool shouldRepaint(covariant _HelicopterPainter oldDelegate) {
    return oldDelegate.nightMode != nightMode ||
        oldDelegate.nvgMode != nvgMode ||
        (oldDelegate.nvgIntensity - nvgIntensity).abs() > 0.001 ||
        (oldDelegate.scale - scale).abs() > 0.001;
  }
}
