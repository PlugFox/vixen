// ignore_for_file: unused_import
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final background = img.ColorUint8.rgb(255, 0, 0);
  // Создаём основное изображение (красный фон)
  final image = img.Image(
    width: 480,
    height: 180,
    format: img.Format.uint8, // Поддержка альфа-канала
    backgroundColor: background,
  );

  img.fill(image, color: background);

  // Шрифт и символ
  final font = img.arial48;
  const char = 'H';

  // Определяем размеры символа
  final charSize = font.characters[char.codeUnitAt(0)]!;
  final charImage = img.Image(
    width: charSize.width * 2,
    height: charSize.height * 2,
    format: img.Format.uint8,
    backgroundColor: background,
  );

  img.fill(charImage, color: background);

  // Рисуем символ с полупрозрачностью
  img.drawString(
    charImage,
    char,
    font: font,
    x: charSize.width ~/ 2,
    y: charSize.height ~/ 2,
    color: img.ColorUint8.rgb(0, 255, 0),
  );

  // Накладываем символ на основное изображение
  img.compositeImage(
    image,
    charImage,
    dstX: 100, // Позиция символа по X
    dstY: 50, // Позиция символа по Y
    blend: img.BlendMode.direct, // Альфа-канал сохраняется!
  );

  // Сохраняем изображение
  File('captcha.png').writeAsBytesSync(img.encodePng(image));
}
