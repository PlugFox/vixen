import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:vixen/src/constant/constants.dart' as constants;
import 'package:vixen/src/database.dart';

typedef ReportMostActiveUsers = List<({int uid, String username, DateTime seen, int count})>;

typedef ReportSpamMessages = List<({String message, int count, DateTime date})>;

typedef ReportVerifiedUsers = List<({int cid, int uid, String username, DateTime verifiedAt})>;

typedef ReportBannedUsers =
    List<({int cid, int uid, String username, String? reason, DateTime bannedAt, DateTime? expiresAt})>;

@immutable
final class Reports {
  const Reports({required Database db}) : _db = db;

  final Database _db;

  /// Returns the most active users in the given time frame.
  Future<Map<int, ReportMostActiveUsers>> mostActiveUsers(DateTime from, DateTime to, [int? chatId]) async {
    final fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    final result =
        await _db
            .customSelect(
              _mostActiveUsersQuery,
              variables: [Variable.withInt(fromUnix), Variable.withInt(toUnix), Variable.withInt(chatId ?? 0)],
            )
            .get();
    return result.fold<Map<int, ReportMostActiveUsers>>(
      <int, ReportMostActiveUsers>{},
      (r, q) =>
          r
            ..putIfAbsent(q.read<int>('cid'), () => []).add((
              uid: q.read<int>('uid'),
              username: q.read<String>('username'),
              seen: DateTime.fromMillisecondsSinceEpoch(q.read<int>('seen') * 1000).toUtc(),
              count: q.read<int>('count'),
            )),
    );
  }

  /// Returns spam messages in the given time frame.
  Future<ReportSpamMessages> spamMessages(DateTime from, DateTime to) async {
    final fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    final result =
        await _db
            .customSelect(
              _spamMessagesQuery,
              variables: [
                Variable.withInt(fromUnix),
                Variable.withInt(toUnix),
                Variable.withInt(constants.spamDuplicateLimit),
              ],
            )
            .get();
    return result
        .map(
          (e) => (
            message: e.read<String>('message'),
            count: e.read<int>('count'),
            date: DateTime.fromMillisecondsSinceEpoch(e.read<int>('date') * 1000).toUtc(),
          ),
        )
        .toList(growable: false);
  }

  /// Returns verified users in the given time frame.
  Future<ReportVerifiedUsers> verifiedUsers(DateTime from, DateTime to, [int? chatId]) async {
    final fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    var query = _db.select(_db.verified)..where((tbl) => tbl.verifiedAt.isBetweenValues(fromUnix, toUnix));
    if (chatId != null) query = query..where((tbl) => tbl.chatId.equals(chatId));
    final result = await query.get();
    return result
        .map(
          (e) => (
            cid: e.chatId,
            uid: e.userId,
            username: e.name,
            verifiedAt: DateTime.fromMillisecondsSinceEpoch(e.verifiedAt * 1000).toUtc(),
          ),
        )
        .toList(growable: false);
  }

  /// Returns banned users in the given time frame.
  Future<ReportBannedUsers> bannedUsers(DateTime from, DateTime to, [int? chatId]) async {
    final fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    var query = _db.select(_db.banned)..where((tbl) => tbl.bannedAt.isBetweenValues(fromUnix, toUnix));
    if (chatId != null) query = query..where((tbl) => tbl.chatId.equals(chatId));
    final result = await query.get();
    return result
        .map(
          (e) => (
            cid: e.chatId,
            uid: e.userId,
            username: e.name,
            reason: e.reason,
            bannedAt: DateTime.fromMillisecondsSinceEpoch(e.bannedAt * 1000).toUtc(),
            expiresAt: switch (e.expiresAt) {
              int n => DateTime.fromMillisecondsSinceEpoch(n * 1000).toUtc(),
              _ => null,
            },
          ),
        )
        .toList(growable: false);
  }

  /// Returns the count of deleted messages in the given time frame.
  Future<List<({int cid, int count})>> deletedCount(DateTime from, DateTime to, [int? chatId]) async {
    final fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    final result =
        await _db
            .customSelect(
              'SELECT chat_id AS cid, COUNT(1) AS count '
              'FROM deleted_message WHERE date BETWEEN :from AND :to '
              'AND (:cid == 0 OR chat_id = :cid) '
              'GROUP BY chat_id',
              variables: [Variable.withInt(fromUnix), Variable.withInt(toUnix), Variable.withInt(chatId ?? 0)],
            )
            .get();
    return result.map((e) => (cid: e.read<int>('cid'), count: e.read<int>('count'))).toList(growable: false);
  }

  /// Data for the chart.
  /// Returns the count of sent, captcha, verified, banned, and deleted messages
  /// in the given time frame split into 10 parts.
  Future<
    ({List<int> parts, List<int> sent, List<int> captcha, List<int> verified, List<int> banned, List<int> deleted})
  >
  chartData(DateTime from, DateTime to, [int? chatId]) async {
    var fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    if (fromUnix > toUnix) (fromUnix, toUnix) = (toUnix, fromUnix);

    final result =
        await _db
            .customSelect(
              _chartDataQuery,
              variables: [Variable.withInt(fromUnix), Variable.withInt(toUnix), Variable.withInt(chatId ?? 0)],
            )
            .get();

    final parts = Uint64List(10),
        sent = Uint32List(10),
        captcha = Uint32List(10),
        verified = Uint32List(10),
        banned = Uint32List(10),
        deleted = Uint32List(10);

    final offset = ((toUnix - fromUnix) / 10).ceil();
    for (var i = 0; i < 9; i++) parts[i] = fromUnix + offset * (i + 1);
    parts[9] = toUnix;

    for (var i = 0; i < result.length; i++) {
      final date = result[i].read<int>('date');
      var index = (date - fromUnix) ~/ offset;
      assert(index >= 0 && index < 10, 'Invalid index: $index');
      index = index.clamp(0, 9);
      final type = result[i].read<String>('type');
      switch (type) {
        case 'sent':
          sent[index]++;
        case 'captcha':
          captcha[index]++;
        case 'verified':
          verified[index]++;
        case 'banned':
          banned[index]++;
        case 'deleted':
          deleted[index]++;
        default:
          assert(false, 'Unknown type: $type');
          continue;
      }
    }
    return (parts: parts, sent: sent, captcha: captcha, verified: verified, banned: banned, deleted: deleted);
  }
}

const String _mostActiveUsersQuery = '''
WITH RankedUsersTmp AS (
  SELECT
    msg.chat_id       AS cid,
    msg.user_id       AS uid,
    MAX(msg.username) AS username,
    MAX(msg.date)     AS seen,
    COUNT(*)          AS count,
    ROW_NUMBER() OVER (PARTITION BY msg.chat_id ORDER BY COUNT(*) DESC) AS rnk
  FROM
    allowed_message AS msg
  WHERE
    msg.date BETWEEN :from AND :to
    AND (:cid == 0 OR msg.chat_id = :cid)
  GROUP BY
    msg.chat_id,
    msg.user_id
  HAVING
    COUNT(1) > 2
)
SELECT
  cid,
  uid,
  username,
  seen,
  count
FROM
  RankedUsersTmp
WHERE
  rnk <= 3
ORDER BY
  cid, count DESC;
''';

const String _spamMessagesQuery = '''
SELECT
  del.message   AS message,
  del.count     AS count,
  del.update_at AS date
FROM
  deleted_message_hash AS del
WHERE
  date BETWEEN :from AND :to
  AND del.count > :threshold
ORDER BY
  del.count DESC;
''';

const String _chartDataQuery = '''
WITH EventsTmp AS (
  SELECT 'sent' AS type, tbl.date AS date
  FROM allowed_message AS tbl
  WHERE tbl.date BETWEEN :from AND :to
  AND (:cid == 0 OR tbl.chat_id = :cid)
  UNION ALL
  SELECT 'verified' AS type, tbl.verified_at AS date
  FROM verified AS tbl
  WHERE tbl.verified_at BETWEEN :from AND :to
  AND (:cid == 0 OR tbl.chat_id = :cid)
  UNION ALL
  SELECT 'banned' AS type, tbl.banned_at AS date
  FROM banned AS tbl
  WHERE tbl.banned_at BETWEEN :from AND :to
  AND (:cid == 0 OR tbl.chat_id = :cid)
  UNION ALL
  SELECT 'deleted' AS type, tbl.date AS date
  FROM deleted_message AS tbl
  WHERE tbl.date BETWEEN :from AND :to
  AND (:cid == 0 OR tbl.chat_id = :cid)
  UNION ALL
  SELECT 'captcha' AS type, tbl.updated_at AS date
  FROM captcha_message AS tbl
  WHERE tbl.updated_at BETWEEN :from AND :to
  AND (:cid == 0 OR tbl.chat_id = :cid)
)
SELECT type, date FROM EventsTmp ORDER BY date ASC;
''';
