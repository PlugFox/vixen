import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:l/l.dart';
import 'package:meta/meta.dart';

/// Captcha class.
@immutable
class Captcha {
  const Captcha({
    required this.numbers,
    required this.text,
    required this.image,
    required this.width,
    required this.height,
  });

  /// Captcha length.
  int get length => numbers.length;

  /// Captcha numbers.
  final Uint8List numbers;

  /// Captcha text.
  final String text;

  /// Captcha image.
  final Uint8List image;

  /// Image width.
  final int width;

  /// Image height.
  final int height;
}

typedef CaptchaColor = ({int red, int green, int blue});

/// Captcha generator class.
class CaptchaGenerator {
  CaptchaGenerator({String fontPath = 'assets/font.webp'})
    : _font = img.decodeWebPFile(fontPath).then((image) => image!);

  static final Random _random = Random();

  @pragma('vm:prefer-inline')
  static Uint8List _generateRandomCaptchaNumbers(int length) {
    final captcha = Uint8List(length);
    for (var i = 0; i < length; i++) captcha[i] = _random.nextInt(10);
    return captcha;
  }

  @pragma('vm:prefer-inline')
  static img.Color _randomColor({int alpha = 255, int max = 255, int min = 0}) => img.ColorRgba8(
    min + _random.nextInt(max - min),
    min + _random.nextInt(max - min),
    min + _random.nextInt(max - min),
    alpha,
  );

  static void _drawRandomCircles({required img.Image image, required int width, required int height, int count = 16}) {
    for (var i = 0; i < count; i++) {
      final x = _random.nextInt(width);
      final y = _random.nextInt(height);
      final radius = 16 + _random.nextInt(width ~/ 4);
      img.fillCircle(image, x: x, y: y, radius: radius, color: _randomColor(alpha: 25 + _random.nextInt(50), max: 255));
    }
  }

  static void _drawRandomLines({required img.Image image, required int width, required int height, int count = 16}) {
    for (var i = 0; i < count; i++) {
      img.drawLine(
        image,
        x1: _random.nextInt(width),
        y1: _random.nextInt(height),
        x2: _random.nextInt(width),
        y2: _random.nextInt(height),
        color: _randomColor(max: 200),
        thickness: 8,
        antialias: true,
      );
    }
  }

  final Future<img.Image> _font;

  Future<Captcha> generate({int width = 480, int height = 180, int length = 4, CaptchaColor? background}) async {
    // Create a new image twice the size to improve quality
    var image = img.Image(width: width * 2, height: height * 2, format: img.Format.uint8);

    // Fill the image with a background color
    img.fill(
      image,
      color: switch (background) {
        (:int red, :int green, :int blue) => img.ColorUint8.rgb(
          red.clamp(0, 255),
          green.clamp(0, 255),
          blue.clamp(0, 255),
        ),
        _ => const img.ConstColorRgb8(0x37, 0x47, 0x4F),
      },
    );

    // Add some random circles
    _drawRandomCircles(image: image, width: width * 2, height: height * 2, count: 16);

    // Add some random lines
    _drawRandomLines(image: image, width: width * 2, height: height * 2, count: 8);

    image = img.gaussianBlur(image, radius: 16);

    // Generate a random captcha numbers
    final numbers = _generateRandomCaptchaNumbers(length);

    // Convert numbers to ASCII codes
    final text = String.fromCharCodes(numbers.map((n) => n + 48));

    // Draw the captcha numbers on the image
    final font = await _font;
    final srcCharWidth = font.width ~/ 10;
    final srcCharHeight = font.height;
    final srcAspectRatio = srcCharWidth / srcCharHeight;
    var dstCharWidth = width ~/ length;
    var dstCharHeight = height;
    if (dstCharWidth / dstCharHeight > srcAspectRatio) {
      dstCharWidth = (dstCharHeight * srcAspectRatio).toInt();
    } else {
      dstCharHeight = dstCharWidth ~/ srcAspectRatio;
    }
    final paddingX = width ~/ 10;
    for (var i = 0; i < text.length; i++) {
      final number = numbers[i];

      var charImage = img.Image(width: srcCharWidth * 8, height: srcCharHeight * 8, format: img.Format.uint8);

      img.compositeImage(
        charImage,
        font,
        dstX: 0,
        dstY: 0,
        dstW: srcCharWidth * 8,
        dstH: srcCharHeight * 8,
        srcX: number * srcCharWidth,
        srcY: 0,
        srcW: srcCharWidth,
        srcH: srcCharHeight,
        blend: img.BlendMode.direct,
      );

      // Randomly rotate the character
      final angle = (_random.nextDouble() - 0.25) * 0.25;
      charImage = img.copyRotate(charImage, angle: angle * 180 / pi, interpolation: img.Interpolation.average);

      charImage = img.gaussianBlur(charImage, radius: 8);

      // Copy the rotated character to the main image
      img.compositeImage(
        image,
        charImage,
        dstX: paddingX + i * (width * 2 - paddingX * 2) ~/ length + dstCharWidth ~/ 2,
        dstY: (height * 2 - dstCharHeight) ~/ 2,
        dstW: dstCharWidth,
        dstH: dstCharHeight,
        srcX: 0,
        srcY: 0,
        srcW: srcCharWidth * 8,
        srcH: srcCharHeight * 8,
        blend: img.BlendMode.subtract,
      );
    }

    // Add some random circles
    _drawRandomCircles(image: image, width: width * 2, height: height * 2, count: 16);

    // Add some random lines
    _drawRandomLines(image: image, width: width * 2, height: height * 2, count: 8);

    // Resize the image to the desired size
    final resized = img.copyResize(image, width: width, height: height, interpolation: img.Interpolation.average);

    // Convert the image to PNG
    final bytes = Uint8List.fromList(img.encodePng(resized));

    return Captcha(numbers: numbers, text: text, image: bytes, width: width, height: height);
  }
}

final class _CaptchaRequest {
  _CaptchaRequest({required this.width, required this.height, required this.length});

  final int width; // 480
  final int height; // 180
  final int length; // 6
}

void _captchaGeneratorIsolate(SendPort sendPort) => l.capture(
  () => runZonedGuarded<void>(
    () async {
      final generator = CaptchaGenerator();
      final receivePort = ReceivePort();
      sendPort.send(receivePort.sendPort);
      receivePort.listen((message) {
        switch (message) {
          case _CaptchaRequest request:
            generator
                .generate(width: request.width, height: request.height, length: request.length)
                .then(sendPort.send);
          default:
            l.w('Unknown message in captcha generator isolate: $message', StackTrace.current);
        }
      }, cancelOnError: false);
    },
    (e, s) {
      l.e('Caught an error in the captcha generator isolate: $e', s);
    },
  ),
  LogOptions(
    handlePrint: true,
    printColors: false,
    outputInRelease: true,
    overrideOutput: (log) {
      sendPort.send(log);
      return null;
    },
  ),
);

class CaptchaQueue {
  CaptchaQueue({int size = 6, int width = 480, int height = 180, int length = 6})
    : _size = size.clamp(1, 64),
      _width = width,
      _height = height,
      _length = length;

  final int _width; // 480
  final int _height; // 180
  final int _length; // 6

  final int _size;

  final Queue<Captcha> _queue = Queue<Captcha>();
  final Queue<Completer<Captcha>> _completers = Queue<Completer<Captcha>>();

  SendPort? _sendPort;
  Isolate? _isolate;

  @pragma('vm:prefer-inline')
  void _maybeRequest() {
    if (_completers.isEmpty && _queue.length >= _size) return;
    final port = _sendPort;
    if (port == null) return;
    port.send(_CaptchaRequest(width: _width, height: _height, length: _length));
  }

  @pragma('vm:prefer-inline')
  void _addToQueue(Captcha captcha) {
    try {
      if (_completers.isNotEmpty) {
        final completer = _completers.removeFirst();
        if (completer.isCompleted) {
          l.w('Completer is already completed', StackTrace.current);
        } else {
          completer.complete(captcha); // Complete the future
        }
      } else {
        _queue.add(captcha); // Store for later
      }
    } on Object catch (e, s) {
      l.e('Failed to add captcha to the queue: $e', s);
    } finally {
      _maybeRequest();
    }
  }

  /// Stop the captcha generator.
  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _sendPort = null;
  }

  /// Start the captcha generator.
  Future<void> start() async {
    stop();
    final completer = Completer<SendPort>();
    final receivePort =
        ReceivePort()..listen((message) {
          switch (message) {
            case Captcha c:
              _addToQueue(c);
            case LogMessage log:
              l.log(log);
            case SendPort sendPort:
              completer.complete(sendPort);
            default:
              l.w('Unknown message captcha isolate message: $message', StackTrace.current);
          }
        }, cancelOnError: false);
    _isolate = await Isolate.spawn(
      _captchaGeneratorIsolate,
      receivePort.sendPort,
      errorsAreFatal: false,
      debugName: 'Captcha generator',
    );
    _sendPort = await completer.future;
    _maybeRequest();
  }

  /// Get the next captcha.
  Future<Captcha> next() async {
    Captcha captcha;
    if (_queue.isEmpty) {
      final completer = Completer<Captcha>();
      _completers.add(completer);
      _maybeRequest();
      captcha = await completer.future;
    } else {
      captcha = _queue.removeFirst();
      _maybeRequest();
    }
    return captcha;
  }
}
