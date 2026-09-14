import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'smart_rule_bundle.dart';

/// Trust only signed data snapshots, never remote executable configuration.
class SmartRuleSignature {
  static const publicKey = 'CB4kRMnlhTBBMZuvCD8wpcgeHLFK8LVHDhwRQTZtVmE=';

  static Future<bool> verify(String text,
      {String trustedPublicKey = publicKey}) async {
    try {
      final descriptor = SmartRuleBundle.parseVersionDescriptor(text);
      final document = jsonDecode(text) as Map<String, dynamic>;
      final signature = document['signature'];
      if (signature is! String || signature.length > 128) return false;
      final bytes = base64Decode(signature);
      if (bytes.length != 64) return false;
      return await Ed25519().verify(
        utf8.encode(
            'SSRVPN rules v1\n${descriptor.version}\n${descriptor.manifestSha256}\n'),
        signature: Signature(bytes,
            publicKey: SimplePublicKey(base64Decode(trustedPublicKey),
                type: KeyPairType.ed25519)),
      );
    } on Object {
      return false;
    }
  }
}
