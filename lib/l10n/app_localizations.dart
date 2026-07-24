import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_bn.dart';
import 'app_localizations_en.dart';
import 'app_localizations_hi.dart';
import 'app_localizations_ta.dart';
import 'app_localizations_te.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('hi'),
    Locale('bn'),
    Locale('ta'),
    Locale('te'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'GeoWake'**
  String get appTitle;

  /// No description provided for @paywallTitle.
  ///
  /// In en, this message translates to:
  /// **'GeoWake Pro'**
  String get paywallTitle;

  /// No description provided for @paywallHeadline.
  ///
  /// In en, this message translates to:
  /// **'Your commute on autopilot.'**
  String get paywallHeadline;

  /// No description provided for @paywallSubtitle.
  ///
  /// In en, this message translates to:
  /// **'One-time purchase. Yours forever. No subscription.'**
  String get paywallSubtitle;

  /// No description provided for @paywallTrustStrip.
  ///
  /// In en, this message translates to:
  /// **'Your never-late alarm is free forever. Pro adds convenience, not safety.'**
  String get paywallTrustStrip;

  /// No description provided for @paywallCta.
  ///
  /// In en, this message translates to:
  /// **'Unlock forever — {price}'**
  String paywallCta(String price);

  /// No description provided for @paywallCtaBusy.
  ///
  /// In en, this message translates to:
  /// **'Please wait…'**
  String get paywallCtaBusy;

  /// No description provided for @paywallRewardedVideo.
  ///
  /// In en, this message translates to:
  /// **'Watch a short video for a free day of Pro'**
  String get paywallRewardedVideo;

  /// No description provided for @paywallRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore purchase'**
  String get paywallRestore;

  /// No description provided for @paywallTerms.
  ///
  /// In en, this message translates to:
  /// **'Terms'**
  String get paywallTerms;

  /// No description provided for @paywallPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get paywallPrivacy;

  /// No description provided for @paywallSuccess.
  ///
  /// In en, this message translates to:
  /// **'Welcome to GeoWake Pro 🎉'**
  String get paywallSuccess;

  /// No description provided for @paywallPending.
  ///
  /// In en, this message translates to:
  /// **'Payment processing — Pro will unlock automatically once it clears.'**
  String get paywallPending;

  /// No description provided for @paywallFailed.
  ///
  /// In en, this message translates to:
  /// **'Purchase didn\'t complete. You can try again anytime.'**
  String get paywallFailed;

  /// No description provided for @paywallRestored.
  ///
  /// In en, this message translates to:
  /// **'Pro restored ✓'**
  String get paywallRestored;

  /// No description provided for @paywallNoPurchase.
  ///
  /// In en, this message translates to:
  /// **'No previous purchase found.'**
  String get paywallNoPurchase;

  /// No description provided for @paywallAlreadyPro.
  ///
  /// In en, this message translates to:
  /// **'You\'re on GeoWake Pro'**
  String get paywallAlreadyPro;

  /// No description provided for @paywallThanks.
  ///
  /// In en, this message translates to:
  /// **'Thanks for supporting GeoWake.'**
  String get paywallThanks;

  /// No description provided for @paywallDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get paywallDone;

  /// No description provided for @paywallPendingBannerTitle.
  ///
  /// In en, this message translates to:
  /// **'Payment processing…'**
  String get paywallPendingBannerTitle;

  /// No description provided for @paywallPendingBannerBody.
  ///
  /// In en, this message translates to:
  /// **'Your UPI payment is being verified. Pro will unlock automatically once it clears — usually within a few minutes. You can close this screen.'**
  String get paywallPendingBannerBody;

  /// No description provided for @featureGuardianMode.
  ///
  /// In en, this message translates to:
  /// **'Guardian mode'**
  String get featureGuardianMode;

  /// No description provided for @featureGuardianModeDesc.
  ///
  /// In en, this message translates to:
  /// **'Auto-share your journey with family + an \"arrived safely\" alert.'**
  String get featureGuardianModeDesc;

  /// No description provided for @featureAntiTheftMode.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft mode'**
  String get featureAntiTheftMode;

  /// No description provided for @featureAntiTheftModeDesc.
  ///
  /// In en, this message translates to:
  /// **'Loud alarm if someone snatches your phone while you sleep on transit.'**
  String get featureAntiTheftModeDesc;

  /// No description provided for @featureCustomAlarm.
  ///
  /// In en, this message translates to:
  /// **'Custom & escalating alarm'**
  String get featureCustomAlarm;

  /// No description provided for @featureCustomAlarmDesc.
  ///
  /// In en, this message translates to:
  /// **'Your own sounds, ramping volume that won\'t let you sleep through it.'**
  String get featureCustomAlarmDesc;

  /// No description provided for @featureHomeWidget.
  ///
  /// In en, this message translates to:
  /// **'Home widget'**
  String get featureHomeWidget;

  /// No description provided for @featureHomeWidgetDesc.
  ///
  /// In en, this message translates to:
  /// **'One-tap arm from your home screen.'**
  String get featureHomeWidgetDesc;

  /// No description provided for @featureAdFree.
  ///
  /// In en, this message translates to:
  /// **'Ad-free'**
  String get featureAdFree;

  /// No description provided for @featureAdFreeDesc.
  ///
  /// In en, this message translates to:
  /// **'No ads, anywhere.'**
  String get featureAdFreeDesc;

  /// No description provided for @antiTheftTitle.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft mode'**
  String get antiTheftTitle;

  /// No description provided for @antiTheftEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable anti-theft protection'**
  String get antiTheftEnable;

  /// No description provided for @antiTheftEnableDesc.
  ///
  /// In en, this message translates to:
  /// **'Monitor for phone snatch detection while you sleep on transit.'**
  String get antiTheftEnableDesc;

  /// No description provided for @antiTheftSensitivity.
  ///
  /// In en, this message translates to:
  /// **'Sensitivity'**
  String get antiTheftSensitivity;

  /// No description provided for @antiTheftSensitivityLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get antiTheftSensitivityLow;

  /// No description provided for @antiTheftSensitivityMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get antiTheftSensitivityMedium;

  /// No description provided for @antiTheftSensitivityHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get antiTheftSensitivityHigh;

  /// No description provided for @antiTheftChargerAlert.
  ///
  /// In en, this message translates to:
  /// **'Alert on charger removal'**
  String get antiTheftChargerAlert;

  /// No description provided for @antiTheftChargerAlertDesc.
  ///
  /// In en, this message translates to:
  /// **'Sound alarm if someone disconnects your charger while sleeping.'**
  String get antiTheftChargerAlertDesc;

  /// No description provided for @antiTheftCalibrating.
  ///
  /// In en, this message translates to:
  /// **'Calibrating sensors…'**
  String get antiTheftCalibrating;

  /// No description provided for @antiTheftMonitoring.
  ///
  /// In en, this message translates to:
  /// **'Monitoring active'**
  String get antiTheftMonitoring;

  /// No description provided for @antiTheftMonitoringDesc.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft is running. Your phone is being protected.'**
  String get antiTheftMonitoringDesc;

  /// No description provided for @antiTheftHowItWorks.
  ///
  /// In en, this message translates to:
  /// **'How it works'**
  String get antiTheftHowItWorks;

  /// No description provided for @antiTheftHowItWorksBody.
  ///
  /// In en, this message translates to:
  /// **'Uses your phone\'s accelerometer and gyroscope to detect sudden movements like a phone snatch. If triggered, a loud alarm sounds immediately. Calibration runs for 3 seconds when monitoring starts to learn your phone\'s resting state.'**
  String get antiTheftHowItWorksBody;

  /// No description provided for @antiTheftProOnly.
  ///
  /// In en, this message translates to:
  /// **'Pro feature'**
  String get antiTheftProOnly;

  /// No description provided for @settingsGoPremium.
  ///
  /// In en, this message translates to:
  /// **'Go Premium'**
  String get settingsGoPremium;

  /// No description provided for @settingsAntiTheftMode.
  ///
  /// In en, this message translates to:
  /// **'Anti-theft mode'**
  String get settingsAntiTheftMode;

  /// No description provided for @settingsGuardianMode.
  ///
  /// In en, this message translates to:
  /// **'Guardian mode'**
  String get settingsGuardianMode;

  /// No description provided for @settingsBuyMeCoffee.
  ///
  /// In en, this message translates to:
  /// **'Buy me a coffee'**
  String get settingsBuyMeCoffee;

  /// No description provided for @settingsBuyMeCoffeeDesc.
  ///
  /// In en, this message translates to:
  /// **'Support the developer'**
  String get settingsBuyMeCoffeeDesc;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['bn', 'en', 'hi', 'ta', 'te'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'bn':
      return AppLocalizationsBn();
    case 'en':
      return AppLocalizationsEn();
    case 'hi':
      return AppLocalizationsHi();
    case 'ta':
      return AppLocalizationsTa();
    case 'te':
      return AppLocalizationsTe();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
