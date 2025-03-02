// ignore_for_file: prefer_foreach
import 'dart:collection';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart' as ffi;
import 'package:l/l.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:vixen/src/constant/constants.dart';
import 'package:vixen/src/queries.dart';

export 'package:drift/drift.dart' hide DatabaseOpener;
export 'package:drift/isolate.dart';

part 'database.g.dart';

/// Key-value storage interface for SQLite database
abstract interface class IKeyValueStorage {
  /// Refresh key-value storage from database
  Future<void> refresh();

  /// Get value by key
  T? getKey<T extends Object>(String key);

  /// Set value by key
  void setKey(String key, Object? value);

  /// Remove value by key
  void removeKey(String key);

  /// Get all values
  Map<String, Object?> getAll([Set<String>? keys]);

  /// Set all values
  void setAll(Map<String, Object?> data);

  /// Remove all values
  void removeAll([Set<String>? keys]);
}

@DriftDatabase(
  include: <String>{
    'ddl/kv.drift',
    'ddl/characteristic.drift',
    'ddl/log.drift',
    'ddl/settings.drift',
    'ddl/user.drift', // Verified, Banned
    'ddl/captcha.drift', // Captcha messages
    'ddl/report_message.drift', // Messages of sent reports
    'ddl/chat.drift', // Chat related information
  },
  tables: <Type>[],
  daos: <Type>[],
  queries: $queries,
)
class Database extends _$Database
    with _DatabaseUserMixin, _DatabaseKeyValueMixin
    implements GeneratedDatabase, DatabaseConnectionUser, QueryExecutorUser, IKeyValueStorage {
  /// Creates a database that will store its result in the [path], creating it
  /// if it doesn't exist.
  ///
  /// [path] - file path to database for native platforms and database name for web platform.
  ///
  /// If [logStatements] is true (defaults to `false`), generated sql statements
  /// will be printed before executing. This can be useful for debugging.
  /// The optional [setup] function can be used to perform a setup just after
  /// the database is opened, before moor is fully ready. This can be used to
  /// add custom user-defined sql functions or to provide encryption keys in
  /// SQLCipher implementations.
  Database.lazy({String? path, bool logStatements = false, bool dropDatabase = false})
    : super(
        LazyDatabase(() => _createQueryExecutor(path: path, logStatements: logStatements, dropDatabase: dropDatabase)),
      );

  /// Creates a database from an existing [executor].
  Database.connect(super.connection);

  /// Creates an in-memory database won't persist its changes on disk.
  ///
  /// If [logStatements] is true (defaults to `false`), generated sql statements
  /// will be printed before executing. This can be useful for debugging.
  /// The optional [setup] function can be used to perform a setup just after
  /// the database is opened, before moor is fully ready. This can be used to
  /// add custom user-defined sql functions or to provide encryption keys in
  /// SQLCipher implementations.
  Database.memory({bool logStatements = false})
    : super(LazyDatabase(() => _createQueryExecutor(logStatements: logStatements, memoryDatabase: true)));

  static Future<QueryExecutor> _createQueryExecutor({
    String? path,
    bool dropDatabase = false,
    bool logStatements = false,
    bool memoryDatabase = false,
  }) async {
    if (kDebugMode) {
      // Close existing instances for hot restart
      try {
        ffi.NativeDatabase.closeExistingInstances();
      } on Object catch (e, st) {
        l.w("Can't close existing database instances, error: $e", st);
      }
    }

    path = path?.trim().toLowerCase();
    if (memoryDatabase || path == ':memory:') {
      return ffi.NativeDatabase.memory(
        logStatements: logStatements,
        /* setup: (db) {}, */
      );
    }

    io.File file;
    if (path == null) {
      var dbFolder = io.Directory.current;
      dbFolder = io.Directory(p.join(dbFolder.path, 'data'));
      if (!dbFolder.existsSync()) await dbFolder.create(recursive: true);
      file = io.File(p.join(dbFolder.path, 'db.sqlite3'));
    } else {
      file = io.File(path);
    }
    try {
      if (dropDatabase && file.existsSync()) {
        await file.delete();
      }
    } on Object catch (e, st) {
      l.e("Can't delete database file: $file, error: $e", st);
      rethrow;
    }
    /* return ffi.NativeDatabase(
      file,
      logStatements: logStatements,
      /* setup: (db) {}, */
    ); */
    return ffi.NativeDatabase.createInBackground(
      file,
      logStatements: logStatements,
      /* setup: (db) {}, */
    );
  }

  @override
  int get schemaVersion => 8;

  @override
  MigrationStrategy get migration => DatabaseMigrationStrategy(database: this);
}

/// Handles database migrations by delegating work to [OnCreate] and [OnUpgrade]
/// methods.
@immutable
class DatabaseMigrationStrategy implements MigrationStrategy {
  /// Construct a migration strategy from the provided [onCreate] and
  /// [onUpgrade] methods.
  const DatabaseMigrationStrategy({required Database database}) : _db = database;

  /// Database to use for migrations.
  final Database _db;

  /// Executes when the database is opened for the first time.
  @override
  OnCreate get onCreate => (m) async {
    await m.createAll();
  };

  /// Executes when the database has been opened previously, but the last access
  /// happened at a different [GeneratedDatabase.schemaVersion].
  /// Schema version upgrades and downgrades will both be run here.
  @override
  OnUpgrade get onUpgrade => (m, from, to) async => _update(_db, m, from, to);

  /// Executes after the database is ready to be used (ie. it has been opened
  /// and all migrations ran), but before any other queries will be sent. This
  /// makes it a suitable place to populate data after the database has been
  /// created or set sqlite `PRAGMAS` that you need.
  @override
  OnBeforeOpen get beforeOpen => (details) async {
    // await details.executor.runCustom('PRAGMA foreign_keys = ON;');
  };

  /// https://moor.simonbinder.eu/docs/advanced-features/migrations/
  static Future<void> _update(Database db, Migrator m, int from, int to) async {
    if (from >= to) return; // Don't run if the schema is already up to date
    switch (from) {
      case 1:
        // Migration from 1 to 2
        await m.deleteTable('log_tbl');
        await m.deleteTable('characteristic_tbl');
        await m.deleteTable('settings_tbl');
        await m.createAll();
      case 2:
        // Migration from 2 to 3
        await m.createTable(db.deletedMessageHash);
      case 3:
        // Migration from 3 to 4
        await m.createIndex(db.deletedMessageHashCountIdx);
      case 4:
        // Migration from 4 to 5
        await m.createTable(db.reportMessage);
        await m.createIndex(db.reportMessageChatIdIdx);
      case 5:
        // Migration from 5 to 6
        await m.deleteTable('captcha_message');
        await m.createTable(db.captchaMessage);
        await m.createIndex(db.captchaMessageChatIdIdx);
        await m.createIndex(db.captchaMessageUserIdIdx);
      case 6:
        // Migration from 6 to 7
        await m.createTable(db.chatInfo);
      case 7:
        // Migration from 7 to 8
        await m.addColumn(db.allowedMessage, db.allowedMessage.length);
        await m.addColumn(db.allowedMessage, db.allowedMessage.message);
      default:
        if (kDebugMode) throw UnimplementedError('Unsupported migration from $from to $to');
    }

    // Recursively upgrade to the latest version
    await _update(db, m, from + 1, to);
  }
}

mixin _DatabaseUserMixin on _$Database {
  late final Future<Set<int>> _verifiedIds = (selectOnly(verified)
    ..addColumns([verified.userId])).map((e) => e.read(verified.userId)).get().then(HashSet<int>.from);

  /// Check if a user is verified.
  Future<bool> isVerified(int userId) async {
    final cache = await _verifiedIds;
    if (cache.contains(userId)) return true;
    final verified = await (select(this.verified)
          ..where((tbl) => tbl.userId.equals(userId))
          ..limit(1))
        .getSingleOrNull()
        .then((value) => value != null);
    return verified;
  }

  /// Check if a user is banned.
  Future<bool> isBanned(int userId) async {
    final banned =
        await (select(this.banned)
              ..where((tbl) => tbl.userId.equals(userId))
              ..limit(1))
            .getSingleOrNull();
    return banned != null;
  }

  /// Verify a user.
  Future<void> verifyUser({
    required int chatId,
    required int userId,
    required String name,
    int? verifiedAt,
    String? reason,
  }) async {
    if ((await _verifiedIds).add(userId)) {
      // Insert the user into the database if not already verified
      await batch((batch) {
        batch
          ..deleteWhere(banned, (tbl) => tbl.userId.equals(userId))
          ..insert(
            verified,
            VerifiedCompanion.insert(
              userId: Value<int>(userId),
              chatId: chatId,
              verifiedAt: verifiedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
              name: name,
              reason: Value<String?>.absentIfNull(reason),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      });
      l.i('Verified user $userId');
    }
  }

  /// Verify a users
  Future<void> verifyUsers(List<({int chatId, int userId, String name, int? verifiedAt, String? reason})> users) async {
    if (users.isEmpty) return;
    late final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final toInsert = users
        .map(
          (e) => VerifiedCompanion.insert(
            userId: Value<int>(e.userId),
            chatId: e.chatId,
            verifiedAt: now,
            name: e.name,
            reason: Value<String?>.absentIfNull(e.reason),
          ),
        )
        .toList(growable: false);
    final verifiedIds = await _verifiedIds;
    final length = toInsert.length;
    for (var i = 0; i < length; i += 500) {
      final sublist = toInsert.sublist(i, math.min(i + 500, length));
      try {
        await batch((batch) {
          batch
            ..deleteWhere(banned, (tbl) => tbl.userId.isIn(sublist.map((e) => e.userId.value)))
            ..insertAll(verified, sublist, mode: InsertMode.insertOrIgnore);
        });
        verifiedIds.addAll(sublist.map((e) => e.userId.value));
        l.i('Verified ${sublist.length} users');
      } on Object catch (e, st) {
        l.w('Failed to verify users: $e', st);
        continue;
      }
    }
  }

  /// Unverify users.
  Future<int> unverifyUsers(Iterable<int> ids) async {
    final toDelete = ids.toSet();
    if (toDelete.isEmpty) return 0;
    final cache = await _verifiedIds;
    cache.removeAll(toDelete);
    return await (delete(verified)..where((tbl) => tbl.userId.isIn(toDelete))).go();
  }

  /// Ban a user.
  Future<void> banUser({
    required int chatId,
    required int userId,
    required String name,
    int? bannedAt,
    int? expiresAt,
    String? reason,
  }) async {
    (await _verifiedIds).remove(userId);
    await batch((batch) {
      batch
        ..deleteWhere(verified, (tbl) => tbl.userId.equals(userId))
        ..insert(
          banned,
          BannedCompanion.insert(
            userId: Value<int>(userId),
            chatId: chatId,
            bannedAt: bannedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
            expiresAt: Value<int?>.absentIfNull(expiresAt),
            name: name,
            reason: Value<String?>.absentIfNull(reason),
          ),
          mode: InsertMode.insertOrReplace,
        );
    });
    l.i('Banned user $userId');
  }
}

mixin _DatabaseKeyValueMixin on _$Database implements IKeyValueStorage {
  bool _$isInitialized = false;
  final Map<String, Object> _$store = <String, Object>{};

  static KvTblCompanion? _kvCompanionFromKeyValue(String key, Object? value) => switch (value) {
    String vstring => KvTblCompanion.insert(k: key, vstring: Value(vstring)),
    int vint => KvTblCompanion.insert(k: key, vint: Value(vint)),
    double vdouble => KvTblCompanion.insert(k: key, vdouble: Value(vdouble)),
    bool vbool => KvTblCompanion.insert(k: key, vbool: Value(vbool ? 1 : 0)),
    _ => null,
  };

  @override
  Future<void> refresh() => select(kvTbl).get().then<void>((values) {
    _$isInitialized = true;
    _$store
      ..clear()
      ..addAll(<String, Object>{for (final kv in values) kv.k: kv.vstring ?? kv.vint ?? kv.vdouble ?? kv.vbool == 1});
  });

  @override
  T? getKey<T extends Object>(String key) {
    assert(_$isInitialized, 'Database is not initialized');
    final v = _$store[key];
    if (v is T) {
      return v;
    } else if (v == null) {
      return null;
    } else {
      assert(false, 'Value is not of type $T');
      return null;
    }
  }

  @override
  void setKey(String key, Object? value) {
    if (value == null) return removeKey(key);
    assert(_$isInitialized, 'Database is not initialized');
    _$store[key] = value;
    final entity = _kvCompanionFromKeyValue(key, value);
    if (entity == null) {
      assert(false, 'Value type is not supported');
      return;
    }
    into(kvTbl).insertOnConflictUpdate(entity).ignore();
  }

  @override
  void removeKey(String key) {
    assert(_$isInitialized, 'Database is not initialized');
    _$store.remove(key);
    (delete(kvTbl)..where((tbl) => tbl.k.equals(key))).go().ignore();
  }

  @override
  Map<String, Object> getAll([Set<String>? keys]) {
    assert(_$isInitialized, 'Database is not initialized');
    return keys == null
        ? Map<String, Object>.of(_$store)
        : <String, Object>{
          for (final e in _$store.entries)
            if (keys.contains(e.key)) e.key: e.value,
        };
  }

  @override
  void setAll(Map<String, Object?> data) {
    assert(_$isInitialized, 'Database is not initialized');
    if (data.isEmpty) return;
    final entries = <(String, Object?, KvTblCompanion?)>[
      for (final e in data.entries) (e.key, e.value, _kvCompanionFromKeyValue(e.key, e.value)),
    ];
    final toDelete = entries.where((e) => e.$3 == null).map<String>((e) => e.$1).toSet();
    final toInsert =
        entries.expand<(String, Object, KvTblCompanion)>((e) sync* {
          final value = e.$2;
          final companion = e.$3;
          if (companion == null || value == null) return;
          yield (e.$1, value, companion);
        }).toList();
    for (final key in toDelete) _$store.remove(key);
    _$store.addAll(<String, Object>{for (final e in toInsert) e.$1: e.$2});
    batch(
      (b) =>
          b
            ..deleteWhere(kvTbl, (tbl) => tbl.k.isIn(toDelete))
            ..insertAllOnConflictUpdate(kvTbl, toInsert.map((e) => e.$3).toList(growable: false)),
    ).ignore();
  }

  @override
  void removeAll([Set<String>? keys]) {
    assert(_$isInitialized, 'Database is not initialized');
    if (keys == null) {
      _$store.clear();
      delete(kvTbl).go().ignore();
    } else if (keys.isNotEmpty) {
      for (final key in keys) _$store.remove(key);
      (delete(kvTbl)..where((tbl) => tbl.k.isIn(keys))).go().ignore();
    }
  }
}
