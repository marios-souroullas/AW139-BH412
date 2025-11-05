// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'cruise_input_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart'
    show rootBundle, Clipboard, ClipboardData;
import 'dart:convert' show jsonDecode, jsonEncode;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart' as xml;
import 'dart:io' show File, Directory;

void main() {
  runApp(const AW139CruiseApp());
}

class AW139CruiseApp extends StatefulWidget {
  const AW139CruiseApp({super.key});
  @override
  State<AW139CruiseApp> createState() => _AW139CruiseAppState();
}

class _AW139CruiseAppState extends State<AW139CruiseApp> {
  bool _cruisePlannerMode = false; // false = Moving Map is default

  @override
  Widget build(BuildContext context) {
    final baseDark = ThemeData.dark();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AW139 Cruise Planner v4',
      theme: baseDark.copyWith(
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        colorScheme: baseDark.colorScheme.copyWith(
          primary: Colors.orangeAccent,
          secondary: Colors.tealAccent,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF1E1E1E),
          labelStyle: TextStyle(color: Colors.white70),
          hintStyle: TextStyle(color: Colors.white38),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.orangeAccent),
          ),
        ),
        textTheme: GoogleFonts.notoSansTextTheme(
          baseDark.textTheme,
        ).apply(bodyColor: Colors.white, displayColor: Colors.white),
        chipTheme: baseDark.chipTheme.copyWith(
          backgroundColor: const Color(0xFF222222),
          selectedColor: Colors.orange,
          labelStyle: const TextStyle(color: Colors.white),
          secondaryLabelStyle: const TextStyle(color: Colors.white),
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text(
            _cruisePlannerMode ? 'AW139 Cruise Planner' : 'Moving Map',
          ),
          actions: [
            Row(
              children: [
                const Text(
                  'Cruise Planner',
                  style: TextStyle(color: Colors.white),
                ),
                Switch(
                  value: _cruisePlannerMode,
                  onChanged: (v) => setState(() => _cruisePlannerMode = v),
                  activeThumbColor: Colors.orangeAccent,
                ),
                const Text('Moving Map', style: TextStyle(color: Colors.white)),
                const SizedBox(width: 12),
              ],
            ),
          ],
        ),
        body: _cruisePlannerMode
            ? const CruiseInputScreen()
            : const MovingMapScreen(),
      ),
    );
  }
}

// API keys for weather and aviation data
const String kOpenWeatherApiKey = '2bfda15eb1d3c7ea910fc5cc180ab4ad';
const String kAvwxApiToken =
    'f03J12T09f6TiY6YqSR39M8Sv6o-bEkieivjBnVi_C8'; // For METAR/TAF
const String kWindyApiKey =
    'a4wqVgw3RBBPbjA0PjMtmD1I9PK0ndAX'; // For winds aloft

class MovingMapScreen extends StatefulWidget {
  const MovingMapScreen({super.key});
  @override
  State<MovingMapScreen> createState() => _MovingMapScreenState();
}

// Simple airport model (private to this file)
class _Airport {
  final String name;
  final String? icao;
  final String? iata;
  final LatLng position;
  final Map<String, dynamic> properties;
  const _Airport({
    required this.name,
    this.icao,
    this.iata,
    required this.position,
    required this.properties,
  });
}

// Simple saved waypoint model
class _Waypoint {
  final String id; // unique id (timestamp-based)
  final String name;
  final double lat;
  final double lon;
  final double? altMeters; // optional altitude MSL in meters
  final String type; // MOT, Hospital, Helipad, User
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
    'alt': altMeters,
    'type': type,
    'createdAt': createdAt.toIso8601String(),
  };

  static _Waypoint fromJson(Map<String, dynamic> m) => _Waypoint(
    id: (m['id'] ?? '') as String,
    name: (m['name'] ?? '') as String,
    lat: (m['lat'] as num).toDouble(),
    lon: (m['lon'] as num).toDouble(),
    altMeters: (m['alt'] as num?)?.toDouble(),
    type: (m['type'] ?? 'User') as String,
    createdAt:
        DateTime.tryParse((m['createdAt'] ?? '') as String) ?? DateTime.now(),
  );
}

class _MovingMapScreenState extends State<MovingMapScreen> {
  final MapController _mapController = MapController();
  // Info bar state
  bool _showInfoBar = false;
  DateTime? _flightStart;
  int? _selectedAirspaceIdx;
  double _mapZoom = 10.0;
  bool _autoCenter = false;
  bool _headingUp = false;
  bool _showPowerLines = false;
  bool _showAirspace = false;
  // Weather toggles
  bool _showClouds = false;
  bool _showRain = false;
  bool _showWind = false;
  // Info bar position format
  bool _posDms = true;
  double? _currentAltitudeM;

  LatLng? _currentPosition;
  final LatLng _initialCenter = const LatLng(34.8723, 33.6243);
  final double _initialZoom = 10.0;

  // Airport data
  final List<_Airport> _airports = [];
  // Saved waypoints
  final List<_Waypoint> _waypoints = [];
  // Each airspace: {'perimeter': List<LatLng>, 'name': String?}
  List<Map<String, dynamic>> _airspacePerimeters = [];

  @override
  void initState() {
    super.initState();
    _initLocation();
    _loadAirports();
    _loadAirspace();
    _loadWaypoints();
    // Listen for map taps to reset airspace selection
    // (Handled in MapOptions.onTap below)
  }

  Future<void> _initLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    ).listen((Position pos) {
      setState(() {
        _currentPosition = LatLng(pos.latitude, pos.longitude);
        _currentAltitudeM = pos.altitude.isFinite ? pos.altitude : null;
      });
    });
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
        for (final f in features) {
          try {
            final m = f as Map<String, dynamic>;
            final props = (m['properties'] ?? {}) as Map<String, dynamic>;
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
    if (!mounted) return;
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
        for (final f in features) {
          try {
            final m = f as Map<String, dynamic>;
            final props = (m['properties'] ?? {}) as Map<String, dynamic>;
            final name = (props['name'] ?? props['NAME'] ?? '').toString();
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
                if (ring.length > 1)
                  perims.add({
                    'perimeter': ring,
                    'name': name.isNotEmpty ? name : null,
                  });
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
                    if (ring.length > 1)
                      perims.add({
                        'perimeter': ring,
                        'name': name.isNotEmpty ? name : null,
                      });
                  }
                }
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _airspacePerimeters = perims;
    });
  }

  Future<void> _onAirportTap(_Airport apt) async {
    if (!mounted) return;
    _showAirportDetails(apt);
  }

  Future<String?> _fetchAvwx(String type, String icao) async {
    try {
      final res = await http.get(
        Uri.parse('https://avwx.rest/api/$type/$icao'),
        headers: {"Authorization": kAvwxApiToken},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return (data['raw'] as String?) ?? (data['sanitized'] as String?);
      }
    } catch (_) {}
    return null;
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

  Widget _buildAirportInfo(_Airport a) {
    final p = a.properties;
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
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: _showInfoBar ? 56 : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Small FAB to toggle the info bar quickly
            FloatingActionButton.small(
              heroTag: 'fab-info',
              tooltip: _showInfoBar ? 'Hide info bar' : 'Show info bar',
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              onPressed: () {
                setState(() {
                  _showInfoBar = !_showInfoBar;
                  _flightStart ??= DateTime.now();
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
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentPosition ?? _initialCenter,
              initialZoom: _mapZoom,
              onTap: (_, __) {
                setState(() {
                  _selectedAirspaceIdx = null;
                  _mapZoom = _initialZoom;
                });
              },
              onLongPress: (_, latLng) => _showSaveWaypointDialog(latLng),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.aw139_cruise',
              ),
              if (_airports.isNotEmpty)
                MarkerLayer(
                  markers: _airports
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
              if (_waypoints.isNotEmpty)
                MarkerLayer(
                  markers: _waypoints.map((wp) {
                    final Color color;
                    final IconData icon;
                    switch (wp.type) {
                      case 'MOT':
                        color = Colors.deepOrangeAccent;
                        icon = Icons.add_location_alt;
                        break;
                      case 'Hospital':
                        color = Colors.redAccent;
                        icon = Icons.local_hospital;
                        break;
                      case 'Helipad':
                        color = Colors.lightBlueAccent;
                        icon = Icons.flight;
                        break;
                      default:
                        color = Colors.orangeAccent;
                        icon = Icons.place;
                    }
                    return Marker(
                      point: LatLng(wp.lat, wp.lon),
                      width: 160,
                      height: 60,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, color: color, size: 28),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black87,
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
                    );
                  }).toList(),
                ),
              if (_showAirspace && _airspacePerimeters.isNotEmpty) ...[
                PolylineLayer(
                  polylines: _airspacePerimeters.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final asp = entry.value;
                    return Polyline(
                      points: asp['perimeter'] as List<LatLng>,
                      color: Colors.red.withAlpha((0.7 * 255).toInt()),
                      strokeWidth: _selectedAirspaceIdx == idx ? 4.0 : 2.0,
                    );
                  }).toList(),
                ),
                // Add airspace name labels at centroid
                MarkerLayer(
                  markers: _airspacePerimeters
                      .asMap()
                      .entries
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
                                color: selected
                                    ? Colors.red.withAlpha(200)
                                    : Colors.red.withAlpha(140),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                asp['name'],
                                style: TextStyle(
                                  color: Colors.white,
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
              if (_showClouds)
                Opacity(
                  opacity: 0.7,
                  child: TileLayer(
                    urlTemplate:
                        'https://tile.openweathermap.org/map/clouds_new/{z}/{x}/{y}.png?appid=$kOpenWeatherApiKey',
                  ),
                ),
              if (_showRain)
                Opacity(
                  opacity: 0.6,
                  child: TileLayer(
                    urlTemplate:
                        'https://tile.openweathermap.org/map/precipitation_new/{z}/{x}/{y}.png?appid=$kOpenWeatherApiKey',
                  ),
                ),
              if (_showWind)
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
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.blue,
                        size: 30,
                      ),
                    ),
                  ],
                ),
            ],
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
                  child: PopupMenuButton<String>(
                    tooltip: 'Map options',
                    iconColor: Colors.white,
                    icon: const Icon(Icons.tune),
                    onSelected: (value) {
                      setState(() {
                        if (value == 'autoCenter') _autoCenter = !_autoCenter;
                        if (value == 'headingUp') _headingUp = !_headingUp;
                        if (value == 'powerLines') {
                          _showPowerLines = !_showPowerLines;
                        }
                        if (value == 'airspace') _showAirspace = !_showAirspace;
                        if (value == 'clouds') _showClouds = !_showClouds;
                        if (value == 'rain') _showRain = !_showRain;
                        if (value == 'wind') _showWind = !_showWind;
                        if (value == 'posDms') _posDms = !_posDms;
                        if (value == 'waypoints') {
                          // Open waypoints folder view without toggling anything
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _openWaypointsFolder();
                          });
                        }
                      });
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'waypoints',
                        child: Row(
                          children: const [
                            Icon(Icons.folder, size: 20),
                            SizedBox(width: 8),
                            Text('Waypoints'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'posDms',
                        checked: _posDms,
                        child: const Text('Info bar: Position in DMS'),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'autoCenter',
                        checked: _autoCenter,
                        child: const Text('Auto Center on Aircraft'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'headingUp',
                        checked: _headingUp,
                        child: const Text('Heading Up'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'powerLines',
                        checked: _showPowerLines,
                        child: const Text('Show Power Lines'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'airspace',
                        checked: _showAirspace,
                        child: const Text('Show Airspace'),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        enabled: false,
                        child: Text(
                          'Weather',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.orangeAccent,
                          ),
                        ),
                      ),
                      CheckedPopupMenuItem(
                        value: 'clouds',
                        checked: _showClouds,
                        child: const Text('Show Clouds'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'rain',
                        checked: _showRain,
                        child: const Text('Show Rain'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'wind',
                        checked: _showWind,
                        child: const Text('Show Wind'),
                      ),
                    ],
                  ),
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
                color: Colors.black.withOpacity(0.92),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _InfoItem(label: 'ETE', value: '--'),
                    _InfoItem(label: 'Dist', value: '--'),
                    _InfoItem(
                      label: 'GPS ALT',
                      value: _currentAltitudeM != null
                          ? '${(_currentAltitudeM! * 3.28084).round()} ft'
                          : '--',
                    ),
                    _InfoItem(label: 'Flight Time', value: _formatFlightTime()),
                    GestureDetector(
                      onLongPress: _saveCurrentPosAsMot,
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
        });
      }
    } catch (_) {}
  }

  Future<void> _persistWaypoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _waypoints.map((e) => e.toJson()).toList();
      await prefs.setString('waypoints', jsonEncode(list));
    } catch (_) {}
  }

  void _addWaypoint(_Waypoint wp, {bool silent = false}) {
    setState(() {
      _waypoints.add(wp);
    });
    _persistWaypoints();
    if (!silent) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved waypoint "${wp.name}"')));
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
              Text('Lat: ${latLng.latitude.toStringAsFixed(6)}'),
              Text('Lon: ${latLng.longitude.toStringAsFixed(6)}'),
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

  void _openWaypointsFolder() {
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
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Waypoints',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
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
                      icon: const Icon(Icons.add, color: Colors.orangeAccent),
                      label: const Text(
                        'Add',
                        style: TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              Expanded(
                child: _waypoints.isEmpty
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
                          return ListTile(
                            leading: Icon(
                              wp.type == 'Hospital'
                                  ? Icons.local_hospital
                                  : wp.type == 'Helipad'
                                  ? Icons.flight
                                  : wp.type == 'MOT'
                                  ? Icons.add_location_alt
                                  : Icons.place,
                              color: wp.type == 'Hospital'
                                  ? Colors.redAccent
                                  : wp.type == 'Helipad'
                                  ? Colors.lightBlueAccent
                                  : wp.type == 'MOT'
                                  ? Colors.deepOrangeAccent
                                  : Colors.orangeAccent,
                            ),
                            title: Text(
                              wp.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              '${_toDms(wp.lat, isLat: true)}, ${_toDms(wp.lon, isLat: false)}'
                              '${wp.altMeters != null ? ' • ${((wp.altMeters ?? 0) * 3.28084).round()} ft' : ''}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _mapController.move(LatLng(wp.lat, wp.lon), 13.0);
                            },
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Actions',
                              icon: const Icon(
                                Icons.more_vert,
                                color: Colors.white70,
                              ),
                              onSelected: (v) {
                                if (v == 'copy_dms') {
                                  final text =
                                      '${_toDms(wp.lat, isLat: true)}, ${_toDms(wp.lon, isLat: false)}';
                                  Clipboard.setData(ClipboardData(text: text));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Copied DMS to clipboard'),
                                    ),
                                  );
                                } else if (v == 'copy_dec') {
                                  final text =
                                      '${wp.lat.toStringAsFixed(6)}, ${wp.lon.toStringAsFixed(6)}';
                                  Clipboard.setData(ClipboardData(text: text));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Copied decimal coords to clipboard',
                                      ),
                                    ),
                                  );
                                } else if (v == 'delete') {
                                  setState(() {
                                    _waypoints.removeAt(i);
                                  });
                                  _persistWaypoints();
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
                                PopupMenuDivider(),
                                PopupMenuItem(
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
                          'Latitude (DMS, e.g. 34°56\'12\"N or 34 56 12 N)',
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
                          'Longitude (DMS, e.g. 33°37\'06\"E or 33 37 06 E)',
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
          setState(() {});
          await _persistWaypoints();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Imported JSON waypoints')),
          );
        }
      } catch (_) {
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
        setState(() {});
        await _persistWaypoints();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Imported GPX waypoints')));
      } catch (_) {
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
        setState(() {});
        await _persistWaypoints();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Imported KML waypoints')));
      } catch (_) {
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
    final d = DateTime.now().difference(_flightStart!);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${s}s';
  }
}
