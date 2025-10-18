import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

double kgToLbs(double kg) => kg * 2.2046226218;

class CruiseReportData {
  // Generated timestamp
  final DateTime generated = DateTime.now();

  // Core
  final double endurance;
  final double estimatedRange;
  final double missionDistance;
  final double missionDuration;
  final double fuelRemaining; // kg
  final bool lowFuel;

  // Flight params
  final double requiredTorque;
  final double cruiseSpeed;
  final double altitude;
  final double temperature;
  final double fuelBurnPerHour; // kg/hr
  final double hoistMinutes;
  final double hoistFuel; // kg

  // Coords (DMS)
  final String? originDmsLat;
  final String? originDmsLon;
  final String? destDmsLat;
  final String? destDmsLon;

  // AI summary
  final double? aiAlt;
  final double? aiIas;
  final double? aiTailOut;
  final double? aiTailBack;

  // Winds (alt ft -> tailwind)
  final Map<int, double> windsAloft;

  // Timeline (kg at source)
  final List<Map<String, double>>? fuelRemainingTimelineKg;

  // NEW: display units flag
  final bool isBell412;

  CruiseReportData({
    // Core
    required this.endurance,
    required this.estimatedRange,
    required this.missionDistance,
    required this.missionDuration,
    required this.fuelRemaining,
    required this.lowFuel,

    // Flight params
    required this.requiredTorque,
    required this.cruiseSpeed,
    required this.altitude,
    required this.temperature,
    required this.fuelBurnPerHour,
    required this.hoistMinutes,
    required this.hoistFuel,

    // Coords
    this.originDmsLat,
    this.originDmsLon,
    this.destDmsLat,
    this.destDmsLon,

    // AI
    this.aiAlt,
    this.aiIas,
    this.aiTailOut,
    this.aiTailBack,

    // Winds
    required this.windsAloft,

    // Timeline
    this.fuelRemainingTimelineKg,

    // Units
    required this.isBell412,
  });
}

class CruiseReportExporter {
  static pw.Widget _kv(String k, String v) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Container(
        width: 155,
        padding: const pw.EdgeInsets.only(right: 6),
        child: pw.Text(k, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      ),
      pw.Expanded(child: pw.Text(v)),
    ],
  );

  static pw.Widget _timelineTable(
    List<Map<String, double>> pts, {
    required bool isBell412,
  }) {
    if (pts.isEmpty) return pw.SizedBox.shrink();
    final unit = isBell412 ? 'lbs' : 'kg';

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 12),
        pw.Text(
          'Fuel Remaining every 20 min',
          style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        pw.Table(
          border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey600),
          columnWidths: {
            0: const pw.FixedColumnWidth(60),
            1: const pw.FlexColumnWidth(),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey300),
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Text(
                    'T+min',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Text(
                    'Fuel ($unit)',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ),
              ],
            ),
            ...pts.map((p) {
              final mins = (p['minute'] ?? 0).toStringAsFixed(0);
              final kg = (p['remainingKg'] ?? 0);
              final val = isBell412 ? kgToLbs(kg) : kg;
              return pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(mins),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(val.round().toString()),
                  ),
                ],
              );
            }),
          ],
        ),
      ],
    );
  }

  // ...existing code...
  static pw.Widget _windsTable(Map<int, double> winds) {
    if (winds.isEmpty) return pw.SizedBox.shrink();
    final entries = winds.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 12),
        pw.Table(
          border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey600),
          columnWidths: {
            0: const pw.FixedColumnWidth(90),
            1: const pw.FlexColumnWidth(),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey300),
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Text(
                    'Altitude (ft)',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Text(
                    'Tailwind (kt)',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ),
              ],
            ),
            ...entries.map(
              (e) => pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text('${e.key}'),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(e.value.toStringAsFixed(0)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
  // ...existing code...

  static Future<Uint8List> buildPdf(CruiseReportData d) async {
    final unit = d.isBell412 ? 'lbs' : 'kg';
    final burnUnit = d.isBell412 ? 'lbs/hr' : 'kg/hr';

    final fuelRemainDisp = d.isBell412
        ? kgToLbs(d.fuelRemaining)
        : d.fuelRemaining;
    final burnDisp = d.isBell412
        ? kgToLbs(d.fuelBurnPerHour)
        : d.fuelBurnPerHour;
    final hoistFuelDisp = d.isBell412 ? kgToLbs(d.hoistFuel) : d.hoistFuel;

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(margin: const pw.EdgeInsets.all(28)),
        build: (_) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              'AW139 Cruise Report',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Text('Generated: ${d.generated.toIso8601String()}'),
          pw.SizedBox(height: 12),
          pw.Divider(),
          _kv('Endurance', '${d.endurance.toStringAsFixed(2)} h'),
          _kv('Estimated Range', '${d.estimatedRange.toStringAsFixed(0)} NM'),
          _kv(
            'Mission Distance (1-way)',
            '${d.missionDistance.toStringAsFixed(0)} NM',
          ),
          _kv('Mission Duration', '${d.missionDuration.toStringAsFixed(2)} h'),
          _kv(
            'Fuel Remaining',
            '${fuelRemainDisp.toStringAsFixed(0)} $unit${d.lowFuel ? ' (LOW)' : ''}',
          ),
          _kv('Fuel Burn (hr)', '${burnDisp.toStringAsFixed(0)} $burnUnit'),
          _kv('Torque Required', '${d.requiredTorque.ceil()} %'),
          _kv('Cruise Speed', '${d.cruiseSpeed.toStringAsFixed(0)} kt'),
          _kv('Altitude', '${d.altitude.toStringAsFixed(0)} ft'),
          _kv('Temperature', '${d.temperature.toStringAsFixed(0)} °C'),
          _kv('Hoist Time', '${d.hoistMinutes.toStringAsFixed(0)} min'),
          _kv('Hoist Fuel', '${hoistFuelDisp.toStringAsFixed(0)} $unit'),
          if (d.originDmsLat != null && d.originDmsLon != null)
            _kv('Origin', '${d.originDmsLat}  ${d.originDmsLon}'),
          if (d.destDmsLat != null && d.destDmsLon != null)
            _kv('Destination', '${d.destDmsLat}  ${d.destDmsLon}'),
          if (d.aiAlt != null ||
              d.aiIas != null ||
              (d.aiTailOut != null && d.aiTailBack != null)) ...[
            pw.SizedBox(height: 10),
            pw.Text(
              'AI Optimization',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            if (d.aiAlt != null)
              _kv('AI Altitude', '${d.aiAlt!.toStringAsFixed(0)} ft'),
            if (d.aiIas != null)
              _kv('AI IAS', '${d.aiIas!.toStringAsFixed(0)} kt'),
            if (d.aiTailOut != null && d.aiTailBack != null)
              _kv(
                'AI Tailwind Out/Back',
                '${d.aiTailOut!.toStringAsFixed(0)} / ${d.aiTailBack!.toStringAsFixed(0)} kt',
              ),
          ],
          // Winds Aloft section (add this before the timeline)
          if (d.windsAloft.isNotEmpty) ...[
            pw.SizedBox(height: 10),
            pw.Text(
              'Winds Aloft',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            _windsTable(d.windsAloft),
          ],
          if ((d.fuelRemainingTimelineKg ?? []).isNotEmpty)
            _timelineTable(d.fuelRemainingTimelineKg!, isBell412: d.isBell412),
          pw.SizedBox(height: 18),
          pw.Text(
            'Advisory only. Verify with AFM / SOP.',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ],
      ),
    );
    return doc.save();
  }

  static Future<void> preview(CruiseReportData d) async {
    final data = await buildPdf(d);
    await Printing.layoutPdf(onLayout: (_) async => data);
  }

  static Future<void> share(CruiseReportData d) async {
    final data = await buildPdf(d);
    await Printing.sharePdf(bytes: data, filename: 'aw139_cruise_report.pdf');
  }

  // Simple winds-only table (Altitude ft, Tailwind kt)
  static pw.Widget _windsOnlyTable(String title, Map<int, double>? winds) {
    if (winds == null || winds.isEmpty) return pw.SizedBox.shrink();
    final entries = winds.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 10),
        pw.Text(
          title,
          style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        pw.Table(
          border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey600),
          columnWidths: {
            0: const pw.FixedColumnWidth(90),
            1: const pw.FlexColumnWidth(),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey300),
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Text(
                    'Altitude (ft)',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Text(
                    'Tailwind (kt)',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ),
              ],
            ),
            ...entries.map(
              (e) => pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text('${e.key}'),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(e.value.toStringAsFixed(0)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Build a PDF that contains ONLY winds aloft (departure/destination)
  static Future<Uint8List> _buildWindsOnlyPdf({
    Map<int, double>? departure,
    Map<int, double>? destination,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(margin: const pw.EdgeInsets.all(28)),
        build: (_) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              'Winds Aloft',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if ((departure ?? {}).isEmpty && (destination ?? {}).isEmpty)
            pw.Text('No winds aloft data available.'),
          if ((departure ?? {}).isNotEmpty)
            _windsOnlyTable('Departure Winds Aloft', departure),
          if ((destination ?? {}).isNotEmpty)
            _windsOnlyTable('Destination Winds Aloft', destination),
          pw.SizedBox(height: 16),
          pw.Text(
            'Advisory only. Verify with official weather sources.',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ],
      ),
    );
    return doc.save();
  }

  // Public: preview the winds-only PDF
  static Future<void> previewWindsOnly({
    Map<int, double>? departure,
    Map<int, double>? destination,
  }) async {
    final data = await _buildWindsOnlyPdf(
      departure: departure,
      destination: destination,
    );
    await Printing.layoutPdf(onLayout: (_) async => data);
  }
}
