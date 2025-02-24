import 'dart:collection';
import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:l/l.dart' as logger;
import 'package:vixen/src/constant/constants.dart';

/// Parse arguments
ArgParser _buildParser() =>
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this usage information')
      /* ..addSeparator('') */
      ..addOption(
        'token',
        abbr: 't',
        aliases: ['bot', 'telegram'],
        mandatory: true,
        help: 'Telegram bot token',
        valueHelp: '123:ABC-DEF',
      )
      ..addOption(
        'chats',
        abbr: 'c',
        aliases: ['groups', 'chat', 'chat_ids'],
        mandatory: false,
        help: 'Comma-separated list of chat IDs',
        valueHelp: '123,-456,-789',
      )
      ..addOption(
        'secret',
        abbr: 's',
        aliases: ['admin', 'api'],
        mandatory: false,
        help: 'Secret admin API key',
        valueHelp: '1234567890',
      )
      /* ..addSeparator('') */
      ..addOption(
        'db',
        abbr: 'd',
        aliases: ['database', 'sqlite', 'sql', 'file', 'path'],
        mandatory: false,
        help: 'Path to the SQLite database file',
        defaultsTo: 'data/vixen.db',
        valueHelp: 'data/vixen.db',
      )
      ..addOption(
        'address',
        abbr: 'a',
        aliases: ['host', 'server', 'ip'],
        mandatory: false,
        help: 'Address to bind the server to',
        defaultsTo: '0.0.0.0',
        valueHelp: '0.0.0.0',
      )
      ..addOption(
        'port',
        abbr: 'p',
        mandatory: false,
        help: 'Port to bind the server to',
        defaultsTo: '8080',
        valueHelp: '8080',
      )
      ..addOption(
        'verbose',
        abbr: 'v',
        aliases: ['logging', 'logger', 'logs', 'log'],
        mandatory: false,
        help: 'Verbose mode for output: all | debug | info | warn | error',
        defaultsTo: 'warn',
        valueHelp: 'info',
      );

/// Arguments for current project
final class Arguments extends UnmodifiableMapBase<String, String> {
  /// Parse arguments for the current project from the command line input
  factory Arguments.parse(List<String> arguments) {
    final parser = _buildParser();
    try {
      final results = parser.parse(arguments);
      const flags = <String>{'help'};
      const options = <String>{'token', 'chats', 'secret', 'verbose', 'db', 'address', 'port'};
      assert(flags.length + options.length == parser.options.length, 'All options must be accounted for.');
      final table = <String, String>{
        // --- From .env file --- //
        if (io.File('.env') case io.File env when env.existsSync())
          for (final line in env.readAsLinesSync().map((e) => e.trim()))
            if (line.length >= 3 && !line.startsWith('#'))
              if (line.split('=') case List<String> parts when parts.length == 2)
                parts[0].trimRight().toLowerCase(): parts[1].trimLeft(),

        // --- From CONFIG_ platform environment --- //
        for (final MapEntry<String, String>(:key, :value) in io.Platform.environment.entries)
          if (key.startsWith('CONFIG_')) key.substring(7).toLowerCase(): value,

        // --- Flags --- //
        for (final flag in flags)
          if (results.wasParsed(flag)) flag: results.flag(flag) ? 'true' : 'false',
      };
      table.addAll({
        // --- Options --- //
        for (final option in options)
          if (results.wasParsed(option))
            option.toLowerCase(): results.option(option)?.toString() ?? ''
          else if (parser.options[option]?.defaultsTo case String byDefault
              when !table.containsKey(option) && byDefault.isNotEmpty)
            option.toLowerCase(): byDefault,
      });

      if (table['help'] == 'true') {
        io.stdout
          ..writeln(_help.trim())
          ..writeln()
          ..writeln(parser.usage);
        io.exit(0);
      }
      for (final option in parser.options.values) {
        if (!option.mandatory) continue;
        if (table[option.name] != null) continue;
        io.stderr.writeln('Option "${option.name}" is required.');
        io.exit(2);
      }
      return Arguments._(
        arguments: table,
        verbose: switch (table['verbose']?.trim().toLowerCase()) {
          'v' || 'all' || 'verbose' => const logger.LogLevel.vvvvvv(),
          'd' || 'debug' => const logger.LogLevel.debug(),
          'i' || 'info' || 'conf' || 'config' => const logger.LogLevel.info(),
          'w' || 'warn' || 'warning' => const logger.LogLevel.warning(),
          'e' || 'err' || 'error' || 'severe' || 'fatal' => const logger.LogLevel.error(),
          _ => const logger.LogLevel.warning(),
        },
        token: table['token'] ?? '',
        chats: HashSet<int>.from(
          table['chats']?.split(',').map((e) => int.tryParse(e.trim())) ?? const Iterable.empty(),
        ),
        secret: table['secret'] ?? (kDebugMode ? Object().hashCode.toRadixString(36) : ''),
        database: table['db'] ?? 'data/vixen.db',
        address: table['address'] ?? io.InternetAddress.anyIPv4,
        port: int.tryParse(table['port'] ?? '8080') ?? 8080,
      );
    } on FormatException {
      io.stderr
        ..writeln('Invalid arguments provided.')
        ..writeln()
        ..writeln(parser.usage);
      io.exit(2);
    } on Object catch (error, stackTrace) {
      io.stderr
        ..writeln('An unknown error occurred.')
        ..writeln()
        ..writeln(error)
        ..writeln()
        ..writeln(stackTrace)
        ..writeln()
        ..writeln(parser.usage);
      io.exit(3);
    }
  }

  Arguments._({
    required this.verbose,
    required this.chats,
    required this.token,
    required this.secret,
    required this.database,
    required this.address,
    required this.port,
    required Map<String, String> arguments,
  }) : _arguments = arguments;

  /// Log level for the current project
  final logger.LogLevel verbose;

  /// Telegram bot token
  final String token;

  /// List of chat IDs
  final Set<int> chats;

  /// Secret admin API key
  final String secret;

  /// Path to the SQLite database file
  final String database;

  /// Address to bind the server to
  final Object address;

  /// Port to bind the server to
  final int port;

  /// Arguments
  final Map<String, String> _arguments;

  @override
  Iterable<String> get keys => _arguments.keys;

  @override
  String? operator [](Object? key) => _arguments[key];
}

const String _help = '''
Telegram Vixen Bot

Telegram Vixen Bot is a bot for automatically banning spammers in Telegram chats.
Written in Dart that helps prevent spam in Telegram groups by generating and
sending CAPTCHA challenges to new users with a virtual keyboard.
It automatically deletes initial messages from unverified users.
''';
