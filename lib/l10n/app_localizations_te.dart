// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Telugu (`te`).
class AppLocalizationsTe extends AppLocalizations {
  AppLocalizationsTe([String locale = 'te']) : super(locale);

  @override
  String get appTitle => 'GeoWake';

  @override
  String get paywallTitle => 'GeoWake Pro';

  @override
  String get paywallHeadline => 'మీ ప్రయాణం ఇప్పుడు స్వయంచాలక.';

  @override
  String get paywallSubtitle =>
      'ఒకేసారి కొనుగోలు. శాశ్వతంగా మీదే. సబ్‌స్క్రిప్షన్ లేదు.';

  @override
  String get paywallTrustStrip =>
      'మీ అలారం ఎల్లప్పుడూ ఉచితం. Pro సౌలభ్యాన్ని జోడిస్తుంది, భద్రతను కాదు.';

  @override
  String paywallCta(String price) {
    return 'శాశ్వతంగా అన్‌లాక్ — $price';
  }

  @override
  String get paywallCtaBusy => 'దయచేసి వేచి ఉండండి…';

  @override
  String get paywallRewardedVideo => 'Pro యొక్క ఒక రోజుకు చిన్న వీడియో చూడండి';

  @override
  String get paywallRestore => 'కొనుగోలు పునరుద్ధరించు';

  @override
  String get paywallTerms => 'నిబంధనలు';

  @override
  String get paywallPrivacy => 'గోప్యత';

  @override
  String get paywallSuccess => 'GeoWake Proకి స్వాగతం 🎉';

  @override
  String get paywallPending =>
      'చెల్లింపు ప్రాసెసింగ్ — Pro స్వయంచాలకంగా అన్‌లాక్ అవుతుంది.';

  @override
  String get paywallFailed => 'కొనుగోలు పూర్తి కాలేదు. మళ్లీ ప్రయత్నించవచ్చు.';

  @override
  String get paywallRestored => 'Pro పునరుద్ధరించబడింది ✓';

  @override
  String get paywallNoPurchase => 'మునుపటి కొనుగోలు లేదు.';

  @override
  String get paywallAlreadyPro => 'మీరు GeoWake Proలో ఉన్నారు';

  @override
  String get paywallThanks => 'GeoWakeను సపర్ట్ చేసినందుకు ధన్యవాదాలు.';

  @override
  String get paywallDone => 'పూర్తయింది';

  @override
  String get paywallPendingBannerTitle => 'చెల్లింపు ప్రాసెసింగ్…';

  @override
  String get paywallPendingBannerBody =>
      'మీ UPI చెల్లింపు ధృవీకరించబడుతోంది. Pro స్వయంచాలకంగా అన్‌లాక్ అవుతుంది — సాధారణంగా కొన్ని నిమిషాల్లో. మీరు ఈ స్క్రీన్ మూసివేయవచ్చు.';

  @override
  String get featureGuardianMode => 'గార్డియన్ మోడ్';

  @override
  String get featureGuardianModeDesc =>
      'కుటుంబంతో ప్రయాణం షేర్ + \"సురక్షితంగా చేరుకున్నాను\" అలర్ట్.';

  @override
  String get featureAntiTheftMode => 'యాంటీ-థెఫ్ట్ మోడ్';

  @override
  String get featureAntiTheftModeDesc =>
      'ప్రయాణంలో నిద్రపోయేటప్పుడు ఫోన్ దొంగిలిస్తే బిగ్గర అలారం.';

  @override
  String get featureCustomAlarm => 'కస్టమ్ & పెరుగుతున్న అలారం';

  @override
  String get featureCustomAlarmDesc =>
      'మీ స్వంత శబ్దాలు, పెరుగుతున్న వాల్యూమ్.';

  @override
  String get featureHomeWidget => 'హోమ్ విడ్జెట్';

  @override
  String get featureHomeWidgetDesc => 'హోమ్ స్క్రీన్ నుండి ఒక ట్యాప్.';

  @override
  String get featureAdFree => 'ప్రకటన-రహిత';

  @override
  String get featureAdFreeDesc => 'ఎక్కడా ప్రకటనలు లేవు.';

  @override
  String get antiTheftTitle => 'యాంటీ-థెఫ్ట్ మోడ్';

  @override
  String get antiTheftEnable => 'యాంటీ-థెఫ్ట్ రక్షణ ప్రారంభించు';

  @override
  String get antiTheftEnableDesc =>
      'ప్రయాణంలో నిద్రపోయేటప్పుడు ఫోన్ దొంగిలింపు గుర్తించు.';

  @override
  String get antiTheftSensitivity => 'సున్నితత్వం';

  @override
  String get antiTheftSensitivityLow => 'తక్కువ';

  @override
  String get antiTheftSensitivityMedium => 'మధ్యమ';

  @override
  String get antiTheftSensitivityHigh => 'అధిక';

  @override
  String get antiTheftChargerAlert => 'ఛార్జర్ తీసివేత అలర్ట్';

  @override
  String get antiTheftChargerAlertDesc =>
      'నిద్రలో ఛార్జర్ డిస్కనెక్ట్ అయితే అలారం.';

  @override
  String get antiTheftCalibrating => 'సెన్సర్ కేలిబ్రేట్ అవుతోంది…';

  @override
  String get antiTheftMonitoring => 'పర్యవేక్షణ క్రియాశీల';

  @override
  String get antiTheftMonitoringDesc =>
      'యాంటీ-థెఫ్ట్ నడుస్తోంది. మీ ఫోన్ రక్షించబడింది.';

  @override
  String get antiTheftHowItWorks => 'ఇది ఎలా పనిచేస్తుంది';

  @override
  String get antiTheftHowItWorksBody =>
      'ఫోన్ యాక్సలెరోమీటర్ మరియు గైరోస్కోప్ ఉపయోగించి ఆకస్మిక కదలికలను గుర్తిస్తుంది. ట్రిగ్గర్ అయితే బిగ్గర అలారం వస్తుంది.';

  @override
  String get antiTheftProOnly => 'Pro ఫీచర్';

  @override
  String get settingsGoPremium => 'ప్రీమియం పొందండి';

  @override
  String get settingsAntiTheftMode => 'యాంటీ-థెఫ్ట్ మోడ్';

  @override
  String get settingsGuardianMode => 'గార్డియన్ మోడ్';

  @override
  String get settingsBuyMeCoffee => 'నాకు కాఫీ కొనండి';

  @override
  String get settingsBuyMeCoffeeDesc => 'డెవలపర్‌ను సపర్ట్ చేయండి';
}
