import 'package:meta/meta.dart';

/// Basic spam detection algorithm for text messages
abstract final class AntiSpam {
  AntiSpam._();

  // Common spam phrases and patterns
  @visibleForTesting
  static const Set<String> spamPhrases = <String>{
    // English spam phrases
    'make money',
    'work from home',
    'fast cash',
    'lose weight',
    'increase sales',
    'sale',
    'offer',
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
    'discount',
    'free offer',
    'guarantee',
    'no obligation',
    'winner',

    // Срочность и ограниченность
    'срочно',
    'только сегодня',
    'количество ограничено',
    'спешите',
    'осталось немного',
    'последняя возможность',
    'успей купить',
    'акция заканчивается',
    'не упустите шанс',

    // Финансы и заработок
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
    'скидка',
    'распродажа',
    'акция',
    'бесплатно',
    'даром',
    'супер цена',
    'лучшая цена',
    'выгодное предложение',
    'экономия',
    'дешево',
    'без переплат',
    'специальное предложение',
    'уникальное предложение',

    // Преувеличения
    'самый лучший',
    'невероятно',
    'потрясающе',
    'революционный',
    'эксклюзивный',
    'инновационный',
    'сенсация',
    'шок',
    'взрыв продаж',

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
    'кликните здесь',
    'перейдите по ссылке',
    'регистрируйся',
    'жми',
    'торопись',

    // Гарантии и обещания
    'гарантия результата',
    'гарантированный доход',
    'стопроцентная гарантия',
    'без риска',
    'проверено',
    'безопасно',
    'надежно',

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
    'выигрыш',
    'джекпот',
    'лотерея',

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
    'интенсив',

    // Сетевой маркетинг
    'сетевой маркетинг',
    'млм',
    'бизнес возможность',
    'присоединяйся к команде',
    'построй свой бизнес',

    // Фразы-усилители
    'только для вас',
    'эксклюзивно',
    'ограниченная серия',
    'специально для',
    'впервые',
    'революционно',

    // Манипулятивные фразы
    'все уже там',
    'не пропусти',
    'читать всем',
    'срочная новость',
    'шокирующая информация',
    'вы не поверите',

    // Подозрительные обращения
    'дорогой клиент',
    'уважаемый пользователь',
    'вы выиграли',
    'поздравляем вас',

    // Фразы для рассылок
    'отписаться',
    'рассылка',
    'подпишись',
    'подписаться на новости',
    'получать уведомления',

    // Остальное
    'ограниченное предложение',
    'действуйте сейчас',
    'бесплатное предложение',
    'гарантия',
    'без обязательств',
    'победитель',
    'увеличение продаж',
    'в личку',
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

  // Подозрительные домены
  static const Set<String> suspiciousDomains = <String>{
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

  // URL regex pattern (supports Cyrillic domains)
  @visibleForTesting
  static final RegExp urlPattern = RegExp(r'\b[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:\.[a-zA-Z]{2,})?\b', caseSensitive: false);

  // Emoji pattern
  @visibleForTesting
  static final RegExp emojiPattern = RegExp(
    r'[\u{1F300}-\u{1F9FF}]|[\u{2702}-\u{27B0}]|[\u{1F000}-\u{1F251}]',
    unicode: true,
  );

  // Special characters pattern (includes Russian letters)
  @visibleForTesting
  static final RegExp specialCharsPattern = RegExp(r'[^\w\s\u0410-\u044F]');

  // Pattern for detecting Russian letters
  @visibleForTesting
  static final RegExp russianLettersPattern = RegExp(r'[\u0410-\u044F]');

  // Maximum allowed URL count
  @visibleForTesting
  static const int maxUrlCount = 3;

  // Maximum allowed capital letters percentage
  @visibleForTesting
  static const double maxCapitalLettersPercentage = 0.3;

  // N-gram size for text analysis
  @visibleForTesting
  static const int nGramSize = 3;

  /// Normalizes the input text by removing emojis, extra spaces, and converting to lowercase
  @visibleForTesting
  static String normalizeText(String text) =>
      text
          // Remove emojis
          .replaceAll(emojiPattern, '')
          // Remove extra whitespace
          .replaceAll(RegExp(r'\s+'), ' ')
          // Remove special characters
          .replaceAll(specialCharsPattern, '')
          // Trim leading and trailing whitespace
          .trim()
          // Convert to lowercase
          .toLowerCase();

  /// Generates n-grams from the input text
  @visibleForTesting
  static List<String> generateNGrams(String text, int n) {
    if (text.length < n) return [text];
    final ngrams = <String>[];
    for (var i = 0; i <= text.length - n; i++) ngrams.add(text.substring(i, i + n));
    return ngrams;
  }

  /// Extracts all domains from text
  @visibleForTesting
  static List<String> extractDomains(String text) => urlPattern
      .allMatches(text)
      .map((match) => match.group(0)) // Используем group(0), т.к. теперь регулярка проще
      .whereType<String>() // Исключаем null-значения
      .map((domain) => domain.toLowerCase()) // Приводим к нижнему регистру
      .toList(growable: false);

  /// Checks if domain ends with any suspicious TLD
  @visibleForTesting
  static bool isSuspiciousDomain(String domain) =>
      suspiciousDomains.any((suspiciousTLD) => domain.toLowerCase().endsWith(suspiciousTLD.toLowerCase()));

  /// Counts suspicious domains in text
  @visibleForTesting
  static int countSuspiciousDomains(String text) {
    final domains = extractDomains(text);
    return domains.where(isSuspiciousDomain).length;
  }

  /// Calculates the percentage of capital letters in the text (supports Russian)
  @visibleForTesting
  static double calculateCapitalLettersPercentage(String text) {
    if (text.isEmpty) return 0;

    final capitalCount = text.split('').where((char) => char.contains(RegExp(r'[A-Z\u0410-\u042F]'))).length;
    return capitalCount / text.length;
  }

  /// Checks for repetitive patterns in the text
  @visibleForTesting
  static bool hasRepetitivePatterns(String text) {
    if (text.length < 10) return false;

    // Check for repeated words
    final words = text.split(' ');
    final wordCount = <String, int>{};

    for (final word in words) {
      if (word.length < 3) continue;
      wordCount[word] = (wordCount[word] ?? 0) + 1;
      if (wordCount[word]! >= 3) return true;
    }

    // Check for repeated character patterns
    final ngrams = generateNGrams(text, 3);
    final ngramCount = <String, int>{};

    for (final ngram in ngrams) {
      ngramCount[ngram] = (ngramCount[ngram] ?? 0) + 1;
      if (ngramCount[ngram]! >= 4) return true;
    }

    return false;
  }

  /// Checks if text contains mixed alphabets (Latin + Cyrillic)
  @visibleForTesting
  static bool hasMixedAlphabets(String text) {
    final hasLatin = RegExp('[a-zA-Z]').hasMatch(text);
    final hasCyrillic = russianLettersPattern.hasMatch(text);
    return hasLatin && hasCyrillic;
  }

  /// Main spam detection function
  static Future<({bool spam, String reason})> check(String text) async {
    if (text.isEmpty) return (spam: false, reason: 'Empty text');

    // Store original text for capital letters check
    final originalText = text;

    // Normalize text
    final normalizedText = normalizeText(text);

    // Check text length
    if (normalizedText.length < 24) return (spam: false, reason: 'Text too short');

    // Check for suspicious domains
    final suspiciousDomainsCount = countSuspiciousDomains(text);
    if (suspiciousDomainsCount > 1) return (spam: true, reason: 'Suspicious domains detected: $suspiciousDomainsCount');

    // Check for excessive URLs
    final urlCount = urlPattern.allMatches(normalizedText).length;
    if (urlCount > maxUrlCount)
      return (spam: true, reason: 'Excessive URLs detected: $urlCount (max allowed: $maxUrlCount)');

    // Check for mixed alphabets (can be suspicious)
    //if (hasMixedAlphabets(normalizedText)) return (spam: true, reason: 'Mixed Latin and Cyrillic alphabets detected');

    // Check capital letters percentage
    final capsPercentage = calculateCapitalLettersPercentage(originalText);
    if (capsPercentage > maxCapitalLettersPercentage)
      return (spam: true, reason: 'Excessive capital letters: ${(capsPercentage * 100).toStringAsFixed(1)}%');

    // Check for repetitive patterns
    if (hasRepetitivePatterns(normalizedText)) return (spam: true, reason: 'Repetitive patterns detected');

    // Check for spam phrases
    for (final phrase in spamPhrases)
      if (normalizedText.contains(phrase)) return (spam: true, reason: 'Spam phrase detected: "$phrase"');

    // Generate and analyze n-grams
    final ngrams = generateNGrams(normalizedText, nGramSize);
    final ngramFrequency = <String, int>{};

    for (final ngram in ngrams) ngramFrequency[ngram] = (ngramFrequency[ngram] ?? 0) + 1;

    // Check for suspicious n-gram patterns
    var suspiciousNGrams = 0;
    ngramFrequency.forEach((ngram, count) {
      if (count > ngrams.length / 4) suspiciousNGrams++;
    });

    if (suspiciousNGrams > 3) return (spam: true, reason: 'Suspicious n-gram patterns detected');

    // If all checks pass, consider the text as non-spam
    return (spam: false, reason: 'Text appears legitimate');
  }
}
