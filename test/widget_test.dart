import 'package:flutter_test/flutter_test.dart';

import 'package:threekings_booking/main.dart';
import 'package:threekings_booking/services/supabase_service.dart';

void main() {
  testWidgets('app loads the auth UI even when Supabase is not configured yet', (WidgetTester tester) async {
    await tester.pumpWidget(const ThreeKingsApp());

    expect(find.text('Welcome Back!'), findsOneWidget);
    expect(find.textContaining('Connect Supabase'), findsNothing);
  });

  test('booking payment options are limited to walk-in and paymongo', () {
    final values = bookingPaymentOptions.map((option) => option['value']).toList();

    expect(values, ['walk_in', 'paymongo']);
    expect(values, isNot(contains('gcash')));
    expect(values, isNot(contains('maya')));
    expect(values, isNot(contains('card')));
    expect(values, isNot(contains('cash_on_site')));
  });

  test('payment callback deep link is recognized and parsed', () {
    final callbackUri = Uri.parse('com.example.threekings://payment/callback?status=success&booking_id=abc-123&session_id=cs_test_123');

    expect(isAppPaymentCallbackUri(callbackUri), isTrue);
    expect(parsePaymentCallbackUri(callbackUri), {
      'status': 'success',
      'booking_id': 'abc-123',
      'session_id': 'cs_test_123',
    });
  });

  test('PayMongo cancellation errors keep the backend message instead of a generic fallback', () {
    expect(
      SupabaseService.parseFunctionError(
        {'error': 'This booking has no active PayMongo checkout.'},
        fallback: 'We could not cancel this booking. Your bookings have been refreshed; please try again.',
      ),
      'This booking has no active PayMongo checkout.',
    );

    expect(
      SupabaseService.parseFunctionError(
        {'cancelled': true},
        fallback: 'We could not cancel this booking. Your bookings have been refreshed; please try again.',
      ),
      isEmpty,
    );
  });
}
