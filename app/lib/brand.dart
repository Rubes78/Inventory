import 'package:flutter/material.dart';

/// Brijj branding, matched to brijjworks.com: blue #0070B9 primary, green #54BB70 accent,
/// Fraunces (semibold serif) headings in black, Inter body text in warm gray #58564F,
/// warm off-white #F3EEEC section backgrounds, pill buttons and well-rounded cards.
/// Fonts are bundled in assets/fonts (SIL OFL) so the app looks the same offline.

const brijjBlue = Color(0xFF0070B9);
const brijjGreen = Color(0xFF54BB70);

/// Headings (the site uses pure black).
const brijjInk = Color(0xFF111111);

/// Body text.
const brijjText = Color(0xFF58564F);

/// Page background behind white cards.
const brijjSand = Color(0xFFF3EEEC);

/// Hairlines and card borders, warm to sit on [brijjSand].
const brijjLine = Color(0xFFE4DDD9);

/// Light tints of the brand colors for banners and highlighted rows.
const brijjBlueTint = Color(0xFFE6F1F8);
const brijjGreenTint = Color(0xFFE8F5EC);

/// Status colors. Success is a darker Brijj green so icons and text stay readable on white;
/// warning and danger stay orange and red because they carry meaning (flagged, irreversible).
const statusSuccess = Color(0xFF2E8B4E);
const statusWarning = Color(0xFFB45F06);
const statusWarningTint = Color(0xFFFDF1E3);
const statusDanger = Color(0xFFC62828);
const statusDangerTint = Color(0xFFFCE9E9);

const headingFont = 'Fraunces';
const bodyFont = 'Inter';

ThemeData brijjTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: brijjBlue).copyWith(
    primary: brijjBlue,
    onPrimary: Colors.white,
    primaryContainer: brijjBlueTint,
    onPrimaryContainer: const Color(0xFF00436F),
    secondary: brijjGreen,
    onSecondary: brijjInk,
    secondaryContainer: brijjGreenTint,
    onSecondaryContainer: const Color(0xFF1E5E33),
    surface: Colors.white,
    onSurface: brijjInk,
    onSurfaceVariant: brijjText,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFFAF8F7),
    surfaceContainer: const Color(0xFFF7F4F2),
    surfaceContainerHigh: brijjSand,
    surfaceContainerHighest: const Color(0xFFEBE5E2),
    outline: const Color(0xFFB9B1AC),
    outlineVariant: brijjLine,
    error: statusDanger,
  );

  TextStyle heading(double size) =>
      TextStyle(fontFamily: headingFont, fontWeight: FontWeight.w600, color: brijjInk, fontSize: size, height: 1.2);

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: bodyFont).textTheme;
  final text = base
      .apply(bodyColor: brijjText, displayColor: brijjInk, fontFamily: bodyFont)
      .copyWith(
        displaySmall: heading(34),
        headlineMedium: heading(28),
        headlineSmall: heading(24),
        titleLarge: heading(22),
        titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: brijjInk),
        labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      );

  final roundedField = OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: const BorderSide(color: brijjLine),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: bodyFont,
    textTheme: text,
    scaffoldBackgroundColor: brijjSand,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: brijjInk,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: heading(22),
      iconTheme: const IconThemeData(color: brijjBlue),
      actionsIconTheme: const IconThemeData(color: brijjBlue),
      shape: const Border(bottom: BorderSide(color: brijjLine)),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: brijjLine),
      ),
    ),
    listTileTheme: const ListTileThemeData(tileColor: Colors.white, iconColor: brijjBlue, textColor: brijjInk),
    dividerTheme: const DividerThemeData(color: brijjLine, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        // Clearly not tappable (e.g. Submit while offline).
        disabledBackgroundColor: brijjLine,
        disabledForegroundColor: const Color(0xFF8F8983),
        textStyle: const TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w600, fontSize: 16),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        foregroundColor: brijjBlue,
        side: const BorderSide(color: brijjBlue, width: 1.5),
        textStyle: const TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brijjBlue,
        textStyle: const TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w600),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: brijjGreen,
      foregroundColor: brijjInk,
      shape: StadiumBorder(),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w600)),
        side: const WidgetStatePropertyAll(BorderSide(color: brijjLine)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? brijjBlue : Colors.white,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : brijjText,
        ),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : brijjText),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      prefixIconColor: brijjBlue,
      border: roundedField,
      enabledBorder: roundedField,
      focusedBorder: roundedField.copyWith(borderSide: const BorderSide(color: brijjBlue, width: 2)),
      errorBorder: roundedField.copyWith(borderSide: const BorderSide(color: statusDanger)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: heading(22),
      contentTextStyle: const TextStyle(fontFamily: bodyFont, fontSize: 16, color: brijjText, height: 1.4),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brijjInk,
      contentTextStyle: const TextStyle(fontFamily: bodyFont, color: Colors.white, fontSize: 15),
      actionTextColor: brijjGreen,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    badgeTheme: const BadgeThemeData(backgroundColor: brijjBlue, textColor: Colors.white),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: brijjBlue, linearTrackColor: brijjBlueTint),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? brijjBlue : null),
    ),
  );
}
