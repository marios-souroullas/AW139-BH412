import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

class CruiseReportData {
  final DateTime generated = DateTime.now();
  final double endurance;
  final double estimatedRange;
  final double missionDistance;
  final double missionDuration;
  final double fuelRemaining;
  final bool lowFuel;
  final double requiredTorque;
  final double cruiseSpeed;
  final double altitude;
  final double temperature;
  final double fuelBurnPerHour;
  final double hoistMinutes;
  final double hoistFuel;
  final String? originDmsLat;
  final String? originDmsLon;
  final String? destDmsLat;
  final String? destDmsLon;
  final double? aiAlt;
  final double? aiIas;
  final double? aiTailOut;
  final double? aiTailBack;

  final Map<int, double> windsAloft;
  CruiseReportData({
    required this.endurance,
    required this.estimatedRange,
    required this.missionDistance,
    required this.missionDuration,
    required this.fuelRemaining,
    required this.lowFuel,
    required this.requiredTorque,
    required this.cruiseSpeed,
    required this.altitude,
    required this.temperature,
    required this.fuelBurnPerHour,
    required this.hoistMinutes,
    required this.hoistFuel,
    this.originDmsLat,
    this.originDmsLon,
    this.destDmsLat,
    this.destDmsLon,
    this.aiAlt,
    this.aiIas,
    this.aiTailOut,
    this.aiTailBack,
    required this.windsAloft,
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

  static Future<Uint8List> buildPdf(CruiseReportData d) async {
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
            '${d.fuelRemaining.toStringAsFixed(0)} kg${d.lowFuel ? ' (LOW)' : ''}',
          ),
          _kv(
            'Fuel Burn (hr)',
            '${d.fuelBurnPerHour.toStringAsFixed(0)} kg/hr',
          ),
          _kv('Torque Required', '${d.requiredTorque.ceil()} %'),
          _kv('Cruise Speed', '${d.cruiseSpeed.toStringAsFixed(0)} kt'),
          _kv('Altitude', '${d.altitude.toStringAsFixed(0)} ft'),
          _kv('Temperature', '${d.temperature.toStringAsFixed(0)} °C'),
          _kv('Hoist Time', '${d.hoistMinutes.toStringAsFixed(0)} min'),
          _kv('Hoist Fuel', '${d.hoistFuel.toStringAsFixed(0)} kg'),
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
    final file = XFile.fromData(
      data,
      name: 'aw139_cruise_report.pdf',
      mimeType: 'application/pdf',
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [file],
        // No text or subject here!
      ),
    );
  }
}
