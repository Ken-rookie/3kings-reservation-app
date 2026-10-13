import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config/supabase/supabase_config.dart';
import 'services/supabase_service.dart';

const lime = Color(0xFFD4FF35);
const lime2 = Color(0xFFB7F432);
const bg = Color(0xFF031311);
const panel = Color(0xFF0A1C20);
const panel2 = Color(0xFF10262A);
const line = Color(0xFF245057);
const muted = Color(0xFFA8B9BB);

const List<Map<String, String>> bookingPaymentOptions = [
  {'value': 'walk_in', 'label': 'Walk-in'},
  {'value': 'paymongo', 'label': 'Via PayMongo'},
];

const paymentCallbackScheme = 'com.example.threekings';
const paymentCallbackHost = 'payment';
const paymentCallbackPath = '/callback';

bool isPayMongoCheckoutUri(Uri? uri) {
  return uri != null &&
      uri.scheme == 'https' &&
      (uri.host == 'paymongo.com' || uri.host.endsWith('.paymongo.com'));
}

bool isAppPaymentCallbackUri(Uri? uri) {
  return uri != null &&
      uri.scheme == paymentCallbackScheme &&
      uri.host == paymentCallbackHost &&
      uri.path == paymentCallbackPath;
}

Map<String, String> parsePaymentCallbackUri(Uri uri) {
  final data = <String, String>{};
  for (final entry in uri.queryParameters.entries) {
    data[entry.key] = entry.value;
  }
  return data;
}

String paymentCallbackStatus(Uri uri) {
  final params = parsePaymentCallbackUri(uri);
  return (params['payment'] ?? params['status'] ?? '').toLowerCase();
}

bool isBookingPaymentConfirmed(Map<String, dynamic>? booking) {
  return booking?['payment_status']?.toString().toLowerCase() == 'paid';
}

bool supabaseReady = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  supabaseReady = SupabaseConfig.isConfigured;
  if (supabaseReady) {
    await SupabaseConfig.initializeIfConfigured();
  }

  runApp(const ThreeKingsApp());
}

class ThreeKingsApp extends StatelessWidget {
  const ThreeKingsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '3Kings Pickleball',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: lime,
          secondary: lime2,
          surface: panel,
        ),
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: panel,
          hintStyle: const TextStyle(color: muted),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: lime, width: 1.4),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    if (!supabaseReady) {
      return const AuthScreen();
    }

    return StreamBuilder<AuthState>(
      stream: SupabaseService.instance.authChanges,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        return session == null ? const AuthScreen() : const MainShell();
      },
    );
  }
}

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Connect Supabase to run 3Kings.\n\nSee README.md and run with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.6),
          ),
        ),
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool signup = false;
  bool busy = false;
  bool obscure = true;

  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();

  Future<void> submit() async {
    if (busy) return;
    if (!supabaseReady) {
      _message('Supabase is not configured yet. Add your URL and anon key to run the app.');
      return;
    }
    setState(() => busy = true);

    try {
      if (signup) {
        await SupabaseService.instance.signUp(
          name: name.text,
          email: email.text,
          password: password.text,
        );
        if (mounted) {
          _message('Account created. Check your email if verification is enabled.');
        }
      } else {
        await SupabaseService.instance.signIn(
          email: email.text,
          password: password.text,
        );
      }
    } on AuthException catch (e) {
      if (mounted) _message(e.message);
    } catch (e) {
      if (mounted) _message(e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> forgot() async {
    if (email.text.trim().isEmpty) {
      _message('Enter your email first.');
      return;
    }
    if (!supabaseReady) {
      _message('Supabase is not configured yet. Add your URL and anon key to run the app.');
      return;
    }

    try {
      await SupabaseService.instance.sendPasswordReset(
        email.text,
        redirectTo: 'https://example.com/reset-password',
      );
      if (mounted) {
        _message(
          'If the account exists, a reset email will be sent. Configure the redirect URL in Supabase.',
        );
      }
    } catch (e) {
      if (mounted) _message(e.toString());
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value)),
    );
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 20),
                  const BrandMark(),
                  const SizedBox(height: 36),
                  Text(
                    signup ? 'Create Account' : 'Welcome Back!',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    signup ? 'Join 3Kings and book your next game.' : 'Sign in to your account',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 28),
                  if (signup)
                    ...[
                      TextField(
                        controller: name,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.person_outline),
                          hintText: 'Full name',
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.mail_outline),
                      hintText: 'Email address',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: obscure,
                    autofillHints: [
                      signup ? AutofillHints.newPassword : AutofillHints.password,
                    ],
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.lock_outline),
                      hintText: 'Password',
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => obscure = !obscure),
                        icon: Icon(
                          obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  if (!signup)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: forgot,
                        child: const Text('Forgot password?'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: busy ? 'Please wait…' : (signup ? 'Create Account' : 'Sign In'),
                    onPressed: busy ? null : submit,
                  ),
                  const SizedBox(height: 18),
                  const Row(
                    children: [
                      Expanded(child: Divider(color: line)),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('OR', style: TextStyle(color: muted)),
                      ),
                      Expanded(child: Divider(color: line)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: () => _message('Social login needs Google/Apple providers configured in Supabase.'),
                    icon: const Icon(Icons.g_mobiledata, size: 26),
                    label: const Text('Continue with Google'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: line),
                      padding: const EdgeInsets.all(15),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => _message('Apple login needs the Apple provider configured in Supabase.'),
                    icon: const Icon(Icons.apple),
                    label: const Text('Continue with Apple'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: line),
                      padding: const EdgeInsets.all(15),
                    ),
                  ),
                  const SizedBox(height: 22),
                  TextButton(
                    onPressed: () => setState(() => signup = !signup),
                    child: Text(
                      signup ? 'Already have an account?  Sign in' : "Don't have an account?  Sign up",
                      style: const TextStyle(color: lime),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int index = 0;
  int bookingsRefreshKey = 0;
  int walletRefreshKey = 0;
  final AppLinks _appLinks = AppLinks();
  late final StreamSubscription<Uri> _deepLinkSubscription;
  RealtimeChannel? bookingStatusChannel;

  @override
  void initState() {
    super.initState();
    _listenForDeepLinks();
    _listenForBookingChanges();
  }

  @override
  void dispose() {
    _deepLinkSubscription.cancel();
    if (bookingStatusChannel != null) {
      SupabaseService.instance.client.removeChannel(bookingStatusChannel!);
    }
    super.dispose();
  }

  Future<void> _listenForDeepLinks() async {
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null && mounted) {
      _handlePaymentCallback(initialUri);
    }

    _deepLinkSubscription = _appLinks.uriLinkStream.listen((uri) {
      if (mounted) {
        _handlePaymentCallback(uri);
      }
    });
  }

  void _listenForBookingChanges() {
    bookingStatusChannel = SupabaseService.instance.client
        .channel('booking-status-updates')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'court_bookings',
          callback: (_) {
            if (!mounted) return;
            setState(() {
              bookingsRefreshKey += 1;
              walletRefreshKey += 1;
            });
            final messenger = ScaffoldMessenger.maybeOf(context);
            messenger?.showSnackBar(
              const SnackBar(
                content: Text('Booking updated. Refreshing your payment status…'),
                duration: Duration(seconds: 2),
              ),
            );
          },
        )
        .subscribe();
  }

  void _handlePaymentCallback(Uri uri) {
    if (!isAppPaymentCallbackUri(uri)) return;

    final params = parsePaymentCallbackUri(uri);
    final status = paymentCallbackStatus(uri);
    final bookingId = params['booking_id'] ?? params['id'];
    final sessionId = params['session_id'] ?? params['checkout_session_id'];

    if (status.isEmpty && bookingId == null && sessionId == null) {
      return;
    }

    setState(() {
      index = 1;
      bookingsRefreshKey += 1;
      walletRefreshKey += 1;
    });

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (status == 'success') {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            bookingId != null
                ? 'Payment submitted. Confirming booking $bookingId…'
                : 'Payment submitted. Confirming your booking…',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      if (bookingId != null) {
        unawaited(_waitForPaymentConfirmation(bookingId));
      }
    } else if (status == 'cancelled') {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Payment was cancelled. Your booking status is refreshing…'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _waitForPaymentConfirmation(String bookingId) async {
    const maxAttempts = 15;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (!mounted) return;
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;

      try {
        final booking = await SupabaseService.instance
            .getMyBookingPaymentStatus(bookingId);
        if (!isBookingPaymentConfirmed(booking)) continue;

        setState(() {
          bookingsRefreshKey++;
          walletRefreshKey++;
        });
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Payment confirmed. Your booking status is updated.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      } catch (error) {
        debugPrint('Could not refresh PayMongo booking status: $error');
      }
    }

    if (!mounted) return;
    setState(() {
      bookingsRefreshKey++;
      walletRefreshKey++;
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Payment confirmation is still processing. Refresh your bookings shortly.'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
        onBook: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BookingPage()),
        ),
        onMyBookings: () => setState(() {
          index = 1;
          bookingsRefreshKey++;
        }),
      ),
      BookingsPage(key: ValueKey(bookingsRefreshKey)),
      WalletScreen(key: ValueKey(walletRefreshKey)),
      const ProfileScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF061917),
        indicatorColor: lime.withValues(alpha: 0.14),
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() {
          index = value;
          if (value == 1) bookingsRefreshKey++;
          if (value == 2) walletRefreshKey++;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home, color: lime),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month, color: lime),
            label: 'Bookings',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet, color: lime),
            label: 'Wallet',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person, color: lime),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final VoidCallback onBook;
  final VoidCallback onMyBookings;

  const HomeScreen({
    super.key,
    required this.onBook,
    required this.onMyBookings,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? settings;
  bool loading = true;
  RealtimeChannel? settingsChannel;

  @override
  void initState() {
    super.initState();
    load();
    settingsChannel = SupabaseService.instance.client
        .channel('home-court-settings')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'court_settings',
          callback: (_) => load(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (settingsChannel != null) {
      SupabaseService.instance.client.removeChannel(settingsChannel!);
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final value = await SupabaseService.instance.getSettings();
      if (mounted) {
        setState(() {
          settings = value;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final greeting = DateTime.now().hour < 12
        ? 'morning'
        : DateTime.now().hour < 18
            ? 'afternoon'
            : 'evening';

    return SafeArea(
      child: RefreshIndicator(
        color: lime,
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const BrandMark(compact: true),
            const SizedBox(height: 20),
            Text(
              'Good $greeting,',
              style: const TextStyle(color: muted),
            ),
            const Text(
              'Player! 👋',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            Container(
              height: 210,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  colors: [Color(0xFF183F3B), Color(0xFF0A2021), Color(0xFF172D17)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(color: line),
              ),
              child: Stack(
                children: [
                  Positioned(
                    right: -10,
                    top: 5,
                    child: Icon(Icons.sports_tennis, size: 150, color: lime.withValues(alpha: 0.09)),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const Text(
                          'PLAY PICKLEBALL',
                          style: TextStyle(
                            color: lime,
                            letterSpacing: 2,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'at 3Kings',
                          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
                        ),
                        const Text(
                          'One court. Your time. Your game.',
                          style: TextStyle(color: muted),
                        ),
                        const SizedBox(height: 15),
                        PrimaryButton(
                          label: 'Book a Court',
                          icon: Icons.calendar_month,
                          onPressed: widget.onBook,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            CardPanel(
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: lime.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.sports_tennis, color: lime),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Court 1 · Single Court',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          loading
                              ? 'Loading live rate…'
                              : '${settings?['currency'] == 'PHP' ? '₱' : (settings?['currency'] ?? '₱')}${settings?['hourly_rate'] ?? '—'} / hour',
                          style: const TextStyle(
                            color: lime,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Text(
                          'Live price from Supabase',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const SectionTitle('Quick access'),
            Row(
              children: [
                Expanded(
                  child: QuickTile(
                    icon: Icons.event_available,
                    title: 'My Bookings',
                    onTap: widget.onMyBookings,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: QuickTile(
                    icon: Icons.rule,
                    title: 'Court Rules',
                    onTap: () => showInfo(
                      context,
                      'Court Rules',
                      'Arrive on time. Keep the court clean. Bookings are hourly and the court is reserved for the confirmed time range.',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: QuickTile(
                    icon: Icons.support_agent,
                    title: 'Help',
                    onTap: () => showInfo(
                      context,
                      'Help & Support',
                      'Contact the court operator for booking and payment questions.',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const SectionTitle('How it works'),
            const InfoLine(
              icon: Icons.calendar_month,
              title: 'Choose your date',
              subtitle: 'Select the day you want to play.',
            ),
            const InfoLine(
              icon: Icons.schedule,
              title: 'Choose your hours',
              subtitle: 'Pick a duration and an available start time.',
            ),
            const InfoLine(
              icon: Icons.verified_user,
              title: 'Book with confidence',
              subtitle: 'Overlapping reservations are blocked by the database.',
            ),
          ],
        ),
      ),
    );
  }
}

class BookingPage extends StatelessWidget {
  const BookingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Book a Court'),
        backgroundColor: bg,
      ),
      body: const BookingScreen(),
    );
  }
}

class BookingScreen extends StatefulWidget {
  const BookingScreen({super.key});

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  DateTime date = DateTime.now().add(const Duration(days: 1));
  int hours = 2;
  int? selectedHour;
  double rate = 250;
  String currency = 'PHP';
  bool loadingRate = true;
  bool loadingSlots = false;
  bool saving = false;
  List<Map<String, dynamic>> occupied = [];
  RealtimeChannel? settingsChannel;
  final durations = [1, 2, 3, 4, 5, 6];

  @override
  void initState() {
    super.initState();
    refreshAll();
    settingsChannel = SupabaseService.instance.client
        .channel('booking-court-settings')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'court_settings',
          callback: (_) => loadRate(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (settingsChannel != null) {
      SupabaseService.instance.client.removeChannel(settingsChannel!);
    }
    super.dispose();
  }

  Future<void> refreshAll() async {
    await loadRate();
    await loadSlots();
  }

  Future<void> loadRate() async {
    try {
      final value = await SupabaseService.instance.getSettings();
      if (mounted) {
        setState(() {
          rate = (value['hourly_rate'] as num).toDouble();
          currency = value['currency'] ?? 'PHP';
          loadingRate = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => loadingRate = false);
        _snack('Could not load current price: $e');
      }
    }
  }

  Future<void> loadSlots() async {
    setState(() {
      loadingSlots = true;
      selectedHour = null;
    });

    try {
      final rows = await SupabaseService.instance.getBookingsForDay(date);
      if (mounted) {
        setState(() {
          occupied = rows;
          loadingSlots = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => loadingSlots = false);
        _snack('Could not load availability: $e');
      }
    }
  }

  bool available(int startHour) {
    final localStart = DateTime(date.year, date.month, date.day, startHour);
    final localEnd = localStart.add(Duration(hours: hours));

    if (!localStart.isAfter(DateTime.now())) return false;

    for (final booking in occupied) {
      final start = DateTime.parse(booking['booking_start'] as String).toLocal();
      final end = DateTime.parse(booking['booking_end'] as String).toLocal();
      if (localStart.isBefore(end) && localEnd.isAfter(start)) {
        return false;
      }
    }

    return true;
  }

  String money(num value) {
    final symbol = currency == 'PHP' ? '₱' : '$currency ';
    return '$symbol${value.toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '')}';
  }

  String hourLabel(int hour) {
    final value = DateTime(date.year, date.month, date.day, hour);
    return DateFormat('h:mm a').format(value);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> chooseDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 180)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(primary: lime, surface: panel),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() => date = picked);
      await loadSlots();
    }
  }

  Future<void> book() async {
    if (selectedHour == null) {
      _snack('Choose an available start time.');
      return;
    }

    final start = DateTime(date.year, date.month, date.day, selectedHour!);
    final total = rate * hours;

    final method = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: panel,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Choose payment method',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '${DateFormat('EEE, MMM d, yyyy').format(date)} · ${hourLabel(selectedHour!)} – ${hourLabel(selectedHour! + hours)}',
                  style: const TextStyle(color: muted),
                ),
                const SizedBox(height: 8),
                Text(
                  'Total: ${money(total)}',
                  style: const TextStyle(
                    color: lime,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                for (final item in bookingPaymentOptions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, item['value']),
                      child: Text(item['label'] ?? ''),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (method == null) return;

    setState(() => saving = true);

    try {
      final booking = await SupabaseService.instance.createBooking(
        start: start,
        hours: hours,
        paymentMethod: method,
      );

      if (method == 'paymongo') {
        Map<String, dynamic> checkout;
        try {
          checkout = await SupabaseService.instance.createPayMongoCheckout(
            bookingId: booking['id'].toString(),
          );
        } catch (e) {
          if (!mounted) return;
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: panel,
              title: const Text('Booking saved; payment not started'),
              content: Text(
                'Your booking is saved and remains unpaid. You can retry PayMongo from My Bookings.\n\n${e.toString().replaceFirst('Exception: ', '')}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Go to My Bookings'),
                ),
              ],
            ),
          );
          if (!mounted) return;
          Navigator.of(context).pop(true);
          return;
        }
        final checkoutUrl = checkout['checkout_url'];
        final checkoutUri = checkoutUrl is String ? Uri.tryParse(checkoutUrl) : null;
        if (!isPayMongoCheckoutUri(checkoutUri)) {
          throw StateError('PayMongo returned an invalid checkout URL.');
        }
        final launched = await launchUrl(
          checkoutUri!,
          mode: LaunchMode.externalApplication,
          webOnlyWindowName: '_self',
        );
        if (!launched) throw StateError('Could not open PayMongo checkout.');
        if (!mounted) return;

        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: panel,
            icon: const Icon(Icons.open_in_new, color: lime, size: 48),
            title: const Text('PayMongo checkout opened'),
            content: const Text(
              'Complete payment in the browser. Your booking will remain pending until PayMongo confirms the payment.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
            ],
          ),
        );

        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            backgroundColor: panel,
            icon: const Icon(Icons.check_circle, color: lime, size: 56),
            title: const Text('Booking created!'),
            content: Text(
              'Your reservation is ${booking['status']}.\n'
              '${DateFormat('EEE, MMM d').format(date)} · ${hourLabel(selectedHour!)} for $hours hour(s)\n'
              'Total: ${money(total)}\n\n'
              'Payment is due at the court. Staff will confirm the reservation after payment.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      _snack('Booking failed: ${e.toString().replaceFirst('Exception: ', '')}');
      await loadSlots();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        color: lime,
        onRefresh: refreshAll,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text(
              'Book a Court',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'One court · Hourly reservation',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 20),
            const StepProgress(),
            const SizedBox(height: 20),
            const SectionTitle('1 · Select date'),
            CardPanel(
              child: InkWell(
                onTap: chooseDate,
                child: Row(
                  children: [
                    const Icon(Icons.calendar_month, color: lime),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            DateFormat('EEEE, MMMM d, yyyy').format(date),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const Text(
                            'Tap to change date',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const SectionTitle('2 · Choose duration'),
            const Text(
              'How many hours would you like to reserve?',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final hour in durations)
                  ChoiceChip(
                    label: Text(
                      '$hour ${hour == 1 ? 'hour' : 'hours'}\n${money(rate * hour)}',
                      textAlign: TextAlign.center,
                    ),
                    selected: hours == hour,
                    onSelected: (_) {
                      setState(() {
                        hours = hour;
                        selectedHour = null;
                      });
                    },
                    selectedColor: lime,
                    backgroundColor: panel,
                    labelStyle: TextStyle(
                      color: hours == hour ? bg : Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            CardPanel(
              child: Row(
                children: [
                  const Icon(Icons.payments_outlined, color: lime),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Live hourly rate',
                          style: TextStyle(color: muted),
                        ),
                        Text(
                          loadingRate ? 'Loading…' : '${money(rate)} / hour',
                          style: const TextStyle(
                            fontSize: 18,
                            color: lime,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'Estimated total',
                        style: TextStyle(color: muted),
                      ),
                      Text(
                        money(rate * hours),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Text(
              '3 · Select start time (${hours} ${hours == 1 ? 'hour' : 'hours'})',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const Text(
              'Times that overlap another reservation are disabled.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            if (loadingSlots)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(color: lime),
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 15,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 1.55,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemBuilder: (context, index) {
                  final hour = index + 6;
                  final ok = available(hour);
                  final selected = selectedHour == hour;

                  return InkWell(
                    onTap: ok ? () => setState(() => selectedHour = hour) : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected ? lime.withValues(alpha: 0.16) : panel,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected ? lime : ok ? line : Colors.redAccent.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            hourLabel(hour),
                            style: TextStyle(
                              color: ok ? Colors.white : muted,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ok ? (selected ? 'Selected' : 'Available') : 'Unavailable',
                            style: TextStyle(
                              fontSize: 10,
                              color: selected ? lime : ok ? Colors.greenAccent : Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 20),
            CardPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Booking summary',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  SummaryRow(label: 'Court', value: 'Court 1'),
                  SummaryRow(
                    label: 'Date',
                    value: DateFormat('MMM d, yyyy').format(date),
                  ),
                  SummaryRow(
                    label: 'Duration',
                    value: '$hours ${hours == 1 ? 'hour' : 'hours'}',
                  ),
                  SummaryRow(
                    label: 'Start time',
                    value: selectedHour == null ? 'Not selected' : hourLabel(selectedHour!),
                  ),
                  SummaryRow(
                    label: 'End time',
                    value: selectedHour == null ? '—' : hourLabel(selectedHour! + hours),
                  ),
                  const Divider(color: line),
                  SummaryRow(
                    label: 'Total',
                    value: money(rate * hours),
                    emphasize: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: saving ? 'Creating booking…' : 'Continue to Payment',
              icon: Icons.arrow_forward,
              onPressed: saving || loadingSlots || loadingRate ? null : book,
            ),
            const SizedBox(height: 10),
            const Text(
              'Your booking is validated in Supabase. Conflicting reservations are rejected even if two users select the same time.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class BookingListScreen extends StatefulWidget {
  final bool past;

  const BookingListScreen({super.key, required this.past});

  @override
  State<BookingListScreen> createState() => _BookingListScreenState();
}

class _BookingListScreenState extends State<BookingListScreen> {
  late Future<List<Map<String, dynamic>>> future;

  @override
  void initState() {
    super.initState();
    future = SupabaseService.instance.getMyBookings(past: widget.past);
  }

  Future<void> reload() async {
    if (!mounted) return;
    final next = SupabaseService.instance.getMyBookings(past: widget.past);
    setState(() {
      future = next;
    });
    try {
      await next;
    } catch (_) {
      // FutureBuilder presents the load error.
    }
  }

  String cancellationErrorMessage(Object error, {required bool payMongo}) {
    final raw = error is StateError
        ? error.message
        : (error is Error && error.toString().startsWith('Exception: ')
            ? error.toString().replaceFirst('Exception: ', '')
            : error.toString());

    final message = raw.toString().trim();
    final lower = message.toLowerCase();

    if (message.isEmpty) {
      return 'We could not cancel this booking. Your bookings have been refreshed; please try again.';
    }

    if (lower.contains('only pending bookings can be cancelled')) {
      return 'This booking has already changed. Your bookings have been refreshed.';
    }
    if (payMongo && (
        lower.contains('no active paymongo checkout') ||
        lower.contains('not eligible for paymongo checkout') ||
        lower.contains('could not expire this checkout') ||
        lower.contains('booking is not eligible') ||
        lower.contains('payment may have completed'))) {
      return 'This checkout is no longer active. Refresh your bookings and try again.';
    }
    if (payMongo && (lower.contains('404') || lower.contains('function not found'))) {
      return 'PayMongo cancellation is unavailable. Please contact support.';
    }
    if (payMongo && (lower.contains('clientfailed to fetch') || lower.contains('status: 0'))) {
      return 'Could not reach PayMongo. Check your connection and try again.';
    }
    if (lower.contains('401') || lower.contains('unauthorized')) {
      return 'Your session may have expired. Sign in again, then retry.';
    }
    return message.replaceFirst(RegExp(r'^(exception|error)\s*:\s*', caseSensitive: false), '').trim();
  }

  Future<void> continuePayMongo(String bookingId) async {
    try {
      final checkout = await SupabaseService.instance.createPayMongoCheckout(
        bookingId: bookingId,
      );
      final checkoutUrl = checkout['checkout_url'];
      final checkoutUri = checkoutUrl is String ? Uri.tryParse(checkoutUrl) : null;
      if (!isPayMongoCheckoutUri(checkoutUri)) {
        throw StateError('PayMongo returned an invalid checkout URL.');
      }
      final launched = await launchUrl(
        checkoutUri!,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      );
      if (!launched) throw StateError('Could not open PayMongo checkout.');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  String price(dynamic value) {
    return '₱${(value as num).toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '')}';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: lime));
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Unable to load bookings. ${snapshot.error}'),
            ),
          );
        }

        final rows = snapshot.data ?? [];

        if (rows.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_month, size: 52, color: muted),
                const SizedBox(height: 12),
                Text(widget.past ? 'No past bookings' : 'No upcoming bookings'),
                const SizedBox(height: 8),
                const Text(
                  'Your reservations will appear here.',
                  style: TextStyle(color: muted),
                ),
                TextButton(onPressed: reload, child: const Text('Refresh')),
              ],
            ),
          );
        }

        return RefreshIndicator(
          color: lime,
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final booking in rows)
                () {
                  final start = DateTime.parse(booking['start_at']).toLocal();
                  final end = DateTime.parse(booking['end_at']).toLocal();
                  final status = booking['status'] as String;
                  final paymentStatus = booking['payment_status']?.toString() ?? 'unpaid';

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: CardPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: lime.withValues(alpha: 0.13),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.sports_tennis, color: lime),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      booking['court_name'] ?? 'Court 1',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 17,
                                      ),
                                    ),
                                    Text(
                                      DateFormat('EEE, MMM d, yyyy').format(start),
                                      style: const TextStyle(color: muted),
                                    ),
                                  ],
                                ),
                              ),
                              StatusPill(
                                status: status,
                                label: 'Booking: ${status.toUpperCase()}',
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SummaryRow(
                            label: 'Time',
                            value: '${DateFormat('h:mm a').format(start)} – ${DateFormat('h:mm a').format(end)}',
                          ),
                          SummaryRow(
                            label: 'Duration',
                            value: '${booking['duration_hours']} hours',
                          ),
                          SummaryRow(
                            label: 'Total',
                            value: price(booking['total_price']),
                            emphasize: true,
                          ),
                          SummaryRow(
                            label: 'Payment status',
                            value: paymentStatus.replaceAll('_', ' ').toUpperCase(),
                          ),
                          if (status == 'pending' && booking['payment_method'] == 'paymongo')
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => continuePayMongo(booking['id'].toString()),
                                icon: const Icon(Icons.open_in_new),
                                label: const Text('Continue PayMongo payment'),
                              ),
                            ),
                          if (status == 'pending')
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () async {
                                  final payMongo = booking['payment_method'] == 'paymongo';
                                  try {
                                    if (payMongo) {
                                      await SupabaseService.instance.cancelPayMongoCheckout(
                                        booking['id'],
                                      );
                                    } else {
                                      await SupabaseService.instance.cancelBooking(booking['id']);
                                    }
                                    await reload();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Booking cancelled.')),
                                    );
                                  } catch (e) {
                                    await reload();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          cancellationErrorMessage(e, payMongo: payMongo),
                                        ),
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.cancel_outlined),
                                label: const Text('Cancel booking'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }(),
            ],
          ),
        );
      },
    );
  }
}

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text(
            'Wallet',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 16),
          CardPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Payment methods',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Choose a payment method at checkout',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Walk-in · PayMongo hosted checkout',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 12),
                const Text(
                  'PayMongo payments are confirmed by a secure server webhook. Walk-in payments are confirmed by court staff.',
                  style: TextStyle(color: muted, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const SectionTitle('Booking payment history'),
          const SizedBox(height: 360, child: BookingListScreen(past: true)),
        ],
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final name = TextEditingController();
  String email = '';
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final profile = await SupabaseService.instance.getMyProfile();
      name.text = profile['full_name'] ?? '';
      email = profile['email'] ?? SupabaseService.instance.currentUser?.email ?? '';
    } catch (_) {
      email = SupabaseService.instance.currentUser?.email ?? '';
    }

    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text(
            'Profile',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 20),
          CardPanel(
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 36,
                  backgroundColor: Color(0xFF203B30),
                  child: Icon(Icons.person, color: lime, size: 38),
                ),
                const SizedBox(height: 12),
                Text(email, style: const TextStyle(color: muted)),
                const SizedBox(height: 20),
                TextField(
                  controller: name,
                  enabled: !loading,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Save Profile',
                  onPressed: loading
                      ? null
                      : () async {
                          try {
                            await SupabaseService.instance.updateMyProfile(
                              fullName: name.text,
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Profile updated.')),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.toString())),
                              );
                            }
                          }
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const SectionTitle('Account'),
          MenuRow(
            icon: Icons.calendar_month,
            title: 'My Bookings',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BookingsPage()),
            ),
          ),
          MenuRow(
            icon: Icons.rule,
            title: 'Court Rules',
            onTap: () => showInfo(
              context,
              'Court Rules',
              'Bookings are hourly. Please arrive on time and keep the court clean.',
            ),
          ),
          MenuRow(
            icon: Icons.help_outline,
            title: 'Help & Support',
            onTap: () => showInfo(
              context,
              'Help & Support',
              'Contact your court operator for assistance.',
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async => SupabaseService.instance.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign Out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: line),
              padding: const EdgeInsets.all(15),
            ),
          ),
        ],
      ),
    );
  }
}

class BookingsPage extends StatefulWidget {
  const BookingsPage({super.key});

  @override
  State<BookingsPage> createState() => _BookingsPageState();
}

class _BookingsPageState extends State<BookingsPage> {
  int refreshKey = 0;

  Future<void> openBookingPage() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const BookingPage()),
    );
    if (created == true && mounted) {
      setState(() => refreshKey++);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My Bookings'),
          backgroundColor: bg,
          actions: [
            TextButton.icon(
              onPressed: openBookingPage,
              icon: const Icon(Icons.add),
              label: const Text('Book court'),
            ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Upcoming'), Tab(text: 'Past')],
            indicatorColor: lime,
            labelColor: lime,
          ),
        ),
        body: TabBarView(
          children: [
            BookingListScreen(
              key: ValueKey('upcoming-$refreshKey'),
              past: false,
            ),
            BookingListScreen(
              key: ValueKey('past-$refreshKey'),
              past: true,
            ),
          ],
        ),
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  final bool compact;

  const BrandMark({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.workspace_premium, color: lime, size: compact ? 30 : 42),
        const SizedBox(width: 5),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '3Kings',
              style: TextStyle(
                fontSize: compact ? 26 : 38,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                letterSpacing: -1.5,
                color: Colors.white,
              ),
            ),
            Text(
              'PLAY · BOOK · REPEAT',
              style: TextStyle(
                fontSize: compact ? 8 : 10,
                letterSpacing: 2,
                color: lime,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class CardPanel extends StatelessWidget {
  final Widget child;

  const CardPanel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: line),
      ),
      child: child,
    );
  }
}

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 18),
        label: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: lime,
          foregroundColor: bg,
          disabledBackgroundColor: lime.withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          elevation: 0,
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String title;

  const SectionTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;

  const SummaryRow({
    super.key,
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: emphasize ? Colors.white : muted,
                fontWeight: emphasize ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: emphasize ? lime : Colors.white,
              fontWeight: emphasize ? FontWeight.w900 : FontWeight.w600,
              fontSize: emphasize ? 18 : 14,
            ),
          ),
        ],
      ),
    );
  }
}

class StepProgress extends StatelessWidget {
  const StepProgress({super.key});

  @override
  Widget build(BuildContext context) {
    final steps = ['Date', 'Duration', 'Time', 'Review'];

    return Row(
      children: [
        for (int i = 0; i < steps.length; i++)
          Expanded(
            child: Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: i == 0 ? lime : panel2,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: i == 0 ? bg : muted,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    steps[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                if (i < steps.length - 1)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: SizedBox(
                      width: 20,
                      child: Divider(color: line),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class QuickTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const QuickTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: CardPanel(
        child: Column(
          children: [
            Icon(icon, color: lime, size: 25),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

class InfoLine extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const InfoLine({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: lime.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: lime),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  final String status;
  final String? label;

  const StatusPill({super.key, required this.status, this.label});

  @override
  Widget build(BuildContext context) {
    final color = status == 'confirmed'
        ? Colors.greenAccent
        : status == 'cancelled'
            ? Colors.redAccent
            : lime;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label ?? status.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class MenuRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const MenuRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: lime),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: panel,
    );
  }
}

void showInfo(BuildContext context, String title, String body) {
  showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: panel,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
