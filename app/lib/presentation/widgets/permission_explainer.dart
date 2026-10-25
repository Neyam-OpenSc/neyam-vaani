/// The just-in-time permission explainer.
///
/// PRIVACY_CHARTER.md: every permission is asked for only when an action
/// needs it, always with one plain sentence **in the user's language**.
/// This dialog is that sentence — no icons, no urgency, no dark-pattern
/// styling, and an equally easy "Not now" (tender UX: the user's
/// autonomy outranks the app's convenience).
///
/// All text arrives as message keys; [resolveText] turns keys into
/// sentences. The default resolver is the English charter table, used
/// only until the l10n layer supplies the user's language.
library;

import 'package:flutter/material.dart';

import '../../domain/entities/action_result.dart';

/// English fallback texts — the charter's exact sentences.
///
/// l10n overrides every key; unknown keys resolve to themselves so a
/// missing translation is visible in review, never silently English.
const Map<String, String> kDefaultPermissionTexts = <String, String>{
  'permission.dialog.title': 'Vaani needs one permission',
  'permission.dialog.allow': 'Allow',
  'permission.dialog.later': 'Not now',
  'permission.microphone.name': 'Microphone',
  'permission.microphone.why': 'To hear you',
  'permission.camera.name': 'Camera',
  'permission.camera.why': 'To photograph your document',
  'permission.storage.name': 'Storage',
  'permission.storage.why': 'To save your document',
  'permission.sms.name': 'SMS',
  'permission.sms.why': 'To send the message you asked for',
  'permission.phone.name': 'Phone',
  'permission.phone.why': 'To make the call you asked for',
  'permission.location.name': 'Location',
  'permission.location.why': "To find what's nearby",
  'permission.notifications.name': 'Notifications',
  'permission.notifications.why': 'To remind you when you asked',
  'permission.unknown.why': 'To do what you asked',
};

/// Resolves a message key to user-facing text.
typedef PermissionTextResolver = String Function(String key);

/// The default resolver: [kDefaultPermissionTexts], keys passing through.
String defaultPermissionText(String key) =>
    kDefaultPermissionTexts[key] ?? key;

/// A calm two-button dialog explaining one permission in one sentence.
class PermissionExplainer extends StatelessWidget {
  const PermissionExplainer({
    super.key,
    required this.permission,
    required this.whyKey,
    this.resolveText = defaultPermissionText,
    required this.onGrant,
    required this.onDeny,
  });

  /// The permission being explained.
  final VaaniPermission permission;

  /// Key of the charter why-sentence (e.g. 'permission.sms.why').
  final String whyKey;

  /// Turns keys into sentences in the user's language.
  final PermissionTextResolver resolveText;

  /// Called when the user chooses Allow.
  final VoidCallback onGrant;

  /// Called when the user chooses Not now. Denying must be as easy as
  /// allowing — never styled weaker or smaller.
  final VoidCallback onDeny;

  /// Shows the explainer and completes with the user's answer.
  ///
  /// Completes `false` when the dialog is dismissed any other way.
  static Future<bool> show(
    BuildContext context, {
    required VaaniPermission permission,
    required String whyKey,
    PermissionTextResolver? resolveText,
  }) async {
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => PermissionExplainer(
        permission: permission,
        whyKey: whyKey,
        resolveText: resolveText ?? defaultPermissionText,
        onGrant: () => Navigator.of(dialogContext).pop(true),
        onDeny: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final String name = resolveText('permission.${permission.id}.name');
    final String why = resolveText(whyKey);
    final String allow = resolveText('permission.dialog.allow');
    final String later = resolveText('permission.dialog.later');
    return AlertDialog(
      title: Text(resolveText('permission.dialog.title')),
      content: Semantics(
        label: '$name. $why',
        child: Text(
          '$name — $why',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
      actions: <Widget>[
        Semantics(
          label: later,
          button: true,
          child: TextButton(onPressed: onDeny, child: Text(later)),
        ),
        Semantics(
          label: allow,
          button: true,
          child: TextButton(onPressed: onGrant, child: Text(allow)),
        ),
      ],
    );
  }
}
