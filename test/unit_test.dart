import 'dart:async';

import 'package:test/test.dart';
import 'package:vixen/vixen.dart';

void main() {
  group('unit', () {
    test('arguments', () {
      expect(() => Arguments.parse(['-t 123']), returnsNormally);
    });

    test('create_captcha', () {
      final generator = CaptchaGenerator();
      expectLater(generator.generate(length: 6), completes);
      expectLater(
        generator.generate(length: 6),
        completion(
          isA<Captcha>()
              .having((c) => c.length, 'length', 6)
              .having((c) => c.numbers.length == c.length, 'numbers', isTrue)
              .having((c) => c.text.length == c.length, 'text', isTrue)
              .having((c) => c.image.length, 'image', greaterThan(0)),
        ),
      );
    });

    test('Get chat short id', () {
      const chatId = -1002427514092;
      final shortId = Bot.shortId(chatId);
      expect(shortId, equals(2427514092));
    });

    group('retry', () {
      test('success', () {
        expectLater(retry(() async => 'Success'), completion(equals('Success')));
      });

      test('function succed after few tries', () {
        var attempt = 0;

        expectLater(
          retry<({String result, int attempt})>(
            () async {
              attempt++;
              if (attempt < 3) throw Exception('Error');
              return (result: 'Success!', attempt: attempt);
            },
            attempts: 5,
            delay: const Duration(milliseconds: 25),
          ),
          completion(equals((result: 'Success!', attempt: 3))),
        );
      });

      test('function throw error after few tries', () {
        var attempt = 0;

        final future = expectLater(
          retry(
            () async {
              attempt++;
              throw Exception('Exception with $attempt attempt');
            },
            attempts: 3,
            delay: const Duration(milliseconds: 25),
          ),
          throwsA(isA<Exception>()),
        );

        expectLater(future.then((_) => attempt), completion(equals(3)));
      });

      test('check onRetry callback', () {
        var attempt = 0;
        var attemptsLogged = <int>[];

        expectLater(
          retry(
            () async {
              attempt++;
              if (attempt < 3) throw Exception('Ошибка');
              return 'ОК';
            },
            attempts: 5,
            delay: const Duration(milliseconds: 25),
            onRetry: (attempt, error) => attemptsLogged.add(attempt),
          ).then((_) => attemptsLogged),
          completion(equals([1, 2])),
        );
      });

      test('shouldRetry filter exception', () async {
        var attempt = 0;

        await expectLater(
          () async => await retry(
            () async {
              attempt++;
              if (attempt < 3) throw const FormatException('Wrong format');
              throw TimeoutException('Timeout');
            },
            attempts: 5,
            delay: const Duration(milliseconds: 5),
            shouldRetry: (e) => e is FormatException, // Retry only FormatException
          ),
          throwsA(isA<TimeoutException>()), // Should throw TimeoutException
        );

        expect(attempt, equals(3)); // Attempted 3 times
      });

      test('backoff', () async {
        var attempt = 0;
        final stopwatch = Stopwatch()..start();

        await retry(
          () async {
            attempt++;
            if (attempt < 3) throw Exception('Error');
            return 'Success';
          },
          attempts: 3,
          delay: const Duration(milliseconds: 50),
          backoffFactor: 2, // Increase delay exponentially by 2
        );

        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, greaterThan(150)); // 150ms (50 + 100)
      });
    });
  });
}
