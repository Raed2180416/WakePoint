// lib/services/data_asset/mobility_consent_copy.dart
//
// GeoWake — standalone DPDP Rule-3 consent notice copy (DATA_SURFACE_SPEC §2.11).
// Const strings only. Every user-facing string says "GeoWake". The grievance/DPO
// contact and Data Protection Board link are PLACEHOLDERS the founder replaces
// before egress (DATA_SURFACE_SPEC §6).

class MobilityConsentCopy {
  const MobilityConsentCopy._();

  static const String title =
      'Help improve transit planning — share anonymous trip stats';

  static const String dataItemised =
      'Only counts of how many riders travelled between stations, by hour and '
      'weekday/weekend. Never your location trail, never your identity, never a '
      'single trip traceable to you.';

  static const String purpose =
      'To build anonymous, aggregated station-to-station travel-flow statistics '
      'for transit authorities and urban planners.';

  static const String guarantees =
      'Off by default. Your GeoWake wake-alarm works exactly the same whether '
      'this is on or off. Turn it off any time in one tap — we stop immediately '
      'and delete what is stored on this device.';

  static const String methodDisclosure =
      'We add statistical noise (differential privacy, epsilon per cell = 0.44) '
      'and never release any group smaller than 100 riders (k-anonymity).';

  static const String ageLine = 'You must be 18 or older to turn this on.';

  static const String withdrawLine =
      'You can withdraw consent at any time from this screen. Withdrawal is as '
      'easy as giving consent, and GeoWake deletes the on-device stats at once.';

  // ---- Founder placeholders (replaced before any egress; DATA_SURFACE_SPEC §6) ----

  static const String grievanceContactPlaceholder =
      'Grievance / Data Protection Officer: [add DPO name + email before egress]';

  static const String dataProtectionBoardPlaceholder =
      'You may complain to the Data Protection Board of India: [add Board '
      'complaint link before egress]';

  static const String toggleLabel = 'Share anonymous trip stats with GeoWake';

  static const String ageConfirmLabel = 'I confirm I am 18 or older';

  // Honest present-tense: while the pipeline is inert (kDataAssetEgressEnabled
  // == false) nothing leaves the device, so this must not promise future
  // contribution. It records the preference locally only.
  static const String enabledSnack =
      'Saved. Your preference to share anonymous, noise-added station counts '
      'is on. Nothing is shared unless and until GeoWake turns the pipeline on.';

  static const String withdrawnSnack =
      'Stopped. GeoWake deleted the anonymous stats stored on this device.';
}
