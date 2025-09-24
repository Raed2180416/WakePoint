// Annotated copy of lib/services/route_queue.dart
// Purpose: Explain an in-memory bounded queue of routes with active index.

import 'package:geowake2/models/route_models.dart'; // RouteModel with isActive flag

/// Singleton class to manage a queue of routes.
class RouteQueue {
  static final RouteQueue instance = RouteQueue._internal(); // Global instance
  final int maxSize = 8;              // Upper bound for queue length
  final List<RouteModel> _routes = []; // Storage for routes
  int activeRouteIndex = 0;           // Index of active route

  RouteQueue._internal(); // Private constructor

  /// Adds a new route to the queue. If full, evict oldest and adjust active index.
  void addRoute(RouteModel route) {
    if (_routes.length >= maxSize) {
      _routes.removeAt(0);
      if (activeRouteIndex > 0) activeRouteIndex--; // Keep active consistent
    }
    _routes.add(route);
    activeRouteIndex = _routes.length - 1; // Newly added becomes active
    _setActiveFlags();
  }

  /// Returns the currently active route, if any.
  RouteModel? getActiveRoute() {
    if (_routes.isEmpty) return null;
    return _routes[activeRouteIndex];
  }

  /// Set specific index as active when valid.
  void setActiveRoute(int index) {
    if (index >= 0 && index < _routes.length) {
      activeRouteIndex = index;
      _setActiveFlags();
    }
  }

  /// Update each route's isActive flag to reflect current active index.
  void _setActiveFlags() {
    for (int i = 0; i < _routes.length; i++) {
      _routes[i].isActive = (i == activeRouteIndex);
    }
  }

  /// Get an unmodifiable view of the routes list.
  List<RouteModel> get routes => List.unmodifiable(_routes);
}
