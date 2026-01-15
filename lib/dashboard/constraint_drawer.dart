/// Slide-out drawer for constraint event logs.
library;

import 'package:flutter/material.dart';

import 'constraint_logger.dart';

/// Slide-out drawer showing constraint events.
class ConstraintDrawer extends StatelessWidget {
  const ConstraintDrawer({
    super.key,
    required this.events,
    required this.isOpen,
    required this.onToggle,
    this.onClear,
    this.width = 400,
  });

  /// Events to display.
  final List<ConstraintEvent> events;

  /// Whether the drawer is open.
  final bool isOpen;

  /// Called when toggle button is pressed.
  final VoidCallback onToggle;

  /// Called when clear button is pressed.
  final VoidCallback? onClear;

  /// Width of the open drawer.
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: isOpen ? width : 50,
      height: double.infinity,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 8,
        clipBehavior: Clip.hardEdge,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            bottomLeft: Radius.circular(16),
          ),
        ),
        child: isOpen ? _buildOpenDrawer(context) : _buildClosedDrawer(context),
      ),
    );
  }

  Widget _buildClosedDrawer(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 16),
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: onToggle,
          tooltip: 'Open constraint log',
        ),
        const SizedBox(height: 8),
        RotatedBox(
          quarterTurns: 3,
          child: Text(
            'Constraints (${events.length})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ),
        const Spacer(),
        // Event count badge
        if (events.isNotEmpty)
          Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _getLatestEventColor(),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${events.length}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildOpenDrawer(BuildContext context) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(16)),
          ),
          child: Row(
            children: [
              const Icon(Icons.list_alt),
              const SizedBox(width: 8),
              const Text(
                'Constraint Log',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const Spacer(),
              if (events.isNotEmpty && onClear != null)
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  onPressed: onClear,
                  tooltip: 'Clear logs',
                  iconSize: 20,
                ),
              Text(
                '${events.length} events',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: onToggle,
                tooltip: 'Close',
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Event list
        Expanded(
          child:
              events.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                    itemCount: events.length,
                    itemBuilder: (_, i) => _buildEventTile(events[i]),
                  ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text('No events yet', style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 8),
          Text(
            'Start the simulation to see\nconstraint events here',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildEventTile(ConstraintEvent event) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: _getEventColor(event.type), width: 4),
        ),
      ),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          backgroundColor: _getEventColor(event.type),
          radius: 12,
          child: Icon(_getEventIcon(event.type), size: 14, color: Colors.white),
        ),
        title: Text(
          event.title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        subtitle:
            event.description != null
                ? Text(
                  event.description!,
                  style: const TextStyle(fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                )
                : null,
        trailing: Text(
          _formatTime(event.timestamp),
          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
        ),
      ),
    );
  }

  Color _getEventColor(ConstraintEventType type) {
    return switch (type) {
      ConstraintEventType.deviationDetected => Colors.orange,
      ConstraintEventType.deviationSustained => Colors.deepOrange,
      ConstraintEventType.rerouteTriggered => Colors.blue,
      ConstraintEventType.rerouteSuccess => Colors.green,
      ConstraintEventType.rerouteFailed => Colors.red,
      ConstraintEventType.rerouteSkipped => Colors.amber,
      ConstraintEventType.terminationCheck => Colors.purple,
      ConstraintEventType.returnToRoute => Colors.teal,
      ConstraintEventType.backOnRoute => Colors.green,
      ConstraintEventType.alarmTriggered => Colors.red,
      ConstraintEventType.alarmStopped => Colors.grey,
      ConstraintEventType.speedChange => Colors.blue,
      ConstraintEventType.warpFactorChange => Colors.indigo,
      ConstraintEventType.info => Colors.blueGrey,
      ConstraintEventType.warning => Colors.amber,
      ConstraintEventType.error => Colors.red,
    };
  }

  IconData _getEventIcon(ConstraintEventType type) {
    return switch (type) {
      ConstraintEventType.deviationDetected => Icons.warning,
      ConstraintEventType.deviationSustained => Icons.timer,
      ConstraintEventType.rerouteTriggered => Icons.alt_route,
      ConstraintEventType.rerouteSuccess => Icons.check,
      ConstraintEventType.rerouteFailed => Icons.error,
      ConstraintEventType.rerouteSkipped => Icons.skip_next,
      ConstraintEventType.terminationCheck => Icons.rule,
      ConstraintEventType.returnToRoute => Icons.undo,
      ConstraintEventType.backOnRoute => Icons.check_circle,
      ConstraintEventType.alarmTriggered => Icons.alarm,
      ConstraintEventType.alarmStopped => Icons.alarm_off,
      ConstraintEventType.speedChange => Icons.speed,
      ConstraintEventType.warpFactorChange => Icons.fast_forward,
      ConstraintEventType.info => Icons.info,
      ConstraintEventType.warning => Icons.warning_amber,
      ConstraintEventType.error => Icons.error_outline,
    };
  }

  Color _getLatestEventColor() {
    if (events.isEmpty) return Colors.grey;
    return _getEventColor(events.last.type);
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}
