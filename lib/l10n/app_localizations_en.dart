// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'GeoWake';

  @override
  String get paywallTitle => 'GeoWake Pro';

  @override
  String get paywallHeadline => 'Your commute on autopilot.';

  @override
  String get paywallSubtitle =>
      'One-time purchase. Yours forever. No subscription.';

  @override
  String get paywallTrustStrip =>
      'Your never-late alarm is free forever. Pro adds convenience, not safety.';

  @override
  String paywallCta(String price) {
    return 'Unlock forever — $price';
  }

  @override
  String get paywallCtaBusy => 'Please wait…';

  @override
  String get paywallRewardedVideo =>
      'Watch a short video for a free day of Pro';

  @override
  String get paywallRestore => 'Restore purchase';

  @override
  String get paywallTerms => 'Terms';

  @override
  String get paywallPrivacy => 'Privacy';

  @override
  String get paywallSuccess => 'Welcome to GeoWake Pro 🎉';

  @override
  String get paywallPending =>
      'Payment processing — Pro will unlock automatically once it clears.';

  @override
  String get paywallFailed =>
      'Purchase didn\'t complete. You can try again anytime.';

  @override
  String get paywallRestored => 'Pro restored ✓';

  @override
  String get paywallNoPurchase => 'No previous purchase found.';

  @override
  String get paywallAlreadyPro => 'You\'re on GeoWake Pro';

  @override
  String get paywallThanks => 'Thanks for supporting GeoWake.';

  @override
  String get paywallDone => 'Done';

  @override
  String get paywallPendingBannerTitle => 'Payment processing…';

  @override
  String get paywallPendingBannerBody =>
      'Your UPI payment is being verified. Pro will unlock automatically once it clears — usually within a few minutes. You can close this screen.';

  @override
  String get featureGuardianMode => 'Guardian mode';

  @override
  String get featureGuardianModeDesc =>
      'Auto-share your journey with family + an \"arrived safely\" alert.';

  @override
  String get featureAntiTheftMode => 'Anti-theft mode';

  @override
  String get featureAntiTheftModeDesc =>
      'Loud alarm if someone snatches your phone while you sleep on transit.';

  @override
  String get featureCustomAlarm => 'Custom & escalating alarm';

  @override
  String get featureCustomAlarmDesc =>
      'Your own sounds, ramping volume that won\'t let you sleep through it.';

  @override
  String get featureHomeWidget => 'Home widget';

  @override
  String get featureHomeWidgetDesc => 'One-tap arm from your home screen.';

  @override
  String get featureAdFree => 'Ad-free';

  @override
  String get featureAdFreeDesc => 'No ads, anywhere.';

  @override
  String get antiTheftTitle => 'Anti-theft mode';

  @override
  String get antiTheftEnable => 'Enable anti-theft protection';

  @override
  String get antiTheftEnableDesc =>
      'Monitor for phone snatch detection while you sleep on transit.';

  @override
  String get antiTheftSensitivity => 'Sensitivity';

  @override
  String get antiTheftSensitivityLow => 'Low';

  @override
  String get antiTheftSensitivityMedium => 'Medium';

  @override
  String get antiTheftSensitivityHigh => 'High';

  @override
  String get antiTheftChargerAlert => 'Alert on charger removal';

  @override
  String get antiTheftChargerAlertDesc =>
      'Sound alarm if someone disconnects your charger while sleeping.';

  @override
  String get antiTheftCalibrating => 'Calibrating sensors…';

  @override
  String get antiTheftMonitoring => 'Monitoring active';

  @override
  String get antiTheftMonitoringDesc =>
      'Anti-theft is running. Your phone is being protected.';

  @override
  String get antiTheftHowItWorks => 'How it works';

  @override
  String get antiTheftHowItWorksBody =>
      'Uses your phone\'s accelerometer and gyroscope to detect sudden movements like a phone snatch. If triggered, a loud alarm sounds immediately. Calibration runs for 3 seconds when monitoring starts to learn your phone\'s resting state.';

  @override
  String get antiTheftProOnly => 'Pro feature';

  @override
  String get settingsGoPremium => 'Go Premium';

  @override
  String get settingsAntiTheftMode => 'Anti-theft mode';

  @override
  String get settingsGuardianMode => 'Guardian mode';

  @override
  String get settingsBuyMeCoffee => 'Buy me a coffee';

  @override
  String get settingsBuyMeCoffeeDesc => 'Support the developer';
}
