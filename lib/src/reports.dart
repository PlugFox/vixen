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

  /// Draw a .png image with the chart data for the given time frame.
  Future<Uint8List> chartPng({DateTime? from, DateTime? to, int? chatId, int width = 800, int height = 600}) async {
    final data = await chartData(
      from ?? DateTime.now().subtract(const Duration(days: 1)),
      to ?? DateTime.now(),
      chatId,
    );

    // Создаем изображение с увеличенным разрешением для повышения качества
    final width4 = width * 4, height4 = height * 4;
    var image = img.Image(width: width4, height: height4);
    // Заливаем фон цветом (цвет фона: #37474F)
    img.fill(image, color: img.ColorUint8.rgb(0x37, 0x47, 0x4F));

    // Определяем отступы для области графика
    const marginLeft = 80, marginRight = 40, marginTop = 40, marginBottom = 80;
    final plotWidth = width4 - marginLeft - marginRight;
    final plotHeight = height4 - marginTop - marginBottom;

    // Рисуем оси графика
    final axisColor = img.ColorUint8.rgb(255, 255, 255);
    // Ось X
    img.drawLine(
      image,
      x1: marginLeft,
      y1: height4 - marginBottom,
      x2: width4 - marginRight,
      y2: height4 - marginBottom,
      color: axisColor,
    );
    // Ось Y
    img.drawLine(image, x1: marginLeft, y1: marginTop, x2: marginLeft, y2: height4 - marginBottom, color: axisColor);

    // Определяем максимальное значение для масштабирования оси Y
    var maxValue = 0;
    final datasets = [data.sent, data.captcha, data.verified, data.banned, data.deleted];
    for (final dataset in datasets) {
      for (final value in dataset) {
        if (value > maxValue) maxValue = value;
      }
    }
    if (maxValue == 0) maxValue = 1; // избежание деления на ноль

    // Определяем цвета для каждого набора данных
    final colorSent = img.ColorUint8.rgb(0, 255, 0); // зеленый
    final colorCaptcha = img.ColorUint8.rgb(255, 255, 0); // желтый
    final colorVerified = img.ColorUint8.rgb(0, 0, 255); // синий
    final colorBanned = img.ColorUint8.rgb(255, 0, 0); // красный
    final colorDeleted = img.ColorUint8.rgb(128, 128, 128); // серый

    // Собираем серии для графика
    final chartSeries = [
      (data: data.sent, color: colorSent),
      (data: data.captcha, color: colorCaptcha),
      (data: data.verified, color: colorVerified),
      (data: data.banned, color: colorBanned),
      (data: data.deleted, color: colorDeleted),
    ];

    // Вычисляем шаг по оси X (10 точек => 9 отрезков)
    const pointsCount = 10;
    final dx = plotWidth / (pointsCount - 1);

    // Для каждой серии данных строим линию графика
    for (final series in chartSeries) {
      final values = series.data;
      final seriesColor = series.color;
      var points = Uint32List(pointsCount * 2);
      for (var i = 0; i < pointsCount; i += 2) {
        points[i] = marginLeft + (dx * i).round();
        // Масштабирование по оси Y (чем больше значение, тем выше точка)
        points[i + 1] = marginTop + plotHeight - ((values[i] / maxValue) * plotHeight).round();
      }
      // Соединяем точки линиями
      for (var i = 0; i < points.length - 1; i += 4) {
        img.drawLine(
          image,
          x1: points[i + 0],
          y1: points[i + 1],
          x2: points[i + 2],
          y2: points[i + 3],
          color: seriesColor,
          thickness: 4,
        );
      }
      // Отмечаем каждую точку небольшим прямоугольником (маркер)
      for (var i = 0; i < points.length - 1; i += 2) {
        img.fillRect(
          image,
          x1: points[i + 0] - 4,
          y1: points[i + 1] - 4,
          x2: points[i + 0] + 4,
          y2: points[i + 1] + 4,
          color: seriesColor,
        );
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
