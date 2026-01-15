/// Simulation control buttons for the dashboard.
library;

import 'package:flutter/material.dart';

import 'simulation_state.dart';

/// Control panel for simulation actions.
class SimulationControls extends StatelessWidget {
  const SimulationControls({
    super.key,
    required this.state,
    required this.onStart,
    required this.onStop,
    required this.onStartDeviation,
    required this.onStopDeviation,
    required this.onGoBackToRoute,
    required this.onPause,
    required this.onResume,
    this.hasPreviousRoutes = false,
    this.onRevertToPreviousRoute,
  });

  /// Current simulation state.
  final SimulationState state;

  /// Called when simulation should start.
  final VoidCallback onStart;

  /// Called when simulation should stop.
  final VoidCallback onStop;

  /// Called when deviation should start.
  final VoidCallback onStartDeviation;

  /// Called when deviation should stop.
  final VoidCallback onStopDeviation;

  /// Called when returning to route.
  final VoidCallback onGoBackToRoute;

  /// Called when pausing.
  final VoidCallback onPause;

  /// Called when resuming.
  final VoidCallback onResume;

  /// Whether there are previous routes available to revert to.
  final bool hasPreviousRoutes;

  /// Called when user wants to revert to a previous route.
  final VoidCallback? onRevertToPreviousRoute;

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
            // State indicator
            _buildStateChip(),
            const SizedBox(height: 16),
            // Control buttons
            _buildControlButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildStateChip() {
    final (label, color, icon) = switch (state) {
      SimulationState.idle => ('Ready', Colors.grey, Icons.play_circle_outline),
      SimulationState.onRoute => (
        'Following Route',
        Colors.green,
        Icons.directions,
      ),
      SimulationState.deviating => (
        'Deviating...',
        Colors.orange,
        Icons.alt_route,
      ),
      SimulationState.returning => ('Returning...', Colors.blue, Icons.undo),
      SimulationState.paused => ('Paused', Colors.amber, Icons.pause),
    };

    return Chip(
      avatar: Icon(icon, size: 18, color: Colors.white),
      label: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      backgroundColor: color,
    );
  }

  Widget _buildControlButtons() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // Start/Stop simulation
        if (state == SimulationState.idle)
          _ActionButton(
            icon: Icons.play_arrow,
            label: 'Start',
            color: Colors.green,
            onPressed: onStart,
          ),

        if (state != SimulationState.idle)
          _ActionButton(
            icon: Icons.stop,
            label: 'Stop',
            color: Colors.red,
            onPressed: onStop,
          ),

        // Pause/Resume
        if (state == SimulationState.onRoute ||
            state == SimulationState.deviating ||
            state == SimulationState.returning)
          _ActionButton(
            icon: Icons.pause,
            label: 'Pause',
            color: Colors.amber.shade700,
            onPressed: onPause,
          ),

        if (state == SimulationState.paused)
          _ActionButton(
            icon: Icons.play_arrow,
            label: 'Resume',
            color: Colors.green,
            onPressed: onResume,
          ),

        // Deviation controls
        if (state == SimulationState.onRoute)
          _ActionButton(
            icon: Icons.alt_route,
            label: 'Start Deviation',
            color: Colors.orange,
            onPressed: onStartDeviation,
          ),

        if (state == SimulationState.deviating) ...[
          _ActionButton(
            icon: Icons.close,
            label: 'Stop Deviation',
            color: Colors.red.shade400,
            onPressed: onStopDeviation,
          ),
          _ActionButton(
            icon: Icons.undo,
            label: 'Go Back to Route',
            color: Colors.blue,
            onPressed: onGoBackToRoute,
          ),
        ],

        if (state == SimulationState.returning)
          _ActionButton(
            icon: Icons.alt_route,
            label: 'Deviate Again',
            color: Colors.orange,
            onPressed: onStartDeviation,
          ),

        // Revert to previous route - shows when there are inactive routes available
        // This allows going back to a previous route AFTER a reroute has completed
        if (hasPreviousRoutes &&
            onRevertToPreviousRoute != null &&
            state != SimulationState.deviating)
          _ActionButton(
            icon: Icons.history,
            label: 'Revert to Previous Route',
            color: Colors.purple,
            onPressed: onRevertToPreviousRoute!,
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      onPressed: onPressed,
    );
  }
}
