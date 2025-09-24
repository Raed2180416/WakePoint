// Annotated copy of lib/services/navigation_service.dart
// Purpose: Explain global navigator key for routing from services.

import 'package:flutter/widgets.dart'; // Navigator and GlobalKey

class NavigationService {
  // Global navigator key so non-UI services (e.g., notifications) can push routes
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
}
