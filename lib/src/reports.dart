import 'package:meta/meta.dart';
import 'package:vixen/src/constant/constants.dart' as constants;
import 'package:vixen/src/database.dart';

typedef ReportMostActiveUsers = List<({int uid, String username, DateTime seen, int count})>;

typedef ReportSpamMessages = List<({String message, int count, DateTime date})>;

/*
{
  'cid': e.chatId,
  'uid': e.userId,
  'username': e.name,
  'reason': e.reason,
  'bannedAt': DateTime.fromMillisecondsSinceEpoch(e.bannedAt * 1000).toIso8601String(),
  'expiresAt': switch (e.expiresAt) {
    int n => DateTime.fromMillisecondsSinceEpoch(n * 1000).toIso8601String(),
    _ => null,
  },
}
*/
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
}

const String _mostActiveUsersQuery = '''
WITH RankedUsers AS (
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
    date BETWEEN :from AND :to
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
  RankedUsers
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
