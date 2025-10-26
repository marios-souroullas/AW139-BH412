import 'package:latlong2/latlong.dart';

class RouteExportKml {
  static String buildKml(List<LatLng> points, {String name = 'AW139 Route'}) {
    final coords = points
        .map(
          (p) =>
              '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)},0',
        )
        .join(' ');
    return '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>$name</name>
    <Placemark>
      <name>$name</name>
      <Style>
        <LineStyle><color>ff0000ff</color><width>4</width></LineStyle>
      </Style>
      <LineString>
        <tessellate>1</tessellate>
        <coordinates>$coords</coordinates>
      </LineString>
    </Placemark>
  </Document>
</kml>
''';
  }

  // Convert ARGB (0xAARRGGBB) to KML ABGR hex "aabbggrr"
  static String _argbToKmlAbgr(int argb) {
    final a = (argb >> 24) & 0xFF;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    String hh(int v) => v.toRadixString(16).padLeft(2, '0');
    return '${hh(a)}${hh(b)}${hh(g)}${hh(r)}';
  }

  static String _coords(List<LatLng> pts) {
    final sb = StringBuffer();
    for (final p in pts) {
      sb.write('${p.longitude},${p.latitude},0 ');
    }
    return sb.toString().trim();
  }

  // Build KML with a Route folder and a separate SAR Patterns folder
  static String buildKmlWithSar(
    List<LatLng> routePts, {
    String name = 'Route',
    Map<String, List<LatLng>>? sarPatterns,
    Map<String, int>? sarColorArgbById, // ARGB colors per SAR id
  }) {
    final sar = sarPatterns ?? const <String, List<LatLng>>{};
    final docName = name;
    final routeColor = 'ff0000ff'; // ABGR (opaque blue)
    final sb = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
      ..writeln('<Document>')
      ..writeln('<name>$docName</name>')
      ..writeln(
        '<Style id="routeLine"><LineStyle><color>$routeColor</color><width>4</width></LineStyle></Style>',
      );

    // SAR styles per id
    for (final id in sar.keys) {
      final argb = (sarColorArgbById?[id]) ?? 0xFFFDD835; // default amber
      final abgr = _argbToKmlAbgr(argb);
      sb.writeln(
        '<Style id="sar_$id"><LineStyle><color>$abgr</color><width>3</width></LineStyle></Style>',
      );
    }

    // Route folder
    sb
      ..writeln('<Folder><name>Route</name>')
      ..writeln('<Placemark><name>Route</name><styleUrl>#routeLine</styleUrl>')
      ..writeln(
        '<LineString><tessellate>1</tessellate><coordinates>${_coords(routePts)}</coordinates></LineString>',
      )
      ..writeln('</Placemark>')
      ..writeln('</Folder>');

    // SAR folder
    if (sar.isNotEmpty) {
      sb.writeln('<Folder><name>SAR Patterns</name>');
      for (final e in sar.entries) {
        if (e.value.length < 2) continue;
        final id = e.key;
        sb
          ..writeln(
            '<Placemark><name>SAR $id</name><styleUrl>#sar_$id</styleUrl>',
          )
          ..writeln(
            '<LineString><tessellate>1</tessellate><coordinates>${_coords(e.value)}</coordinates></LineString>',
          )
          ..writeln('</Placemark>');
      }
      sb.writeln('</Folder>');
    }

    sb
      ..writeln('</Document>')
      ..writeln('</kml>');
    return sb.toString();
  }
}
