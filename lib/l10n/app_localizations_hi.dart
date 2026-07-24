// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Hindi (`hi`).
class AppLocalizationsHi extends AppLocalizations {
  AppLocalizationsHi([String locale = 'hi']) : super(locale);

  @override
  String get appTitle => 'GeoWake';

  @override
  String get paywallTitle => 'GeoWake Pro';

  @override
  String get paywallHeadline => 'आपकी यात्रा अब स्वचालित।';

  @override
  String get paywallSubtitle =>
      'एकमुश्त खरीदारी। हमेशा के लिए आपका। कोई सदस्यता नहीं।';

  @override
  String get paywallTrustStrip =>
      'आपका अलार्म हमेशा मुफ्त रहेगा। Pro सुविधा जोड़ता है, सुरक्षा नहीं।';

  @override
  String paywallCta(String price) {
    return 'हमेशा के लिए अनलॉक करें — $price';
  }

  @override
  String get paywallCtaBusy => 'कृपया प्रतीक्षा करें…';

  @override
  String get paywallRewardedVideo =>
      'Pro के एक दिन के लिए एक छोटा वीडियो देखें';

  @override
  String get paywallRestore => 'खरीदारी पुनर्स्थापित करें';

  @override
  String get paywallTerms => 'शर्तें';

  @override
  String get paywallPrivacy => 'गोपनीयता';

  @override
  String get paywallSuccess => 'GeoWake Pro में आपका स्वागत है 🎉';

  @override
  String get paywallPending =>
      'भुगतान प्रसंस्करण — Pro स्वचालित रूप से अनलॉक होगा।';

  @override
  String get paywallFailed =>
      'खरीदारी पूरी नहीं हुई। आप कभी भी पुनः प्रयास कर सकते हैं।';

  @override
  String get paywallRestored => 'Pro पुनर्स्थापित ✓';

  @override
  String get paywallNoPurchase => 'कोई पूर्व खरीदारी नहीं मिली।';

  @override
  String get paywallAlreadyPro => 'आप GeoWake Pro पर हैं';

  @override
  String get paywallThanks => 'GeoWake का समर्थन करने के लिए धन्यवाद।';

  @override
  String get paywallDone => 'पूर्ण';

  @override
  String get paywallPendingBannerTitle => 'भुगतान प्रसंस्करण…';

  @override
  String get paywallPendingBannerBody =>
      'आपका UPI भुगतान सत्यापित हो रहा है। Pro स्वचालित रूप से अनलॉक होगा — आमतौर पर कुछ मिनटों में। आप इस स्क्रीन को बंद कर सकते हैं।';

  @override
  String get featureGuardianMode => 'गार्जियन मोड';

  @override
  String get featureGuardianModeDesc =>
      'अपनी यात्रा परिवार के साथ साझा करें + \"सुरक्षित पहुंचे\" अलर्ट।';

  @override
  String get featureAntiTheftMode => 'एंटी-थेफ्ट मोड';

  @override
  String get featureAntiTheftModeDesc =>
      'यात्रा में सोते समय फोन छीनने पर तेज अलार्म।';

  @override
  String get featureCustomAlarm => 'कस्टम और बढ़ता अलार्म';

  @override
  String get featureCustomAlarmDesc =>
      'अपनी ध्वनियाँ, बढ़ती आवाज़ जो आपको नींद से नहीं जगने देगी।';

  @override
  String get featureHomeWidget => 'होम विजेट';

  @override
  String get featureHomeWidgetDesc => 'होम स्क्रीन से एक टैप पर चालू करें।';

  @override
  String get featureAdFree => 'विज्ञान-मुक्त';

  @override
  String get featureAdFreeDesc => 'कहीं भी कोई विज्ञान नहीं।';

  @override
  String get antiTheftTitle => 'एंटी-थेफ्ट मोड';

  @override
  String get antiTheftEnable => 'एंटी-थेफ्ट सुरक्षा सक्षम करें';

  @override
  String get antiTheftEnableDesc =>
      'यात्रा में सोते समय फोन छीनने की पहचान करें।';

  @override
  String get antiTheftSensitivity => 'संवेदनशीलता';

  @override
  String get antiTheftSensitivityLow => 'कम';

  @override
  String get antiTheftSensitivityMedium => 'मध्यम';

  @override
  String get antiTheftSensitivityHigh => 'उच्च';

  @override
  String get antiTheftChargerAlert => 'चार्जर हटने पर अलर्ट';

  @override
  String get antiTheftChargerAlertDesc =>
      'सोते समय कोई चार्जर डिस्कनेक्ट करे तो अलार्म बजे।';

  @override
  String get antiTheftCalibrating => 'सेंसर कैलिब्रेट हो रहे हैं…';

  @override
  String get antiTheftMonitoring => 'निगरानी सक्रिय';

  @override
  String get antiTheftMonitoringDesc =>
      'एंटी-थेफ्ट चल रहा है। आपका फोन सुरक्षित है।';

  @override
  String get antiTheftHowItWorks => 'यह कैसे काम करता है';

  @override
  String get antiTheftHowItWorksBody =>
      'फोन के एक्सेलेरोमीटर और जायरोस्कोप का उपयोग करके अचानक गति का पता लगाता है। ट्रिगर होने पर तेज अलार्म बजता है। निगरानी शुरू होने पर 3 सेकंड कैलिब्रेशन होता है।';

  @override
  String get antiTheftProOnly => 'Pro सुविधा';

  @override
  String get settingsGoPremium => 'प्रीमियम बनें';

  @override
  String get settingsAntiTheftMode => 'एंटी-थेफ्ट मोड';

  @override
  String get settingsGuardianMode => 'गार्जियन मोड';

  @override
  String get settingsBuyMeCoffee => 'मुझे कॉफी खरीदें';

  @override
  String get settingsBuyMeCoffeeDesc => 'डेवलपर का समर्थन करें';
}
