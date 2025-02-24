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

  antiSpamTest();
}

void antiSpamTest() {
  group('AntiSpam Tests', () {
    // Helper function to make tests more readable
    bool isSpam(String text) {
      final result = AntiSpam.checkSync(text);
      return result.spam;
    }

    group('Basic Text Tests', () {
      test('empty text should not be spam', () async {
        expect(isSpam(''), isFalse);
      });

      test('normal text should not be spam', () async {
        expect(isSpam('Привет! Как дела? Давно не виделись.'), isFalse);
      });

      test('very short text should not be spam', () async {
        expect(isSpam('Ок'), isFalse);
      });
    });

    group('Capital Letters Tests', () {
      test('text with normal capitalization should not be spam', () async {
        expect(isSpam('Привет! Как Прошел Твой День?'), isFalse);
      });

      test('text with excessive caps should be spam', () async {
        expect(isSpam('СУПЕР ПРЕДЛОЖЕНИЕ! ТОЛЬКО СЕГОДНЯ! ВСЕ БЕСПЛАТНО!'), isTrue);
      });

      test('mixed caps should be detected', () async {
        expect(isSpam('СуПеР ЗаРаБоТоК в СеТи!!!'), isTrue);
      });
    });

    group('URL Tests', () {
      test('text with single URL should not be spam', () async {
        expect(isSpam('Посмотри интересную статью https://example.com'), isFalse);
      });

      test('text with multiple URLs should be spam', () async {
        expect(
          isSpam('''
            https://buy.com
            https://cheap.com
            https://discount.com
            https://best-price.com
          '''),
          isTrue,
        );
      });

      test('text with suspicious domain should be flagged', () async {
        expect(isSpam('Заходи на super-money.xyz и easy-money.online!'), isTrue);
      });
    });

    group('Spam Phrases Tests', () {
      test('single spam phrase detection', () async {
        expect(isSpam('Гарантированный доход от 100000 рублей!'), isTrue);
      });

      test('multiple spam phrases detection', () async {
        expect(isSpam('Быстрый заработок! Работа на дому! Без вложений!'), isTrue);
      });

      test('spam phrase with normal context should still be detected', () async {
        expect(isSpam('Я нашел способ пассивного дохода, который реально работает!'), isTrue);
      });
    });

    group('Character Replacement Tests', () {
      test('mixed alphabet detection', () async {
        expect(isSpam('Zarabotok na domu!'), isTrue);
      });

      test('normal text with numbers should not be spam', () async {
        expect(isSpam('Встречаемся в 12:30 возле входа'), isFalse);
      });
    });

    group('Repetitive Pattern Tests', () {
      test('repeated words detection', () async {
        expect(isSpam('Купить купить купить купить прямо сейчас!'), isTrue);
      });

      test('repeated patterns detection', () async {
        expect(isSpam('Акция! Акция! Акция! Акция! Скидки! Скидки! Скидки!'), isTrue);
      });

      test('normal repetition should not be spam', () async {
        expect(isSpam('Да-да, я тебя слышу. Хорошо-хорошо.'), isFalse);
      });
    });

    group('Special Cases Tests', () {
      test('emoji-only text should not be spam', () async {
        expect(isSpam('👋 🌞 😊'), isFalse);
      });

      test('text with normal emoji usage should not be spam', () async {
        expect(isSpam('Привет! Как дела? 😊'), isFalse);
      });

      test('excessive emoji with spam content should be spam', () async {
        expect(isSpam('‼️СУПЕР АКЦИЯ‼️ 💰ДЕНЬГИ💰 🔥СКИДКИ🔥'), isTrue);
      });
    });

    group('Mixed Content Tests', () {
      test('legitimate business announcement should not be spam', () async {
        expect(
          isSpam('''
            Уважаемые клиенты!
            Информируем вас о плановом обновлении сервиса 25 марта.
            Сервис будет недоступен с 2:00 до 5:00 по московскому времени.
            Приносим извинения за возможные неудобства.
          '''),
          isFalse,
        );
      });

      test('legitimate sale announcement should not be spam', () async {
        expect(
          isSpam('''
            В нашем магазине сезонная распродажа.
            Скидки на зимнюю коллекцию до 30%.
            Ждем вас по адресу: ул. Примерная, д. 1
            Режим работы: 10:00 - 20:00
          '''),
          isFalse,
        );
      });

      test('spam with legitimate-looking content should be detected', () async {
        expect(
          isSpam('''
            СРОЧНО! ТОЛЬКО СЕГОДНЯ!
            Распродажа брендовой одежды!
            Скидки до 90%!!!
            Количество ограничено!!!
            Спешите купить по СУПЕР ЦЕНЕ!!!
            Жми на ссылку прямо сейчас!!!
            www.super-sale.xyz
          '''),
          isTrue,
        );
      });
    });

    group('Edge Cases Tests', () {
      test('text with multiple languages should be handled', () async {
        expect(isSpam('Hello! Привет! Bonjour! 你好!'), isFalse);
      });

      test('text with special characters should be handled', () async {
        expect(isSpam(r'$#@&* тестовое сообщение #@$*&'), isFalse);
      });

      test('very long text should be handled', () async {
        var longText = 'Нормальное предложение. ' * 100;
        expect(isSpam(longText), isTrue); // repetition
      });

      test('html content should be handled', () async {
        expect(isSpam('<b>КУПИТЬ СЕЙЧАС</b> <i>по выгодной цене!!!</i>'), isTrue);
      });
    });

    group('Suspicious Domains Tests', () {
      test('extractDomains should find all domains in text', () {
        const text = '''
          Check out these sites:
          https://example.com
          http://test.xyz
          www.spam.space
          good.website
          тест.рф
        ''';

        final domains = AntiSpam.extractDomains(text);
        expect(domains, containsAll(['example.com', 'test.xyz', 'www.spam.space', 'good.website']));
      });

      test('isSuspiciousDomain should detect suspicious TLDs', () {
        expect(AntiSpam.hasSuspiciousDomains('test.xyz'), isTrue);
        expect(AntiSpam.hasSuspiciousDomains('example.space'), isTrue);
        expect(AntiSpam.hasSuspiciousDomains('spam.top'), isTrue);
        expect(AntiSpam.hasSuspiciousDomains('test.com'), isFalse);
        expect(AntiSpam.hasSuspiciousDomains('example.org'), isFalse);
      });

      test('countSuspiciousDomains should count correctly', () {
        const text = '''
          Check these:
          https://good.com
          http://bad.xyz
          www.spam.space
          normal.org
          test.top
        ''';

        expect(AntiSpam.countSuspiciousDomains(text), 3); // xyz, space, top
      });

      test('should not detect cyrillic domains', () {
        expect(AntiSpam.hasSuspiciousDomains('тест.рф'), isFalse);
        expect(AntiSpam.hasSuspiciousDomains('сайт.москва'), isFalse);
      });

      test('should handle domains with subdomains', () {
        expect(AntiSpam.hasSuspiciousDomains('sub.test.xyz'), isTrue);
        expect(AntiSpam.hasSuspiciousDomains('sub.example.com'), isFalse);
      });

      test('should detect mixed legitimate and suspicious domains', () async {
        const text = '''
          Наш официальный сайт: example.com
          А также: spam.xyz, test.space
        ''';

        final result = await AntiSpam.check(text);
        expect(result.spam, isTrue);
        expect(result.reason, contains('Suspicious domains'));
      });

      test('should ignore domains in legitimate contexts', () async {
        const text = '''
          Уважаемые клиенты!
          Наш новый сайт: example.com
          С уважением, команда поддержки
        ''';

        final result = await AntiSpam.check(text);
        expect(result.spam, isFalse);
      });
    });

    group('False Positive Prevention Tests', () {
      test('business email should not be spam', () async {
        expect(
          isSpam('''
            Уважаемые коллеги,

            Направляю вам отчет о продажах за март 2024 года.
            Общая выручка составила 1,250,000 рублей.
            Рост по сравнению с предыдущим месяцем: 15%.

            С уважением,
            Иван Петров
            Отдел продаж
          '''),
          isFalse,
        );
      });

      test('legitimate newsletter should not be spam', () async {
        expect(
          isSpam('''
            Новости компании "Пример"

            1. Открыт новый офис в Москве
            2. Запущена акция для постоянных клиентов
            3. Обновлен каталог продукции

            Подробности на сайте example.com
          '''),
          isFalse,
        );
      });

      test('technical instructions should not be spam', () async {
        expect(
          isSpam('''
            Инструкция по установке:
            1. Скачайте файл
            2. Запустите установщик
            3. Следуйте инструкциям на экране

            Техподдержка: support@example.com
          '''),
          isFalse,
        );
      });
    });
  });
}
