// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Tamil (`ta`).
class AppLocalizationsTa extends AppLocalizations {
  AppLocalizationsTa([String locale = 'ta']) : super(locale);

  @override
  String get appTitle => 'GeoWake';

  @override
  String get paywallTitle => 'GeoWake Pro';

  @override
  String get paywallHeadline => 'உங்கள் பயணம் இப்போது தானியங்கி.';

  @override
  String get paywallSubtitle =>
      'ஒரு முறை பணம் செலுத்துதல். என்றென்றைக்கும் உங்களது. சந்தா இல்லை.';

  @override
  String get paywallTrustStrip =>
      'உங்கள் அலாரம் என்றென்றைக்கும் இலவசம். Pro வசதியைச் சேர்க்கிறது, பாதுகாப்பை அல்ல.';

  @override
  String paywallCta(String price) {
    return 'என்றென்றைக்கும் திறக்க — $price';
  }

  @override
  String get paywallCtaBusy => 'தயவுசெய்து காத்திருக்கவும்…';

  @override
  String get paywallRewardedVideo =>
      'Pro-ன் ஒரு நாளுக்கு ஒரு சிறிய வீடியோ பார்க்கவும்';

  @override
  String get paywallRestore => 'கொள்முதலை மீட்டமைக்கவும்';

  @override
  String get paywallTerms => 'விதிமுறைகள்';

  @override
  String get paywallPrivacy => 'தனியுரிமை';

  @override
  String get paywallSuccess => 'GeoWake Pro-க்கு வரவேற்கிறோம் 🎉';

  @override
  String get paywallPending => 'கட்டணம் செயல்படுகிறது — Pro தானாகத் திறக்கும்.';

  @override
  String get paywallFailed => 'கொள்முதல் முடியவில்லை. மீண்டும் முயற்சிக்கலாம்.';

  @override
  String get paywallRestored => 'Pro மீட்டமைக்கப்பட்டது ✓';

  @override
  String get paywallNoPurchase => 'முந்தைய கொள்முதல் இல்லை.';

  @override
  String get paywallAlreadyPro => 'நீங்கள் GeoWake Pro-ல் உள்ளீர்கள்';

  @override
  String get paywallThanks => 'GeoWake-ஐ ஆதரிப்பதற்கு நன்றி.';

  @override
  String get paywallDone => 'முடிந்தது';

  @override
  String get paywallPendingBannerTitle => 'கட்டணம் செயல்படுகிறது…';

  @override
  String get paywallPendingBannerBody =>
      'உங்கள் UPI கட்டணம் சரிபார்க்கப்படுகிறது. Pro தானாகத் திறக்கும் — பொதுவாக சில நிமிடங்களில். இந்தத் திரையை மூடலாம்.';

  @override
  String get featureGuardianMode => 'கார்டியன் முறை';

  @override
  String get featureGuardianModeDesc =>
      'குடும்பத்துடன் பயணம் பகிர் + \"பாதுகாப்பாக வந்தேன்\" எச்சரிக்கை.';

  @override
  String get featureAntiTheftMode => 'திருட்டு எதிர்ப்பு முறை';

  @override
  String get featureAntiTheftModeDesc =>
      'பயணத்தில் தூங்கும்போது போன் பறிக்கப்பட்டால் சத்தமான அலாரம்.';

  @override
  String get featureCustomAlarm => 'தனிப்பயன் மற்றும் ஏறும் அலாரம்';

  @override
  String get featureCustomAlarmDesc => 'உங்கள் சொந்த ஒலிகள், ஏறும் ஒலியளவு.';

  @override
  String get featureHomeWidget => 'ஹோம் விட்ஜெட்';

  @override
  String get featureHomeWidgetDesc => 'ஹோம் ஸ்கிரீனிலிருந்து ஒரு தட்டு.';

  @override
  String get featureAdFree => 'விளம்பரம் இல்லை';

  @override
  String get featureAdFreeDesc => 'எங்கும் விளம்பரம் இல்லை.';

  @override
  String get antiTheftTitle => 'திருட்டு எதிர்ப்பு முறை';

  @override
  String get antiTheftEnable => 'திருட்டு எதிர்ப்பு பாதுகாப்பை இயக்கு';

  @override
  String get antiTheftEnableDesc =>
      'பயணத்தில் தூங்கும்போது போன் பறிப்பைக் கண்டறி.';

  @override
  String get antiTheftSensitivity => 'உணர்திறன்';

  @override
  String get antiTheftSensitivityLow => 'குறைந்த';

  @override
  String get antiTheftSensitivityMedium => 'நடுத்தரம்';

  @override
  String get antiTheftSensitivityHigh => 'அதிக';

  @override
  String get antiTheftChargerAlert => 'சார்ஜர் நீக்க எச்சரிக்கை';

  @override
  String get antiTheftChargerAlertDesc =>
      'தூங்கும்போது சார்ஜர் துண்டிக்கப்பட்டால் அலாரம்.';

  @override
  String get antiTheftCalibrating => 'சென்சார் கேலிப்ரேட் செய்யப்படுகிறது…';

  @override
  String get antiTheftMonitoring => 'கண்காணிப்பு செயலில்';

  @override
  String get antiTheftMonitoringDesc =>
      'திருட்டு எதிர்ப்பு இயங்குகிறது. உங்கள் போன் பாதுகாக்கப்பட்டது.';

  @override
  String get antiTheftHowItWorks => 'இது எப்படி வேலை செய்கிறது';

  @override
  String get antiTheftHowItWorksBody =>
      'போனின் ஆக்சலரோமீட்டர் மற்றும் ஜைரோஸ்கோப் திடீர் அசைவுகளைக் கண்டறிய பயன்படுகிறது. தூண்டப்பட்டால் சத்தமான அலாரம் ஒலிக்கும்.';

  @override
  String get antiTheftProOnly => 'Pro அம்சம்';

  @override
  String get settingsGoPremium => 'பிரீமியம் பெறு';

  @override
  String get settingsAntiTheftMode => 'திருட்டு எதிர்ப்பு முறை';

  @override
  String get settingsGuardianMode => 'கார்டியன் முறை';

  @override
  String get settingsBuyMeCoffee => 'எனக்கு காபி வாங்கு';

  @override
  String get settingsBuyMeCoffeeDesc => 'டெவலப்பரை ஆதரி';
}
