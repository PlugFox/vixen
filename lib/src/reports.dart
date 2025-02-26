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
  /// in the given time frame split into 24 parts.
  Future<ReportChartData> chartData({
    required DateTime from,
    required DateTime to,
    int? chatId,
    bool random = false,
  }) async {
    var fromUnix = from.millisecondsSinceEpoch ~/ 1000, toUnix = to.millisecondsSinceEpoch ~/ 1000;
    if (fromUnix > toUnix) (fromUnix, toUnix) = (toUnix, fromUnix);

    const count = 24;
    final parts = Uint64List(count),
        sent = Uint32List(count),
        captcha = Uint32List(count),
        verified = Uint32List(count),
        banned = Uint32List(count),
        deleted = Uint32List(count);

    final offset = ((toUnix - fromUnix) / count).ceil();
    for (var i = 0; i < count - 1; i++) parts[i] = fromUnix + offset * (i + 1);
    parts[count - 1] = toUnix;

    if (random) {
      final random = math.Random();

      for (var i = 0; i < count; i++) {
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
      assert(index >= 0 && index < count, 'Invalid index: $index');
      index = index.clamp(0, count - 1);
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
    int paddingLeft = 64,
    int paddingRight = 24,
    int paddingTop = 24,
    int paddingBottom = 48,
  }) async {
    assert(data == null || (from == null && to == null), 'Either data or from and to must be null');
    data ??= await chartData(
      from: from ?? DateTime.now().subtract(const Duration(days: 1)),
      to: to ?? DateTime.now(),
      chatId: chatId,
    );

    // Создаем изображение с увеличенным разрешением для повышения качества
    const scale = 2; // 1 // 2 // 4;
    final width4 = width * scale, height4 = height * scale;
    var image = img.Image(
      width: width4,
      height: height4,
      format: img.Format.uint8,
      backgroundColor: const img.ConstColorRgba8(0x37, 0x47, 0x4F, 0x7F),
      numChannels: 4, // RGBA
      withPalette: false,
    );

    // Заливаем фон цветом (цвет фона: #263238)
    img.fill(image, color: const img.ConstColorRgb8(0x26, 0x32, 0x38));

    // Определяем отступы для области графика
    final marginLeft = paddingLeft * scale,
        marginRight = paddingRight * scale,
        marginTop = paddingTop * scale,
        marginBottom = paddingBottom * scale;
    final plotWidth = width4 - marginLeft - marginRight;
    final plotHeight = height4 - marginTop - marginBottom;

    // Рисуем оси графика
    {
      const thickness = 2 * scale;
      const axisColor = img.ConstColorRgb8(0xBD, 0xBD, 0xBD); // BDBDBD
      // Ось X
      img.drawLine(
        image,
        x1: marginLeft,
        y1: height4 - marginBottom,
        x2: width4 - marginRight,
        y2: height4 - marginBottom,
        color: axisColor,
        antialias: false,
        thickness: thickness,
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
        thickness: thickness,
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
    // img.ColorUint8.rgb(0x02, 0x77, 0xBD)
    const colorDeleted = img.ConstColorRgb8(0xFF, 0x3D, 0x00); // deep orange (FF3D00)
    const colorSent = img.ConstColorRgb8(0x29, 0xB6, 0xF6); // light blue (29B6F6)
    const colorCaptcha = img.ConstColorRgb8(0x65, 0x1F, 0xFF); // deep purple (651FFF)
    const colorBanned = img.ConstColorRgb8(0xFF, 0x17, 0x44); // red (FF1744)
    const colorVerified = img.ConstColorRgb8(0xC6, 0xFF, 0x00); // lime (C6FF00)

    // Собираем серии для графика
    final chartSeries = <({String label, List<int> data, img.Color color})>[
      (label: 'Banned', data: data.banned, color: colorBanned),
      (label: 'Verified', data: data.verified, color: colorVerified),
      (label: 'Deleted', data: data.deleted, color: colorDeleted),
      (label: 'Sent', data: data.sent, color: colorSent),
      (label: 'Captcha', data: data.captcha, color: colorCaptcha),
    ].where((e) => e.data.isNotEmpty && e.data.any((e) => e > 0)).toList(growable: false);

    // Draw the chart values
    for (var i = 0; i < 7; i++) {
      img.drawString(
        image,
        (maxValue - maxValue * i / 7).toStringAsFixed(0),
        font: scale == 1 ? img.arial24 : img.arial48,
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
        font: scale == 1 ? img.arial24 : img.arial48,
        x: marginLeft + i * plotWidth ~/ chartSeries.length,
        y: height4 - marginBottom + 12 * scale,
        color: series.color,
      );
    }

    // Polygons for banned
    if (data.banned.any((e) => e > 0)) {
      img.fillPolygon(
        image,
        vertices: [
          img.Point(marginLeft, height4 - marginBottom),
          for (var i = 0; i < data.banned.length; i++)
            img.Point(
              marginLeft + i * plotWidth ~/ (data.banned.length - 1),
              height4 - marginBottom - (data.banned[i] * plotHeight ~/ maxValue),
            ),
          img.Point(marginLeft + plotWidth, height4 - marginBottom),
        ],
        color: const img.ConstColorRgba8(0xFF, 0x17, 0x44, 64),
      );
    }

    // Polygons for verified
    if (data.verified.any((e) => e > 0)) {
      img.fillPolygon(
        image,
        vertices: [
          img.Point(marginLeft, height4 - marginBottom),
          for (var i = 0; i < data.verified.length; i++)
            img.Point(
              marginLeft + i * plotWidth ~/ (data.verified.length - 1),
              height4 - marginBottom - (data.verified[i] * plotHeight ~/ maxValue),
            ),
          img.Point(marginLeft + plotWidth, height4 - marginBottom),
        ],
        color: const img.ConstColorRgba8(0xC6, 0xFF, 0x00, 64),
      );
    }

    // Для каждой серии данных строим линию графика
    for (final series in chartSeries) {
      const radius = 4 * scale, thickness = 2 * scale;
      final (:String label, :List<int> data, :img.Color color) = series;
      final length = data.length;
      var dx1 = marginLeft, dy1 = height4 - marginBottom - (data[0] * plotHeight ~/ maxValue);
      img.fillCircle(image, x: dx1, y: dy1, radius: radius, color: color, antialias: true);
      for (var i = 1; i < length; i++) {
        var dx2 = marginLeft + i * plotWidth ~/ (length - 1);
        var dy2 = height4 - marginBottom - (data[i] * plotHeight ~/ maxValue);
        img.drawLine(image, x1: dx1, y1: dy1, x2: dx2, y2: dy2, color: color, thickness: thickness, antialias: true);
        img.fillCircle(image, x: dx2, y: dy2, radius: radius, color: color, antialias: true);
        dx1 = dx2;
        dy1 = dy2;
      }
    }

    // Resize the image to the desired size
    final resized =
        scale == 1
            ? image
            : img.copyResize(image, width: width, height: height, interpolation: img.Interpolation.nearest);

    // Кодируем изображение в формат PNG
    final pngBytes = img.encodePng(resized, level: 1, filter: img.PngFilter.none);
    //final pngBytes = img.encodeGif(resized, singleFrame: true, dither: img.DitherKernel.none);

    return pngBytes;
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
