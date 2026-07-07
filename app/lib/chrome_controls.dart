import 'package:flutter/material.dart';

/// Compact icon button used by the frameless desktop chrome.
class AppChromeIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final String tooltip;

  const AppChromeIconButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 15, color: color),
      ),
    );
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(label: tooltip, button: true, child: button),
    );
  }
}
