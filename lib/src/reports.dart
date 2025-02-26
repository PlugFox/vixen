import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:vixen/src/constant/constants.dart' as constants;
import 'package:vixen/src/database.dart';

typedef ReportMostActiveUsers = List<({int uid, String username, DateTime seen, int count})>;

typedef ReportSpamMessages = List<({String message, int count, DateTime date})>;

typedef ReportVerifiedUsers = List<({int cid, int uid, String username, DateTime verifiedAt})>;

typedef ReportBannedUsers =
    List<({int cid, int uid, String username, String? reason, DateTime bannedAt, DateTime? expiresAt})>;

typedef ReportChartData =
    ({List<int> parts, List<int> sent, List<int> captcha, List<int> verified, List<int> banned, List<int> deleted});

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
  Future<ReportChartData> chartData({
    required DateTime from,
    required DateTime to,
    int? chatId,
    bool random = false,
  }) async {
    var fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    if (fromUnix > toUnix) (fromUnix, toUnix) = (toUnix, fromUnix);

    final parts = Uint64List(10),
        sent = Uint32List(10),
        captcha = Uint32List(10),
        verified = Uint32List(10),
        banned = Uint32List(10),
        deleted = Uint32List(10);

    final offset = ((toUnix - fromUnix) / 10).ceil();
    for (var i = 0; i < 9; i++) parts[i] = fromUnix + offset * (i + 1);
    parts[9] = toUnix;

    if (random) {
      final random = math.Random();

      for (var i = 0; i < 10; i++) {
        sent[i] = random.nextInt(100);
        captcha[i] = random.nextInt(100);
        verified[i] = random.nextInt(100);
        banned[i] = random.nextInt(100);
        deleted[i] = random.nextInt(100);
      }

      return (parts: parts, sent: sent, captcha: captcha, verified: verified, banned: banned, deleted: deleted);
    }

    final result =
        await _db
            .customSelect(
              _chartDataQuery,
              variables: [Variable.withInt(fromUnix), Variable.withInt(toUnix), Variable.withInt(chatId ?? 0)],
            )
            .get();

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

  /// Draw a .png image with the chart data for the given time frame.
  Future<Uint8List> chartPng({
    ReportChartData? data,
    DateTime? from,
    DateTime? to,
    int? chatId,
    int width = 480,
    int height = 240,
    int paddingLeft = 48,
    int paddingRight = 16,
    int paddingTop = 16,
    int paddingBottom = 32,
  }) async {
    assert(data == null || (from == null && to == null), 'Either data or from and to must be null');
    data ??= await chartData(
      from: from ?? DateTime.now().subtract(const Duration(days: 1)),
      to: to ?? DateTime.now(),
      chatId: chatId,
    );

    // Создаем изображение с увеличенным разрешением для повышения качества
    const scale = 3;
    final width4 = width * scale, height4 = height * scale;
    var image = img.Image(width: width4, height: height4);
    // Заливаем фон цветом (цвет фона: #37474F)
    img.fill(image, color: img.ColorUint8.rgb(0x37, 0x47, 0x4F));

    // Определяем отступы для области графика
    final marginLeft = paddingLeft * scale,
        marginRight = paddingRight * scale,
        marginTop = paddingTop * scale,
        marginBottom = paddingBottom * scale;
    final plotWidth = width4 - marginLeft - marginRight;
    final plotHeight = height4 - marginTop - marginBottom;

    // Рисуем оси графика
    {
      final axisColor = img.ColorUint8.rgb(255, 255, 255);
      // Ось X
      img.drawLine(
        image,
        x1: marginLeft,
        y1: height4 - marginBottom,
        x2: width4 - marginRight,
        y2: height4 - marginBottom,
        color: axisColor,
        antialias: false,
        thickness: 6,
      );
      // Ось Y
      img.drawLine(
        image,
        x1: marginLeft,
        y1: marginTop,
        x2: marginLeft,
        y2: height4 - marginBottom,
        color: axisColor,
        antialias: false,
        thickness: 6,
      );
    }

    // Определяем максимальное значение для масштабирования оси Y
    final maxValue = <List<int>>[
      data.sent,
      data.captcha,
      data.verified,
      data.banned,
      data.deleted,
    ].fold(1, (r, l) => math.max(r, l.reduce(math.max)));

    // Определяем цвета для каждого набора данных
    // https://materialui.co/colors
    final colorSent = img.ColorUint8.rgb(0x02, 0x77, 0xBD); // light blue (0277BD)
    final colorCaptcha = img.ColorUint8.rgb(0x45, 0x27, 0xA0); // deep purple (4527A0)
    final colorVerified = img.ColorUint8.rgb(0x2E, 0x7D, 0x32); // green (2E7D32)
    final colorBanned = img.ColorUint8.rgb(0xC6, 0x28, 0x28); // red (C62828)
    final colorDeleted = img.ColorUint8.rgb(0xD8, 0x43, 0x15); // deep orange (D84315)

    // Собираем серии для графика
    final chartSeries = <({String label, List<int> data, img.Color color})>[
      (label: 'Sent', data: data.sent, color: colorSent),
      (label: 'Captcha', data: data.captcha, color: colorCaptcha),
      (label: 'Verified', data: data.verified, color: colorVerified),
      (label: 'Banned', data: data.banned, color: colorBanned),
      (label: 'Deleted', data: data.deleted, color: colorDeleted),
    ];

    // Draw the chart values
    for (var i = 0; i < 7; i++) {
      img.drawString(
        image,
        (maxValue - maxValue * i / 7).toStringAsFixed(0),
        font: img.arial48,
        rightJustify: true,
        x: marginLeft - 8 * scale,
        y: marginTop + i * plotHeight ~/ 7,
        color: const img.ConstColorRgb8(0xCF, 0xD8, 0xDC), // CFD8DC
      );
    }

    // Draw the chart legend
    for (var i = 0; i < chartSeries.length; i++) {
      final series = chartSeries[i];
      img.drawString(
        image,
        series.label,
        font: img.arial48,
        x: marginLeft + i * plotWidth ~/ chartSeries.length,
        y: height4 - marginBottom + 10 * scale,
        color: series.color,
      );
    }

    // Для каждой серии данных строим линию графика
    for (final series in chartSeries) {
      final (:String label, :List<int> data, :img.Color color) = series;
      final length = data.length;
      var dx1 = marginLeft, dy1 = height4 - marginBottom - (data[0] * plotHeight ~/ maxValue);
      img.fillCircle(image, x: dx1, y: dy1, radius: 4, color: color);
      for (var i = 1; i < length; i++) {
        var dx2 = marginLeft + i * plotWidth ~/ (length - 1);
        var dy2 = height4 - marginBottom - (data[i] * plotHeight ~/ maxValue);
        img.drawLine(image, x1: dx1, y1: dy1, x2: dx2, y2: dy2, color: color, thickness: 4);
        img.fillCircle(image, x: dx2, y: dy2, radius: 8, color: color);
        dx1 = dx2;
        dy1 = dy2;
      }
    }

    // Resize the image to the desired size
    final resized = img.copyResize(image, width: width, height: height, interpolation: img.Interpolation.average);

    // Кодируем изображение в формат PNG
    final pngBytes = img.encodePng(resized);
    return Uint8List.fromList(pngBytes);
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
