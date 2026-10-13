# Supabase config

This folder holds the project’s Supabase startup settings.

Use the app with the project credentials as runtime dart defines:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

The app reads those values in [lib/config/supabase/supabase_config.dart](supabase_config.dart) and initializes Supabase during startup.
