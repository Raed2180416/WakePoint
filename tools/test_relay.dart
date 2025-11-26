import 'dart:io';
import 'dart:async';

void main() async {
  print('Starting Relay Server Test...');

  // 1. Connect Client A
  final clientA = await WebSocket.connect('ws://localhost:8080');
  print('Client A connected');

  // 2. Connect Client B
  final clientB = await WebSocket.connect('ws://localhost:8080');
  print('Client B connected');

  final completer = Completer<void>();

  // 3. Client B listens
  clientB.listen((message) {
    print('Client B received: $message');
    if (message == 'Hello from A') {
      print('✅ TEST PASSED: Message received correctly.');
      completer.complete();
    } else {
      print('❌ TEST FAILED: Unexpected message.');
      completer.completeError('Unexpected message');
    }
  });

  // 4. Client A sends message
  print('Client A sending: "Hello from A"');
  clientA.add('Hello from A');

  // Wait for result
  try {
    await completer.future.timeout(Duration(seconds: 2));
  } catch (e) {
    print('❌ TEST FAILED: Timeout or Error - $e');
    exit(1);
  } finally {
    await clientA.close();
    await clientB.close();
    exit(0);
  }
}
