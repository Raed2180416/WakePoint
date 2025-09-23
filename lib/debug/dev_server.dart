import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as dev;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/debug/demo_tools.dart';

class DevServer {
  static HttpServer? _server;

  static Future<void> start({int port = 8765}) async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      dev.log('DevServer listening on 0.0.0.0:$port', name: 'DevServer');
      // ignore: unawaited_futures
      _server!.forEach(_handleRequest);
    } catch (e) {
      dev.log('DevServer failed to start: $e', name: 'DevServer');
    }
  }

  static Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      dev.log('DevServer request: $path', name: 'DevServer');
      if (path == '/health') {
        return _json(req, {'ok': true});
      }
      if (path == '/demo/journey') {
        LatLng? origin;
        final lat = double.tryParse(req.uri.queryParameters['lat'] ?? '');
        final lng = double.tryParse(req.uri.queryParameters['lng'] ?? '');
        if (lat != null && lng != null) {
          origin = LatLng(lat, lng);
        }
        await DemoRouteSimulator.startDemoJourney(origin: origin);
        return _json(req, {'status': 'started'});
      }
      if (path == '/demo/transfer') {
        await DemoRouteSimulator.triggerTransferAlarmDemo();
        return _json(req, {'status': 'transfer_triggered'});
      }
      if (path == '/demo/destination') {
        await DemoRouteSimulator.triggerDestinationAlarmDemo();
        return _json(req, {'status': 'destination_triggered'});
      }
      return _json(req, {'error': 'not_found', 'path': path}, status: HttpStatus.notFound);
    } catch (e) {
      return _json(req, {'error': e.toString()}, status: HttpStatus.internalServerError);
    }
  }

  static Future<void> _json(HttpRequest req, Map<String, dynamic> body, {int status = 200}) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}
