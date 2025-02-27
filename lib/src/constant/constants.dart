import 'dart:convert';

/// A constant that is true if the application was compiled in release mode.
///
/// More specifically, this is a constant that is true if the application was
/// compiled in Dart with the '-Ddart.vm.product=true' flag.
///
/// Since this is a const value, it can be used to indicate to the compiler that
/// a particular block of code will not be executed in release mode, and hence
/// can be removed.
///
/// Generally it is better to use [kDebugMode] or `assert` to gate code, since
/// using [kReleaseMode] will introduce differences between release and profile
/// builds, which makes performance testing less representative.
///
/// See also:
///
///  * [kDebugMode], which is true in debug builds.
///  * [kProfileMode], which is true in profile builds.
const bool kReleaseMode = bool.fromEnvironment('dart.vm.product');

/// A constant that is true if the application was compiled in profile mode.
///
/// More specifically, this is a constant that is true if the application was
/// compiled in Dart with the '-Ddart.vm.profile=true' flag.
///
/// Since this is a const value, it can be used to indicate to the compiler that
/// a particular block of code will not be executed in profile mode, an hence
/// can be removed.
///
/// See also:
///
///  * [kDebugMode], which is true in debug builds.
///  * [kReleaseMode], which is true in release builds.
const bool kProfileMode = bool.fromEnvironment('dart.vm.profile');

/// A constant that is true if the application was compiled in debug mode.
///
/// More specifically, this is a constant that is true if the application was
/// not compiled with '-Ddart.vm.product=true' and '-Ddart.vm.profile=true'.
///
/// Since this is a const value, it can be used to indicate to the compiler that
/// a particular block of code will not be executed in debug mode, and hence
/// can be removed.
///
/// An alternative strategy is to use asserts, as in:
///
/// ```dart
/// assert(() {
///   // ...debug-only code here...
///   return true;
/// }());
/// ```
///
/// See also:
///
///  * [kReleaseMode], which is true in release builds.
///  * [kProfileMode], which is true in profile builds.
const bool kDebugMode = !kReleaseMode && !kProfileMode;

/// The epsilon of tolerable double precision error.
///
/// This is used in various places in the framework to allow for floating point
/// precision loss in calculations. Differences below this threshold are safe to
/// disregard.
const double precisionErrorTolerance = 1e-10;

/// The key used to store the last update id in the database.
const String updateIdKey = 'update_id';

/// The key used to store the last reports date in the database.
const String lastReportKey = 'last_report';

/// Captcha lifetime in seconds.
const int captchaLifetime = 1 * 60; // 1 minute

// --- Keyboard Callbacks --- //

const kbCaptcha = 'keyboard.captcha';

const String kbCaptchaOne = '$kbCaptcha.one',
    kbCaptchaTwo = '$kbCaptcha.two',
    kbCaptchaThree = '$kbCaptcha.three',
    kbCaptchaFour = '$kbCaptcha.four',
    kbCaptchaFive = '$kbCaptcha.five',
    kbCaptchaSix = '$kbCaptcha.six',
    kbCaptchaSeven = '$kbCaptcha.seven',
    kbCaptchaEight = '$kbCaptcha.eight',
    kbCaptchaNine = '$kbCaptcha.nine',
    kbCaptchaZero = '$kbCaptcha.zero',
    kbCaptchaRefresh = '$kbCaptcha.refresh',
    kbCaptchaBackspace = '$kbCaptcha.backspace';

final String defaultCaptchaKeyboard = jsonEncode({
  'inline_keyboard': <List<Map<String, Object?>>>[
    <Map<String, Object?>>[
      <String, Object?>{'text': '1️⃣', 'callback_data': kbCaptchaOne},
      <String, Object?>{'text': '2️⃣', 'callback_data': kbCaptchaTwo},
      <String, Object?>{'text': '3️⃣', 'callback_data': kbCaptchaThree},
    ],
    <Map<String, Object?>>[
      <String, Object?>{'text': '4️⃣', 'callback_data': kbCaptchaFour},
      <String, Object?>{'text': '5️⃣', 'callback_data': kbCaptchaFive},
      <String, Object?>{'text': '6️⃣', 'callback_data': kbCaptchaSix},
    ],
    <Map<String, Object?>>[
      <String, Object?>{'text': '7️⃣', 'callback_data': kbCaptchaSeven},
      <String, Object?>{'text': '8️⃣', 'callback_data': kbCaptchaEight},
      <String, Object?>{'text': '9️⃣', 'callback_data': kbCaptchaNine},
    ],
    <Map<String, Object?>>[
      <String, Object?>{'text': '🔄', 'callback_data': kbCaptchaRefresh},
      <String, Object?>{'text': '0️⃣', 'callback_data': kbCaptchaZero},
      <String, Object?>{'text': '↩️', 'callback_data': kbCaptchaBackspace},
    ],
  ],
});

/// If a users sends the same message more than this number of times as initial
/// messages, they will be considered as spamming.
const int spamDuplicateLimit = 4;

/// The hour (server time) at which the daily report should be sent.
const int reportAtHour = 17;
