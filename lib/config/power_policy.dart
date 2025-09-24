import 'package:geolocator/geolocator.dart';

class PowerPolicy {
  final LocationAccuracy accuracy;
  final int distanceFilterMeters;
  final Duration gpsDropoutBuffer;
  final Duration notificationTick;
  final Duration rerouteCooldown;

  const PowerPolicy({
    required this.accuracy,
    required this.distanceFilterMeters,
    required this.gpsDropoutBuffer,
    required this.notificationTick,
    required this.rerouteCooldown,
  });

  static PowerPolicy testing() => const PowerPolicy(
        accuracy: LocationAccuracy.high,
        distanceFilterMeters: 5,
        gpsDropoutBuffer: Duration(seconds: 2),
        notificationTick: Duration(milliseconds: 50),
        rerouteCooldown: Duration(seconds: 2),
      );
}

class PowerPolicyManager {
  static PowerPolicy forBatteryLevel(int levelPercent) {
    // Default/normal tier
    if (levelPercent > 50) {
      return const PowerPolicy(
        accuracy: LocationAccuracy.high,
        distanceFilterMeters: 20,
        gpsDropoutBuffer: Duration(seconds: 25),
        notificationTick: Duration(seconds: 1),
        rerouteCooldown: Duration(seconds: 20),
      );
    }
    // Medium tier
    if (levelPercent > 20) {
      return const PowerPolicy(
        accuracy: LocationAccuracy.medium,
        distanceFilterMeters: 35,
        gpsDropoutBuffer: Duration(seconds: 30),
        notificationTick: Duration(seconds: 2),
        rerouteCooldown: Duration(seconds: 25),
      );
    }
    // Low battery tier
    return const PowerPolicy(
      accuracy: LocationAccuracy.low,
      distanceFilterMeters: 50,
      gpsDropoutBuffer: Duration(seconds: 40),
      notificationTick: Duration(seconds: 3),
      rerouteCooldown: Duration(seconds: 30),
    );
  }
}
