# SSRVPN ProGuard Rules

# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Provider
-keep class * extends androidx.lifecycle.ViewModel { *; }

# ClashService native
-keep class com.ssrvpn.** { *; }

# Suppress missing Google Play Core classes (not used in non-Play-Store builds)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
