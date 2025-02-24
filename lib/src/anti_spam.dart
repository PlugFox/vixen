import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Optimized spam detection algorithm with N-grams and Set-based spam phrase lookup
abstract final class AntiSpam {
  AntiSpam._();

  /// Spam phrases stored in a Set for O(1) lookup
  @visibleForTesting
  static const Set<String> $spamPhrases = <String>{
    // English spam phrases
    'make money',
    'work from home',
    'fast cash',
    'lose weight',
    'increase sales',
    'earn money',
    'details in dm',
    'details in pm',
    'details in private messages',
    'details in personal messages',
    'earn remotely',
    'earn online',
    'earn in network',
    'partners wanted',
    'buy now',
    'click here',
    'limited time',
    'act now',
    'best price',
    'free offer',
    'guarantee',
    'no obligation',

    // Срочность и ограниченность
    'только сегодня',
    'количество ограничено',
    'осталось немного',
    'последняя возможность',
    'успей купить',
    'акция заканчивается',
    'не упустите шанс',

    // Финансы и заработок
    'zarabotok',
    'быстрый заработок',
    'пассивный доход',
    'заработок в интернете',
    'работа на дому',
    'дополнительный доход',
    'высокий доход',
    'без вложений',
    'деньги без усилий',
    'заработок от',
    'доход от',
    'финансовая независимость',
    'миллион за месяц',
    'бизнес под ключ',

    // Скидки и цены
    'супер цена',
    'лучшая цена',
    'выгодное предложение',
    'без переплат',
    'специальное предложение',
    'уникальное предложение',

    // Здоровье и красота
    'похудение',
    'омоложение',
    'чудо-средство',
    'супер-эффект',
    'мгновенный результат',
    'похудеть без диет',
    'стопроцентный результат',
    'гарантированный эффект',
    'чудодейственный',

    // Призывы к действию
    'купить сейчас',
    'закажи сейчас',
    'звоните прямо сейчас',
    'перейдите по ссылке',

    // Гарантии и обещания
    'гарантия результата',
    'гарантированный доход',
    'стопроцентная гарантия',
    'без риска',

    // Инвестиции и криптовалюта
    'инвестиции под',
    'высокий процент',
    'криптовалюта',
    'биткоин',
    'майнинг',
    'прибыльные инвестиции',
    'доход от вложений',

    // Азартные игры
    'ставки на спорт',
    'казино',
    'беспроигрышная стратегия',

    // Кредиты и займы
    'кредит без справок',
    'займ без проверок',
    'деньги сразу',
    'одобрение без отказа',
    'кредит онлайн',
    'быстрые деньги',

    // Недвижимость
    'квартира в рассрочку',
    'без первоначального взноса',
    'материнский капитал',
    'ипотека без справок',

    // Образование и курсы
    'курсы похудения',
    'обучение заработку',
    'секреты успеха',
    'марафон похудения',
    'бесплатный вебинар',

    // Сетевой маркетинг
    'сетевой маркетинг',
    'бизнес возможность',
    'присоединяйся к команде',
    'построй свой бизнес',

    // Подозрительные обращения
    'дорогой клиент',
    'уважаемый пользователь',

    // Остальное
    'пассивного дохода',
    'ограниченное предложение',
    'действуйте сейчас',
    'бесплатное предложение',
    'без обязательств',
    'увеличение продаж',
    'писать в лc',
    'пишите в лс',
    'в лuчные сообщенuя',
    'личных сообщениях',
    'заработок удалённо',
    'заработок в сети',
    'для yдaлённoгo зaрaбoткa',
    'детали в лс',
    'ищу партнеров',
    'подробности в лс',
    'подробности в личке',
  };

  /// Stopwords in English and Russian
  @visibleForTesting
  static const Set<String> $stopwords = {
    // English stopwords
    'and', 'the', 'is', 'in', 'on', 'at', 'for', 'with', 'not',
    'by', 'be', 'this', 'are', 'from', 'or', 'that', 'an', 'it',
    'his', 'but', 'he', 'she', 'as', 'you', 'do', 'their', 'all',
    'will', 'there', 'can', 'i', 'me', 'my', 'myself', 'we', 'our', 'ours', 'ourselves',
    'your', 'yours', 'yourself', 'yourselves', 'him', 'himself',
    'her', 'hers', 'herself', 'its', 'itself', 'they', 'them',
    'theirs', 'themselves', 'what', 'which', 'who', 'whom',
    'these', 'those', 'am', 'was', 'were', 'been', 'being', 'have',
    'has', 'had', 'having', 'does', 'did', 'a', 'if', 'because',
    'until', 'while', 'of', 'about', 'against', 'between', 'into',
    'through', 'during', 'before', 'after', 'above', 'below', 'to',
    'up', 'down', 'out', 'off', 'over', 'under', 'again', 'further',
    'then', 'once', 'here', 'why', 'how', 'any', 'both', 'each',
    'few', 'more', 'most', 'other', 'some', 'such', 'no', 'nor',
    'only', 'own', 'same', 'so', 'than', 'too', 'very', 's', 't',
    'just', 'don', 'should', 'now',

    // Russian stopwords
    'а', 'без', 'более', 'больше', 'будет', 'будто', 'бы', 'был', 'была', 'были',
    'было', 'быть', 'в', 'вам', 'вас', 'вдруг', 'ведь', 'во', 'вот', 'впрочем',
    'все', 'всегда', 'всего', 'всех', 'всю', 'вы', 'где', 'да', 'даже', 'два',
    'для', 'до', 'другой', 'его', 'ее', 'если', 'есть', 'еще', 'же', 'за', 'здесь',
    'и', 'из', 'или', 'им', 'иногда', 'их', 'к', 'как', 'какая', 'какой', 'когда',
    'конечно', 'которого', 'которые', 'кто', 'куда', 'ли', 'лучше', 'между',
    'меня', 'мне', 'много', 'может', 'можно', 'мой', 'моя', 'мы', 'на', 'над',
    'надо', 'наконец', 'нас', 'не', 'него', 'нее', 'нельзя', 'нет', 'ни', 'нибудь',
    'никогда', 'ним', 'них', 'ничего', 'но', 'ну', 'о', 'об', 'один', 'он', 'она',
    'они', 'оно', 'опять', 'от', 'перед', 'по', 'под', 'после', 'потом', 'потому',
    'почти', 'при', 'про', 'раз', 'разве', 'с', 'сам', 'свое', 'свою', 'себе',
    'себя', 'сегодня', 'сейчас', 'сказал', 'сказала', 'сказать', 'со', 'совсем',
    'так', 'такой', 'там', 'тебя', 'тем', 'теперь', 'то', 'тогда', 'того', 'тоже',
    'только', 'том', 'тот', 'три', 'тут', 'ты', 'у', 'уж', 'уже', 'хорошо', 'хоть',
    'чего', 'чей', 'чем', 'через', 'что', 'чтоб', 'чтобы', 'чуть', 'эти', 'этого',
    'этой', 'этом', 'этот', 'эту', 'я',
  };

  /// Suspicious domain TLDs
  static const Set<String> $suspiciousDomains = {
    '.xyz',
    '.top',
    '.space',
    '.site',
    '.website',
    '.online',
    '.buzz',
    '.click',
    '.loan',
    '.work',
    '.date',
    '.racing',
    '.download',
  };

  /// URL regex pattern
  @visibleForTesting
  static final RegExp $urlPattern = RegExp(
    r'\b(?:https?://)?([a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:\.[a-zA-Z]{2,})?)\b',
    caseSensitive: false,
  );

  /// Capital letters regex
  @visibleForTesting
  static final RegExp $capitalLettersPattern = RegExp(r'[A-Z\u0410-\u042F]');

  /// Latin and Cyrillic character regex
  @visibleForTesting
  static final RegExp $latinPattern = RegExp('[a-zA-Z]');

  @visibleForTesting
  static final RegExp $cyrillicPattern = RegExp('[а-яА-ЯёЁ]');

  /// Max allowed URLs in text
  @visibleForTesting
  static const int $maxUrlCount = 3;

  /// Max allowed capital letter percentage
  @visibleForTesting
  static const double $maxCapitalLettersPercentage = 0.3;

  /// N-gram size
  @visibleForTesting
  static const int $nGramSize = 3;

  /// Removes stopwords from text
  @visibleForTesting
  static String $removeStopwords(String text) => text.split(' ').where((word) => !$stopwords.contains(word)).join(' ');

  /// Normalizes text by removing special characters, extra spaces, and converting to lowercase
  @visibleForTesting
  static String $normalizeText(String text) => $removeStopwords(
    text
        .replaceAll(RegExp(r'[\p{P}\p{S}]', unicode: true), '') // Remove special characters
        .replaceAll(RegExp(r'\s+'), ' ') // Remove extra spaces
        .trim()
        .toLowerCase(),
  );

  /// Calculates the percentage of capital letters in the text
  @visibleForTesting
  static double $calculateCapitalLettersPercentage(String text) {
    if (text.isEmpty) return 0;
    final totalLetters = text.length;
    final capitalCount = text.split('').where($capitalLettersPattern.hasMatch).length;
    return capitalCount / totalLetters;
  }

  /// Checks if text contains mixed alphabets (Latin + Cyrillic)
  @visibleForTesting
  static bool $hasMixedAlphabets(String text) => $latinPattern.hasMatch(text) && $cyrillicPattern.hasMatch(text);

  /// Extracts domains from text
  @visibleForTesting
  static Set<String> $extractDomains(String text) =>
      $urlPattern.allMatches(text).map((match) => match.group(1)!).toSet();

  /// Checks if the text contains suspicious domains
  @visibleForTesting
  static bool $hasSuspiciousDomains(String text) =>
      $extractDomains(text).any((domain) => $suspiciousDomains.any((tld) => domain.toLowerCase().endsWith(tld)));

  /// Counts the number of suspicious domains in the text
  @visibleForTesting
  static int $countSuspiciousDomains(String text) =>
      $extractDomains(
        text,
      ).where((domain) => $suspiciousDomains.any((tld) => domain.toLowerCase().endsWith(tld))).length;

  /// Generates N-grams from the input text
  @visibleForTesting
  static List<String> $generateNGrams(String text, int n) {
    if (text.length < n) return [text];
    final ngrams = <String>[];
    for (var i = 0; i <= text.length - n; i++) ngrams.add(text.substring(i, i + n));
    return ngrams;
  }

  /// Detects repetitive patterns using N-grams
  @visibleForTesting
  static bool $hasRepetitivePatterns(String text, {int n = 4}) {
    if (text.length < 16) return false;

    final ngrams = $generateNGrams(text, $nGramSize);
    final ngramCount = <String, int>{};

    for (final ngram in ngrams) {
      final count = ngramCount[ngram] = (ngramCount[ngram] ?? 0) + 1;
      if (count >= n) return true;
    }

    return false;
  }

  /// Checks if the text contains known spam phrases using Set lookup
  @visibleForTesting
  static String? $containsSpamPhrase(String text) => $spamPhrases.firstWhereOrNull((phrase) => text.contains(phrase));

  /// Asynchronous spam detection algorithm
  static Future<({bool spam, String reason})> check(String text) async =>
      Isolate.run<({bool spam, String reason})>(() => checkSync(text));

  /// Synchronous spam detection algorithm
  static ({bool spam, String reason}) checkSync(String text) {
    if (text.isEmpty) return (spam: false, reason: 'Empty text');

    // Normalize text
    final normalizedText = $normalizeText(text);

    // Check for short text
    if (normalizedText.length < 16) return (spam: false, reason: 'Text too short');

    // Check for suspicious domains
    if ($countSuspiciousDomains(text) case int count when count > 1)
      return (spam: true, reason: 'Suspicious domains detected ($count)');

    // Check for excessive URLs
    final urlCount = $urlPattern.allMatches(text).length;
    if (urlCount > $maxUrlCount) return (spam: true, reason: 'Too many URLs detected ($urlCount of ${$maxUrlCount})');

    // Check for mixed alphabets
    //if (hasMixedAlphabets(normalizedText)) return (spam: true, reason: 'Mixed Latin and Cyrillic alphabets detected');

    // Check capital letters percentage
    final capsPercentage = $calculateCapitalLettersPercentage(text);
    if (capsPercentage > $maxCapitalLettersPercentage)
      return (spam: true, reason: 'Excessive capital letters: ${(capsPercentage * 100).toStringAsFixed(1)}%');

    // Check for repetitive patterns using N-grams
    if ($hasRepetitivePatterns(normalizedText, n: 4)) return (spam: true, reason: 'Repetitive patterns detected');

    // Check for spam phrases using Set lookup
    if ($containsSpamPhrase(normalizedText) case String spamPhrase)
      return (spam: true, reason: 'Spam phrase detected: $spamPhrase');

    return (spam: false, reason: 'Text appears legitimate');
  }
}
