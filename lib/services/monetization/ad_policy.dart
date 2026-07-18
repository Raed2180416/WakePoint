// lib/services/monetization/ad_policy.dart
//
// Pure, stateless rules for WHERE and WHEN an ad may appear. This file has no
// dependencies and no I/O — it is a decision function so the "never show an ad
// that could compromise the alarm" property is exhaustively unit-testable.
//
// The constraints come straight from HANDOFF §2 and MONETIZATION §1:
//   * A wake-alarm is used eyes-closed; there is almost no in-app attention to
//     sell during the core flow, and the two moments that DO have attention
//     (arm, arrive) are time-pressured. So ads live only on non-critical
//     surfaces, and interstitial-style ads are frequency-capped.
//   * NEVER an ad during the alarm, the wake, or the lock-screen — anything
//     that could delay or obscure the alarm. Reliability is the product; it is
//     a hard denylist here, enforced by construction (see [_alwaysForbidden]).
//   * Prefer OPT-IN rewarded video ("premium for a day") over forced pre-roll:
//     higher eCPM, zero forced friction, self-selects the ad-tolerant.
//   * If isPro (paid unlock or an active rewarded day-pass) ⇒ no ads anywhere.

/// Surfaces the app can request an ad for. The three ad-eligible surfaces are
/// the only low-intrusion moments; the rest are listed so the policy can HARD
/// DENY them — an ad there could compete with the alarm and is never allowed.
enum AdPlacement {
  /// Route-arming screen, before the trip. Banner/native, low intrusion.
  routeArming,

  /// Above-ground map/tracking screen. Small banner.
  mapTracking,

  /// Post-arrival summary the user opens AFTER they're off the train. The best
  /// intent moment ("you've arrived at X"); interstitial/native, frequency-capped.
  postArrival,

  /// The alarm is ringing. NEVER an ad.
  alarm,

  /// The wake / lock-screen wake surface. NEVER an ad.
  wake,

  /// Any lock-screen context. NEVER an ad.
  lockScreen,
}

/// Pure ad-gating rules. Immutable and const-constructible; hold no runtime
/// state — the ride counter is passed in so the caller owns persistence.
class AdPolicy {
  /// Show a frequency-capped (interstitial/rewarded) ad at most once per this
  /// many rides. MONETIZATION §1's "every 3 rides" floor.
  final int frequencyCapRides;

  const AdPolicy({this.frequencyCapRides = 3});

  /// The only surfaces an ad may EVER appear on.
  static const Set<AdPlacement> adEligiblePlacements = <AdPlacement>{
    AdPlacement.routeArming,
    AdPlacement.mapTracking,
    AdPlacement.postArrival,
  };

  /// Interstitial/native surfaces subject to the every-N-rides frequency cap.
  /// Banner surfaces (arming, map) are low-intrusion and NOT capped.
  static const Set<AdPlacement> frequencyCappedPlacements = <AdPlacement>{
    AdPlacement.postArrival,
  };

  /// Surfaces where an ad is NEVER permitted — the alarm and its wake path.
  /// Denied for everyone, Pro or free, regardless of any counter. This is the
  /// reliability/safety guardrail expressed as data.
  static const Set<AdPlacement> alwaysForbiddenPlacements = <AdPlacement>{
    AdPlacement.alarm,
    AdPlacement.wake,
    AdPlacement.lockScreen,
  };

  /// Whether an ad may be shown at [placement] right now.
  ///
  /// [isPro] — paid Pro unlock OR an active rewarded day-pass. Pro ⇒ no ads.
  /// [ridesSinceLastAd] — rides completed since the last frequency-capped ad
  /// was shown (caller-owned counter). Only consulted for capped placements.
  bool canShow(
    AdPlacement placement, {
    required bool isPro,
    required int ridesSinceLastAd,
  }) {
    // Pro removes every ad, everywhere.
    if (isPro) return false;
    // The alarm/wake/lock-screen are never monetized — reliability first.
    if (alwaysForbiddenPlacements.contains(placement)) return false;
    // Anything not explicitly ad-eligible is denied by default (fail-closed).
    if (!adEligiblePlacements.contains(placement)) return false;
    // Interstitial-style surfaces respect the every-N-rides cap.
    if (frequencyCappedPlacements.contains(placement)) {
      return ridesSinceLastAd >= frequencyCapRides;
    }
    // Low-intrusion banners (arming, map) are always allowed for free users.
    return true;
  }

  /// Whether to OFFER the opt-in rewarded-video "premium for a day" unlock.
  ///
  /// Offered only to free users who don't already hold an active day-pass — no
  /// point nagging a Pro user or someone who already unlocked today. The grant
  /// itself is applied by PremiumService.grantRewardedDayPass on completion.
  bool shouldOfferRewardedUnlock({
    required bool isPro,
    required bool dayPassActive,
  }) {
    if (isPro) return false;
    if (dayPassActive) return false;
    return true;
  }
}
