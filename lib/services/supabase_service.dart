import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();
  static const Set<String> allowedPaymentMethods = {'walk_in', 'paymongo'};

  static String parseFunctionError(Object? data, {required String fallback}) {
    if (data is! Map) {
      final text = data?.toString() ?? fallback;
      if (text.contains('The payment return URL is invalid')) {
        return 'PayMongo is not configured correctly in Supabase. Set a valid PAYMONGO_RETURN_URL secret for localhost or your production app URL.';
      }
      return fallback;
    }

    final map = Map<String, dynamic>.from(data);
    if (map['cancelled'] == true) {
      return '';
    }

    final error = map['error'];
    if (error is Map) {
      final nested = error['message'] ?? error['error'] ?? error['details'];
      if (nested is String && nested.trim().isNotEmpty) {
        final message = nested.trim();
        if (message.contains('The payment return URL is invalid')) {
          return 'PayMongo is not configured correctly in Supabase. Set a valid PAYMONGO_RETURN_URL secret for localhost or your production app URL.';
        }
        return message;
      }
    }

    if (error is String && error.trim().isNotEmpty) {
      final message = error.trim();
      if (message.contains('The payment return URL is invalid')) {
        return 'PayMongo is not configured correctly in Supabase. Set a valid PAYMONGO_RETURN_URL secret for localhost or your production app URL.';
      }
      return message;
    }

    return fallback;
  }

  SupabaseClient get client => Supabase.instance.client;
  User? get currentUser => client.auth.currentUser;
  Stream<AuthState> get authChanges => client.auth.onAuthStateChange;

  Future<void> signUp({required String name, required String email, required String password}) async {
    final result = await client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'full_name': name.trim()},
    );
    if (result.user == null) throw const AuthException('Account could not be created.');
  }

  Future<void> signIn({required String email, required String password}) async {
    await client.auth.signInWithPassword(email: email.trim(), password: password);
  }

  Future<void> signOut() => client.auth.signOut();

  Future<void> sendPasswordReset(String email, {required String redirectTo}) async {
    await client.auth.resetPasswordForEmail(email.trim(), redirectTo: redirectTo);
  }

  Future<Map<String, dynamic>> getSettings() async {
    return await client.from('court_settings').select().eq('id', true).single();
  }

  Future<List<Map<String, dynamic>>> getBookingsForDay(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day).toUtc().toIso8601String();
    final end = DateTime(day.year, day.month, day.day + 1).toUtc().toIso8601String();
    final rows = await client.rpc('get_court_bookings', params: {'p_from': start, 'p_to': end});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<Map<String, dynamic>> createBooking({required DateTime start, required int hours, required String paymentMethod}) async {
    if (!allowedPaymentMethods.contains(paymentMethod)) {
      throw ArgumentError.value(
        paymentMethod,
        'paymentMethod',
        'Unsupported payment method. Allowed values: walk_in, paymongo.',
      );
    }

    final result = await client.rpc('create_court_booking', params: {
      'p_start_at': start.toUtc().toIso8601String(),
      'p_duration_hours': hours,
      'p_payment_method': paymentMethod,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createPayMongoCheckout({
    required String bookingId,
  }) async {
    final response = await client.functions.invoke(
      'create-paymongo-checkout',
      body: {'booking_id': bookingId},
    );
    if (response.data is! Map) {
      throw StateError('PayMongo did not return a checkout session.');
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> cancelPayMongoCheckout(String bookingId) async {
    final response = await client.functions.invoke(
      'cancel-paymongo-checkout',
      body: {'booking_id': bookingId},
    );

    if (response.data is Map && response.data['cancelled'] == true) {
      return;
    }

    final message = parseFunctionError(
      response.data,
      fallback: 'PayMongo could not cancel this checkout. Refresh bookings and try again.',
    );
    if (message.isNotEmpty) {
      throw StateError(message);
    }

    throw StateError('PayMongo could not cancel this checkout. Refresh bookings and try again.');
  }

  Future<List<Map<String, dynamic>>> getMyBookings({bool past = false, bool all = false}) async {
    final user = currentUser;
    if (user == null) {
      throw StateError('Sign in to view your bookings.');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final query = client.from('court_bookings').select().eq('user_id', user.id);
    final rows = all
      ? await query.order('start_at', ascending: false)
      : past
        ? await query.lt('end_at', now).order('start_at', ascending: false)
        : await query
          .gte('end_at', now)
          .inFilter('status', ['pending', 'confirmed'])
          .order('start_at');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>?> getMyBookingPaymentStatus(String bookingId) async {
    final user = currentUser;
    if (user == null) {
      throw StateError('Sign in to refresh your payment status.');
    }

    final booking = await client
        .from('court_bookings')
        .select('id,status,payment_status')
        .eq('id', bookingId)
        .eq('user_id', user.id)
        .maybeSingle();
    return booking == null ? null : Map<String, dynamic>.from(booking);
  }

  Future<void> cancelBooking(String id) async {
    await client.rpc('cancel_court_booking', params: {'p_booking_id': id});
  }

  Future<Map<String, dynamic>> getMyProfile() async {
    return await client.from('profiles').select().eq('id', currentUser!.id).single();
  }

  Future<void> updateMyProfile({required String fullName}) async {
    await client.from('profiles').update({'full_name': fullName.trim()}).eq('id', currentUser!.id);
  }
}
