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
  });
}
