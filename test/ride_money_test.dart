import 'package:gocity6_backend/ride/ride_money.dart';
import 'package:test/test.dart';

void main() {
  group('RideMoney', () {
    test('uses EUR currency', () {
      expect(RideMoney.currency, 'EUR');
    });

    test('calculates 10 percent commission exactly in minor units', () {
      final commission = RideMoney.calculateCommissionMinor(
        meterFareMinor: 1234,
        commissionRateBps: 1000,
      );

      expect(commission, 123);
    });

    test('rounds half cent upward', () {
      final commission = RideMoney.calculateCommissionMinor(
        meterFareMinor: 1235,
        commissionRateBps: 1000,
      );

      expect(commission, 124);
    });

    test('supports fractional percentage using basis points', () {
      final commission = RideMoney.calculateCommissionMinor(
        meterFareMinor: 2000,
        commissionRateBps: 750,
      );

      expect(commission, 150);
    });

    test('rejects negative fare', () {
      expect(
        () => RideMoney.calculateCommissionMinor(
          meterFareMinor: -1,
          commissionRateBps: 1000,
        ),
        throwsArgumentError,
      );
    });

    test('rejects commission above 100 percent', () {
      expect(
        () => RideMoney.calculateCommissionMinor(
          meterFareMinor: 1000,
          commissionRateBps: 10001,
        ),
        throwsArgumentError,
      );
    });
  });
}
