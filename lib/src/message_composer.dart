// ignore_for_file: avoid_classes_with_only_static_members

import 'package:intl/intl.dart';
import 'package:vixen/src/bot.dart';
import 'package:vixen/src/constant/constants.dart';
import 'package:vixen/src/database.dart';
import 'package:vixen/src/reports.dart';
import 'package:vixen/src/summarizer.dart';

/// Telegram message composer.
abstract final class TelegramMessageComposer {
  static const nbsp = '\u00A0';

  /// Compose a report message.
  static String report({
    required int chatId,
    required DateTime date,
    required int sentMessagesCount,
    required int deletedMessagesCount,
    required int captchaCount,
    required ReportMostActiveUsers mostActiveUsers,
    required ReportVerifiedUsers verifiedUsers,
    required ReportBannedUsers bannedUsers,
    ChatInfoData? chatInfo,
  }) {
    final buffer = StringBuffer();

    final dateFormat = DateFormat('d MMMM yyyy', 'en_US');
    buffer
      ..write('*📅 Report for chat'.replaceAll(' ', nbsp))
      ..write(' ')
      ..write(Bot.escapeMarkdownV2(chatInfo?.title ?? '$chatId').replaceAll(' ', nbsp))
      ..writeln('*')
      ..write(nbsp * 6)
      ..write('_')
      /* ..write(Bot.escapeMarkdownV2(dateFormat.format(from)))
              ..write(r' \- ')
               */
      ..write(Bot.escapeMarkdownV2(dateFormat.format(date).replaceAll(' ', nbsp)))
      ..writeln('_')
      ..writeln();

    if (sentMessagesCount > 0) {
      buffer
        ..writeln('*📊 Messages count:* $sentMessagesCount')
        ..writeln();
    }

    if (deletedMessagesCount > 0) {
      buffer
        ..writeln('*🗑️ Deleted messages:* $deletedMessagesCount')
        ..writeln();
    }

    if (captchaCount > 0) {
      buffer
        ..writeln('*🔒 Captcha messages:* $captchaCount')
        ..writeln();
    }

    if (mostActiveUsers.isNotEmpty) {
      if (mostActiveUsers.length == 1) {
        final u = mostActiveUsers.single;
        buffer
          ..write('*🥇 Most active user:* ')
          ..writeln('${Bot.userMention(u.uid, u.username)} \\(${u.count} msg\\)');
      } else {
        buffer.writeln('*🥇 Most active users:*');
        mostActiveUsers.sort((a, b) => b.count.compareTo(a.count));
        for (final e in mostActiveUsers.take(5))
          buffer.writeln('• ${Bot.userMention(e.uid, e.username)} \\(${e.count} msg\\)');
      }
      buffer.writeln();
    }

    if (verifiedUsers.isNotEmpty) {
      if (verifiedUsers.length == 1) {
        final u = verifiedUsers.single;
        buffer
          ..write('*✅ Verified user:* ')
          ..writeln(Bot.userMention(u.uid, u.username));
      } else {
        buffer.writeln('*✅ Verified ${verifiedUsers.length} users:*');
        for (final e in verifiedUsers.take(reportVerifiedLimit))
          buffer.writeln('• ${Bot.userMention(e.uid, e.username)}');
        if (verifiedUsers.length > reportVerifiedLimit)
          buffer.writeln('\\.\\.\\. _and ${verifiedUsers.length - reportVerifiedLimit} more_');
      }
      buffer.writeln();
    }

    if (bannedUsers.isNotEmpty) {
      if (bannedUsers.length == 1) {
        final u = bannedUsers.single;
        buffer
          ..write('*🚫 Banned user:* ')
          ..writeln(Bot.escapeMarkdownV2(u.username));
      } else {
        buffer.writeln('*🚫 Banned ${bannedUsers.length} users:*');
        /* \\(${Bot.escapeMarkdownV2(e.reason ?? 'Unknown')}\\) */
        for (final e in bannedUsers.take(reportBannedLimit)) buffer.writeln('• ${Bot.escapeMarkdownV2(e.username)}');
        if (bannedUsers.length > reportBannedLimit)
          buffer.writeln('\\.\\.\\. _and ${bannedUsers.length - reportBannedLimit} more_');
      }
      buffer.writeln();
    }

    // Add the hashtag
    buffer
      ..writeln()
      ..writeln(Bot.escapeMarkdownV2('#report #chart'));

    return buffer.toString();
  }

  /// Compose a summary message.
  static String summary({
    required int chatId,
    required List<SummaryTopic> topics,
    required DateTime date,
    ChatInfoData? chatInfo,
  }) {
    final buffer = StringBuffer();

    final dateFormat = DateFormat('d MMMM yyyy', 'en_US');

    buffer
      ..write('*📝 Summary for chat'.replaceAll(' ', nbsp))
      ..write(' ')
      ..write(Bot.escapeMarkdownV2(chatInfo?.title ?? '$chatId').replaceAll(' ', nbsp))
      ..writeln('*')
      ..write(nbsp * 6)
      ..write('_')
      ..write(Bot.escapeMarkdownV2(dateFormat.format(date).replaceAll(' ', nbsp)))
      ..writeln('_')
      ..writeln();

    var first = true;
    for (final topic in topics) {
      final topicBuffer =
          StringBuffer()
            ..write('*')
            ..write('📌 [')
            ..write(Bot.escapeMarkdownV2(topic.title))
            ..write('](https://t.me/c/${Bot.shortId(chatId)}/${topic.message})')
            ..writeln('*');

      // Summary
      if (topic.summary.isNotEmpty) {
        topicBuffer
          ..writeln(Bot.escapeMarkdownV2(topic.summary))
          ..writeln();
      }

      // Points
      if (topic.points.isNotEmpty) {
        topicBuffer.writeln('*✨ Points:*');
        for (final point in topic.points) {
          final lines = point
              .trim()
              .split('\n')
              .map<String>((e) => e.trim())
              .map<String>(Bot.escapeMarkdownV2)
              .toList(growable: false);
          for (final line in lines)
            topicBuffer
              ..write('• ')
              ..writeln(line);
        }
        topicBuffer.writeln();
      }

      // Conclusions
      if (topic.conclusions.isNotEmpty) {
        topicBuffer.writeln('*🔍 Conclusions:*');
        for (final conclusion in topic.conclusions) {
          final lines = conclusion
              .trim()
              .split('\n')
              .map<String>((e) => e.trim())
              .map<String>(Bot.escapeMarkdownV2)
              .toList(growable: false);
          for (final line in lines)
            topicBuffer
              ..write('• ')
              ..writeln(line);
        }
        topicBuffer.writeln();
      }

      if (topic.quotes.isNotEmpty) {
        for (final quote in topic.quotes) {
          final lines = quote.quote
              .trim()
              .split('\n')
              .map<String>((e) => e.trim())
              .map<String>(Bot.escapeMarkdownV2)
              .toList(growable: false);
          if (lines.length > 1) {
            // Multiline expandable quote
            topicBuffer
              ..write('**>')
              ..write('*')
              //..write(Bot.userMention(quote.uid, quote.username))
              ..write(Bot.escapeMarkdownV2(quote.username))
              ..write(' ')
              ..write('[')
              ..write(nbsp)
              ..write('💬')
              ..write(nbsp)
              ..write('](https://t.me/c/${Bot.shortId(chatId)}/${quote.message})')
              ..write('*')
              ..write(' ')
              ..writeln(lines.first);
            for (var i = 1; i < lines.length - 1; i++) {
              topicBuffer
                ..write('>')
                ..writeln(lines[i]);
            }
            topicBuffer
              ..write('>')
              ..write(lines.last)
              ..writeln('||');
          } else {
            // Single line quote
            topicBuffer
              ..write('**>')
              ..write('*')
              //..write(Bot.userMention(quote.uid, quote.username))
              ..write(Bot.escapeMarkdownV2(quote.username))
              ..write(' ')
              ..write('[')
              ..write(nbsp)
              ..write('💬')
              ..write(nbsp)
              ..write('](https://t.me/c/${Bot.shortId(chatId)}/${quote.message})')
              ..write('*')
              ..write(' ')
              ..writeln(lines.first);
          }
        }
        topicBuffer.writeln();
      }

      if (buffer.length + topicBuffer.length <= 4000) {
        // Add divider if not the first topic
        if (!first)
          buffer
            ..writeln('')
            ..writeln('▬' * 10)
            ..writeln('')
            ..writeln('');
        buffer.write(topicBuffer.toString()); // Add the topic
        first = false;
      } else {
        continue; // Skip the topic if the buffer is too large
      }
    }

    if (first) return ''; // Skip the chat if the buffer is empty

    // Add the hashtag
    buffer
      ..writeln()
      ..writeln(Bot.escapeMarkdownV2('#report #summary'));

    return buffer.toString();
  }
}
