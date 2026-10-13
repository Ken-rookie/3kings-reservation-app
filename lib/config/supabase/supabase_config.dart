import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  const SupabaseConfig._();

  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://kaloyqomoehfmfexwtja.supabase.co',
  );

  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImthbG95cW9tb2VoZm1mZXh3dGphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2MzI0MjMsImV4cCI6MjEwNzIwODQyM30.yCj4PmYh2bD37UBZguHZnm0wxQeDpYwqnm7Clw0aMP8',
  );

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  static Future<void> initializeIfConfigured() async {
    if (!isConfigured) return;

    await Supabase.initialize(
      url: url,
      anonKey: anonKey,
    );
  }
}
