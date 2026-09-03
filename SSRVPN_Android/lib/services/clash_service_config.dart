part of 'clash_service.dart';

// Mihomo on Android can match exact package names. Browsers stay out so
// domestic browsing still follows Smart mode instead of being fully proxied.
const List<String> _androidForcedProxyAppRules = [
  'PROCESS-NAME,org.telegram.messenger,PROXY',
  'PROCESS-NAME,org.thunderdog.challegram,PROXY',
  'PROCESS-NAME,com.whatsapp,PROXY',
  'PROCESS-NAME,com.whatsapp.w4b,PROXY',
  'PROCESS-NAME,org.thoughtcrime.securesms,PROXY',
  'PROCESS-NAME,com.instagram.android,PROXY',
  'PROCESS-NAME,com.instagram.barcelona,PROXY',
  'PROCESS-NAME,com.facebook.katana,PROXY',
  'PROCESS-NAME,com.facebook.lite,PROXY',
  'PROCESS-NAME,com.facebook.orca,PROXY',
  'PROCESS-NAME,com.twitter.android,PROXY',
  'PROCESS-NAME,com.discord,PROXY',
  'PROCESS-NAME,com.reddit.frontpage,PROXY',
  'PROCESS-NAME,com.google.android.youtube,PROXY',
  'PROCESS-NAME,com.google.android.apps.youtube.music,PROXY',
  'PROCESS-NAME,com.google.android.gm,PROXY',
  'PROCESS-NAME,com.google.android.apps.bard,PROXY',
  'PROCESS-NAME,com.google.android.apps.docs,PROXY',
  'PROCESS-NAME,com.google.android.apps.maps,PROXY',
  'PROCESS-NAME,com.google.android.apps.photos,PROXY',
  'PROCESS-NAME,com.openai.chatgpt,PROXY',
  'PROCESS-NAME,com.anthropic.claude,PROXY',
  'PROCESS-NAME,com.netflix.mediaclient,PROXY',
  'PROCESS-NAME,com.spotify.music,PROXY',
  'PROCESS-NAME,com.zhiliaoapp.musically,PROXY',
  'PROCESS-NAME,com.github.android,PROXY',
  'PROCESS-NAME,com.dropbox.android,PROXY',
  'PROCESS-NAME,com.Slack,PROXY',
  'PROCESS-NAME,tv.twitch.android.app,PROXY',
  'PROCESS-NAME,com.pinterest,PROXY',
  'PROCESS-NAME,com.snapchat.android,PROXY',
  'PROCESS-NAME,xyz.blueskyweb.app,PROXY',
];

extension AndroidClashConfig on ClashService {
  String _androidTunConfig(AppSettings settings) {
    final buffer = StringBuffer()
      ..writeln('tun:')
      ..writeln('  enable: true')
      ..writeln('  stack: ${settings.tunStack}')
      ..writeln('  dns-hijack:')
      ..writeln('    - any:53')
      ..writeln('  auto-route: true')
      ..writeln('  auto-detect-interface: true')
      ..writeln('  inet6-address:')
      ..writeln('    - ${AppConstants.tunInet6Address}')
      ..writeln('  route-exclude-address:');
    for (final address in AppConstants.routeExcludeAddresses) {
      // Android 原生 VPN 接管 ::/0；不排除 IPv6，避免绕过或黑洞。
      if (address.contains(':')) continue;
      buffer.writeln('    - $address');
    }
    return buffer.toString().trimRight();
  }
}
