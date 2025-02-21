import 'package:test/test.dart';
import 'package:vixen/vixen.dart';

void main() => group('unit', () {
  test('arguments', () {
    expect(() => Arguments.parse(['-t 123']), returnsNormally);
  });
});
