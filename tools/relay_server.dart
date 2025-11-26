import 'dart:io';

void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('Relay Server listening on ws://localhost:8080');

  final clients = <WebSocket>[];

  await for (HttpRequest request in server) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then((socket) {
        print('Client connected');
        clients.add(socket);

        socket.listen(
          (message) {
            // Broadcast to all other clients
            for (final client in clients) {
              if (client != socket && client.readyState == WebSocket.open) {
                client.add(message);
              }
            }
          },
          onDone: () {
            print('Client disconnected');
            clients.remove(socket);
          },
          onError: (error) {
            print('Client error: $error');
            clients.remove(socket);
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
