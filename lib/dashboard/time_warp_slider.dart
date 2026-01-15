/// Time warp slider control for simulation dashboard.
library;

import 'package:flutter/material.dart';

/// Slider for controlling time warp factor (1x - 50x).
class TimeWarpSlider extends StatelessWidget {
  const TimeWarpSlider({
    super.key,
    required this.warpFactor,
    required this.onChanged,
    this.enabled = true,
  });

  /// Current warp factor (1.0 - 50.0).
  final double warpFactor;

  /// Called when warp factor changes.
  final ValueChanged<double> onChanged;

  /// Whether the slider is enabled.
  final bool enabled;

  /// Preset warp values.
  static const presets = [1.0, 5.0, 10.0, 20.0, 35.0, 50.0];

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
                  'Time Warp',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _getWarpColor(warpFactor),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${warpFactor.toStringAsFixed(0)}x',
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
                activeTrackColor: _getWarpColor(warpFactor),
                thumbColor: _getWarpColor(warpFactor),
                overlayColor: _getWarpColor(warpFactor).withValues(alpha: 0.2),
              ),
              child: Slider(
                value: warpFactor.clamp(1.0, 50.0),
                min: 1,
                max: 50,
                divisions: 49,
                label: '${warpFactor.toStringAsFixed(0)}x',
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
                    final isActive = (warpFactor - preset).abs() < 0.5;
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
              _getWarpDescription(warpFactor),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Color _getWarpColor(double factor) {
    if (factor <= 1) return Colors.grey;
    if (factor <= 10) return Colors.green;
    if (factor <= 50) return Colors.blue;
    if (factor <= 100) return Colors.orange;
    if (factor <= 200) return Colors.deepOrange;
    return Colors.red;
  }

  String _getWarpDescription(double factor) {
    if (factor <= 1) {
      return 'Real-time';
    }
    if (factor <= 10) {
      return '1 real second = ${factor.toStringAsFixed(0)} simulated seconds';
    }
    if (factor <= 60) {
      return '1 real second = ${(factor / 60).toStringAsFixed(1)} simulated minutes';
    }
    return '1 real second = ${(factor / 60).toStringAsFixed(1)} simulated minutes';
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
        child: Text('${value.toStringAsFixed(0)}x'),
      ),
    );
  }
}
