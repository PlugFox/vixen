/// Retries a function for a given number of [attempts] with a [delay] between each attempt.
/// You can optionally provide an [onRetry] callback to handle retries and a [shouldRetry] function
/// to filter which exceptions should trigger a retry.
/// The [backoffFactor] allows increasing delay time exponentially.
Future<T> retry<T>(
  Future<T> Function() fn, {
  int attempts = 3,
  Duration delay = const Duration(seconds: 1),
  void Function(int attempt, Object error)? onRetry,
  bool Function(Object error)? shouldRetry,
  double backoffFactor = 1.0, // Increase delay exponentially if needed
}) async {
  assert(attempts > 0, 'Number of attempts must be greater than zero');
  if (attempts < 2) return await fn(); // No retries needed

  var currentDelay = delay;

  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt == attempts) rethrow;
      if (!(shouldRetry?.call(e) ?? true)) rethrow;

      onRetry?.call(attempt, e);

      await Future<void>.delayed(currentDelay);
      currentDelay *= backoffFactor; // Apply exponential backoff if needed
    }
  }

  throw Exception('Retry logic failed unexpectedly'); // This should never be reached
}
