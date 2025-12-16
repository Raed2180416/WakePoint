import 'dart:io';
import 'dart:async';
import 'dart:convert';

void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8081);
  print('Relay Server listening on ws://localhost:8081');
  print('Heartbeat enabled: ping every 30s, timeout after 60s');

  final clients = <WebSocket>[];
  final clientLastPong = <WebSocket, DateTime>{};

  // Heartbeat timer: ping all clients every 30 seconds
  Timer.periodic(const Duration(seconds: 30), (timer) {
    final now = DateTime.now();
    final deadClients = <WebSocket>[];

    for (final client in clients) {
      if (client.readyState == WebSocket.open) {
        // Check if client responded to last ping (within 60s)
        final lastPong = clientLastPong[client];
        if (lastPong != null && now.difference(lastPong).inSeconds > 60) {
          print('Client timed out (no pong), closing connection');
          deadClients.add(client);
          client.close();
        } else {
          // Send ping
          try {
            client.add(
              jsonEncode({
                'type': 'ping',
                'timestamp': now.millisecondsSinceEpoch,
              }),
            );
          } catch (e) {
            print('Failed to send ping: $e');
            deadClients.add(client);
          }
        }
      } else {
        deadClients.add(client);
      }
    }

    // Clean up dead clients
    for (final dead in deadClients) {
      clients.remove(dead);
      clientLastPong.remove(dead);
    }
  });

  await for (HttpRequest request in server) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then((socket) {
        print('Client connected (total: ${clients.length + 1})');
        clients.add(socket);
        clientLastPong[socket] = DateTime.now(); // Initialize last pong time

        socket.listen(
          (message) {
            try {
              // Try to parse message to check for pong
              final json = jsonDecode(message);
              if (json['type'] == 'pong') {
                // Update last pong time
                clientLastPong[socket] = DateTime.now();
                return; // Don't broadcast pong messages
              }
            } catch (_) {
              // Not JSON or not a pong, continue to broadcast
            }

            // Broadcast to all other clients
            for (final client in clients) {
              if (client != socket && client.readyState == WebSocket.open) {
                try {
                  client.add(message);
                } catch (e) {
                  print('Failed to broadcast to client: $e');
                }
              }
            }
          },
          onDone: () {
            print('Client disconnected (remaining: ${clients.length - 1})');
            clients.remove(socket);
            clientLastPong.remove(socket);
          },
          onError: (error) {
            print('Client error: $error');
            clients.remove(socket);
            clientLastPong.remove(socket);
          },
        );
      });
    } else {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
    }
  }
}
