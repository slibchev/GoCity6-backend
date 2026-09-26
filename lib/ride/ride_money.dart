class RideMoney {
  static const String currency = 'EUR';

  static const int basisPointsPerHundredPercent = 10000;

  const RideMoney._();

  static int calculateCommissionMinor({
    required int meterFareMinor,
    required int commissionRateBps,
  }) {
    if (meterFareMinor < 0) {
      throw ArgumentError.value(
        meterFareMinor,
        'meterFareMinor',
        'Meter fare cannot be negative.',
      );
    }

    if (commissionRateBps < 0 ||
        commissionRateBps > basisPointsPerHundredPercent) {
      throw ArgumentError.value(
        commissionRateBps,
        'commissionRateBps',
        'Commission rate must be between 0 and 10000 basis points.',
      );
    }

    final numerator = meterFareMinor * commissionRateBps;

    return (numerator + 5000) ~/ basisPointsPerHundredPercent;
  }
}
