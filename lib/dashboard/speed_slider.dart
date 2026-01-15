/// Speed slider control for simulation dashboard.
library;

import 'package:flutter/material.dart';

/// Slider for controlling simulated vehicle speed (1-160 km/h).
class SpeedSlider extends StatelessWidget {
  const SpeedSlider({
    super.key,
    required this.speedKmh,
    required this.onChanged,
    this.enabled = true,
  });

  /// Current speed in km/h.
  final double speedKmh;

  /// Called when speed changes.
  final ValueChanged<double> onChanged;

  /// Whether the slider is enabled.
  final bool enabled;

  /// Preset speed values in km/h.
  static const presets = [5.0, 20.0, 40.0, 60.0, 80.0, 120.0];

  /// Convert km/h to m/s.
  static double kmhToMps(double kmh) => kmh / 3.6;

  /// Convert m/s to km/h.
  static double mpsToKmh(double mps) => mps * 3.6;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with value
            Row(
              children: [
                const Icon(Icons.speed, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Speed',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _getSpeedColor(speedKmh),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${speedKmh.toStringAsFixed(0)} km/h',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Slider
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: _getSpeedColor(speedKmh),
                thumbColor: _getSpeedColor(speedKmh),
                overlayColor: _getSpeedColor(speedKmh).withValues(alpha: 0.2),
              ),
              child: Slider(
                value: speedKmh,
                min: 1,
                max: 160,
                divisions: 159,
                label: '${speedKmh.toStringAsFixed(0)} km/h',
                onChanged: enabled ? onChanged : null,
              ),
            ),
            const SizedBox(height: 8),
            // Preset buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  presets.map((preset) {
                    final isActive = (speedKmh - preset).abs() < 0.5;
                    return _PresetButton(
                      value: preset,
                      isActive: isActive,
                      enabled: enabled,
                      onPressed: () => onChanged(preset),
                    );
                  }).toList(),
            ),
            const SizedBox(height: 8),
            // Info text
            Text(
              _getSpeedDescription(speedKmh),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Color _getSpeedColor(double speed) {
    if (speed <= 20) return Colors.green;
    if (speed <= 40) return Colors.lightGreen;
    if (speed <= 60) return Colors.orange;
    if (speed <= 80) return Colors.deepOrange;
    return Colors.red;
  }

  String _getSpeedDescription(double speed) {
    if (speed <= 5) return 'Walking pace';
    if (speed <= 15) return 'Cycling speed';
    if (speed <= 30) return 'City driving';
    if (speed <= 60) return 'Urban highway';
    if (speed <= 100) return 'Highway driving';
    return 'High-speed driving';
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({
    required this.value,
    required this.isActive,
    required this.enabled,
    required this.onPressed,
  });

  final double value;
  final bool isActive;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: isActive ? Colors.blue : null,
          foregroundColor: isActive ? Colors.white : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          side: BorderSide(
            color: isActive ? Colors.blue : Colors.grey.shade400,
          ),
        ),
        onPressed: enabled ? onPressed : null,
        child: Text(value.toStringAsFixed(0)),
      ),
    );
  }
}
