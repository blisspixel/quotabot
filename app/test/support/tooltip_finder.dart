import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

extension MaterialTooltipFinders on CommonFinders {
  /// Finds a material_ui [Tooltip] by [message].
  ///
  /// [CommonFinders.byTooltip] only recognizes `package:flutter/material.dart`
  /// Tooltip. This app imports material_ui, and chrome tooltips set
  /// `excludeFromSemantics`, so that finder never sees the message.
  Finder byMaterialTooltip(Pattern message, {bool skipOffstage = true}) {
    return byWidgetPredicate((Widget widget) {
      if (widget is! Tooltip) return false;
      final tooltipMessage =
          widget.message ?? widget.richMessage?.toPlainText() ?? '';
      return message is RegExp
          ? message.hasMatch(tooltipMessage)
          : tooltipMessage == message;
    }, skipOffstage: skipOffstage);
  }
}
