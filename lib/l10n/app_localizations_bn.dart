// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Bengali Bangla (`bn`).
class AppLocalizationsBn extends AppLocalizations {
  AppLocalizationsBn([String locale = 'bn']) : super(locale);

  @override
  String get appTitle => 'GeoWake';

  @override
  String get paywallTitle => 'GeoWake Pro';

  @override
  String get paywallHeadline => 'আপনার যাত্রা এখন স্বয়ংক্রিয়।';

  @override
  String get paywallSubtitle =>
      'এককালীন ক্রয়। চিরকালের জন্য আপনার। কোনো সাবস্ক্রিপশন নেই।';

  @override
  String get paywallTrustStrip =>
      'আপনার অ্যালার্ম চিরকাল বিনামূল্যে। Pro সুবিধা যোগ করে, নিরাপত্তা নয়।';

  @override
  String paywallCta(String price) {
    return 'চিরকালের জন্য আনলক করুন — $price';
  }

  @override
  String get paywallCtaBusy => 'অনুগ্রহ করে অপেক্ষা করুন…';

  @override
  String get paywallRewardedVideo =>
      'Pro-এর এক দিনের জন্য একটি ছোট ভিডিও দেখুন';

  @override
  String get paywallRestore => 'ক্রয় পুনরুদ্ধার করুন';

  @override
  String get paywallTerms => 'শর্তাবলী';

  @override
  String get paywallPrivacy => 'গোপনীয়তা';

  @override
  String get paywallSuccess => 'GeoWake Pro-এ স্বাগতম 🎉';

  @override
  String get paywallPending =>
      'পেমেন্ট প্রক্রিয়াধান — Pro স্বয়ংক্রিয়ভাবে আনলক হবে।';

  @override
  String get paywallFailed =>
      'ক্রয় সম্পূর্ণ হয়নি। আপনি যেকোনো সময় আবার চেষ্টা করতে পারেন।';

  @override
  String get paywallRestored => 'Pro পুনরুদ্ধার হয়েছে ✓';

  @override
  String get paywallNoPurchase => 'কোনো পূর্ববর্তী ক্রয় পাওয়া যায়নি।';

  @override
  String get paywallAlreadyPro => 'আপনি GeoWake Pro-এ আছেন';

  @override
  String get paywallThanks => 'GeoWake সমর্থন করার জন্য ধন্যবাদ।';

  @override
  String get paywallDone => 'সম্পন্ন';

  @override
  String get paywallPendingBannerTitle => 'পেমেন্ট প্রক্রিয়াধান…';

  @override
  String get paywallPendingBannerBody =>
      'আপনার UPI পেমেন্ট যাচাই হচ্ছে। Pro স্বয়ংক্রিয়ভাবে আনলক হবে — সাধারণত কয়েক মিনিটে। আপনি এই স্ক্রিন বন্ধ করতে পারেন।';

  @override
  String get featureGuardianMode => 'গার্ডিয়ান মোড';

  @override
  String get featureGuardianModeDesc =>
      'পরিবারের সাথে যাত্রা শেয়ার করুন + \"নিরাপদে পৌঁছেছি\" অ্যালার্ট।';

  @override
  String get featureAntiTheftMode => 'অ্যান্টি-থেফট মোড';

  @override
  String get featureAntiTheftModeDesc =>
      'যাত্রায় ঘুমানোর সময় ফোন ছিনতাই হলে জোর অ্যালার্ম।';

  @override
  String get featureCustomAlarm => 'কাস্টম এবং ক্রমবর্ধমান অ্যালার্ম';

  @override
  String get featureCustomAlarmDesc => 'আপনার নিজের শব্দ, ক্রমবর্ধমান ভলিউম।';

  @override
  String get featureHomeWidget => 'হোম উইজেট';

  @override
  String get featureHomeWidgetDesc => 'হোম স্ক্রিন থেকে এক ট্যাপে চালু করুন।';

  @override
  String get featureAdFree => 'বিজ্ঞাপন-মুক্ত';

  @override
  String get featureAdFreeDesc => 'কোথাও কোনো বিজ্ঞাপন নেই।';

  @override
  String get antiTheftTitle => 'অ্যান্টি-থেফট মোড';

  @override
  String get antiTheftEnable => 'অ্যান্টি-থেফট সুরক্ষা সক্ষম করুন';

  @override
  String get antiTheftEnableDesc =>
      'যাত্রায় ঘুমানোর সময় ফোন ছিনতাই শনাক্ত করুন।';

  @override
  String get antiTheftSensitivity => 'সংবেদনশীলতা';

  @override
  String get antiTheftSensitivityLow => 'কম';

  @override
  String get antiTheftSensitivityMedium => 'মাঝারি';

  @override
  String get antiTheftSensitivityHigh => 'উচ্চ';

  @override
  String get antiTheftChargerAlert => 'চার্জার সরানোর অ্যালার্ট';

  @override
  String get antiTheftChargerAlertDesc =>
      'ঘুমানোর সময় চার্জার ডিস্কানেক্ট হলে অ্যালার্ম।';

  @override
  String get antiTheftCalibrating => 'সেন্সর ক্যালিব্রেট হচ্ছে…';

  @override
  String get antiTheftMonitoring => 'নজরদারি সক্রিয়';

  @override
  String get antiTheftMonitoringDesc =>
      'অ্যান্টি-থেফট চলছে। আপনার ফোন সুরক্ষিত।';

  @override
  String get antiTheftHowItWorks => 'এটি কীভাবে কাজ করে';

  @override
  String get antiTheftHowItWorksBody =>
      'ফোনের অ্যাক্সেলেরোমিটার এবং জাইরোস্কোপ ব্যবহার করে হঠাৎ নড়াচড়া শনাক্ত করে। ট্রিগার হলে জোর অ্যালার্ম বাজে।';

  @override
  String get antiTheftProOnly => 'Pro ফিচার';

  @override
  String get settingsGoPremium => 'প্রিমিয়াম হন';

  @override
  String get settingsAntiTheftMode => 'অ্যান্টি-থেফট মোড';

  @override
  String get settingsGuardianMode => 'গার্ডিয়ান মোড';

  @override
  String get settingsBuyMeCoffee => 'আমাকে কফি কিনুন';

  @override
  String get settingsBuyMeCoffeeDesc => 'ডেভেলপারকে সমর্থন করুন';
}
