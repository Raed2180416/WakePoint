// ignore_for_file: avoid_print
import 'dart:io';

void main() async {
  final path = 'd:/WakePoint/assets/logs/Nallur_to_Vijaynagar/Location.csv';
  final file = File(path);
  if (!file.existsSync()) {
    print('File not found: $path');
    return;
  }

  final lines = await file.readAsLines();
  if (lines.isEmpty) return;

  // Header: time,seconds_elapsed,...,speed (index 6),...
  // index 6 is speed.

  int total = 0;
  int zeroCount = 0;
  int sub05Count = 0;
  int sub08Count = 0;
  int sub10Count = 0;
  int sub20Count = 0;
  double minSpeed = double.infinity;
  double maxSpeed = -double.infinity;

  for (var i = 1; i < lines.length; i++) {
    final parts = lines[i].split(',');
    if (parts.length < 7) continue;

    try {
      final speed = double.parse(parts[6]);
      total++;
      if (speed < minSpeed) minSpeed = speed;
      if (speed > maxSpeed) maxSpeed = speed;

      if (speed == 0) zeroCount++;
      if (speed < 0.5) sub05Count++;
      if (speed < 0.8) sub08Count++;
      if (speed < 1.0) sub10Count++;
      if (speed < 2.0) sub20Count++;
    } catch (e) {
      // ignore
    }
  }

  print('Total Points: $total');
  print('Min Speed: $minSpeed');
  print('Max Speed: $maxSpeed');
  print(
    'Exact 0.0: $zeroCount (${(zeroCount / total * 100).toStringAsFixed(2)}%)',
  );
  print(
    '< 0.5: $sub05Count (${(sub05Count / total * 100).toStringAsFixed(2)}%)',
  );
  print(
    '< 0.8: $sub08Count (${(sub08Count / total * 100).toStringAsFixed(2)}%)',
  );
  print(
    '< 1.0: $sub10Count (${(sub10Count / total * 100).toStringAsFixed(2)}%)',
  );
  print(
    '< 2.0: $sub20Count (${(sub20Count / total * 100).toStringAsFixed(2)}%)',
  );
}
