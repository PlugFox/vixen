// ignore_for_file: avoid_classes_with_only_static_members

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:shelf/shelf.dart' as shelf;
import 'package:vixen/vixen.dart';

/// Statuses
const ({String ok, String error}) _kStatus = (ok: 'ok', error: 'error');

/// Headers
final Map<String, String> _headers = <String, String>{
  'Content-Type': io.ContentType.json.value,
  /* 'Cache-Control': 'public, max-age=86400', */
};

/// Responses
sealed class Responses {
  /// Response encoder
  static final Converter<Map<String, Object?>, List<int>> _responseEncoder = JsonEncoder(
    (obj) => switch (obj) {
      DateTime dt => dt.toUtc().toIso8601String(),
      Exception e => kDebugMode ? e.toString() : '<Exception>',
      Error e => kDebugMode ? e.toString() : '<Error>',
      StackTrace st => kDebugMode ? st.toString() : '<StackTrace>',
      _ => kDebugMode ? '<${obj.runtimeType}>' : '<Object>',
    },
  ).cast<Map<String, Object?>, String>().fuse(const Utf8Encoder());

  /// Ok
  static Future<shelf.Response> ok(Object? data, {Map<String, String>? headers}) {
    String contentType;
    Object body;
    switch (data) {
      case Map<String, Object?> data:
        contentType = io.ContentType.json.value;
        body = _responseEncoder.convert(<String, Object>{'status': _kStatus.ok, 'data': data});
      case null:
        contentType = io.ContentType.json.value;
        body = utf8.encode('{"status":"${_kStatus.ok}"}');
      case List<int> data:
        contentType = io.ContentType.binary.value;
        body = data;
      case String data:
        contentType = io.ContentType.text.value;
        body = data;
      case DateTime data:
        return ok({'value': data.toUtc().toIso8601String()}, headers: headers);
      case num data:
        return ok({'value': data}, headers: headers);
      case List<Object?> data:
        return ok({'value': data}, headers: headers);
      default:
        return error(
          const HttpException(
            status: io.HttpStatus.internalServerError,
            code: 'internal',
            message: 'Internal Server Error',
            data: <String, Object?>{'error': 'Invalid response data type'},
          ),
        );
    }
    return Future<shelf.Response>.value(
      shelf.Response.ok(
        body,
        headers: <String, String>{
          ..._headers,
          ...?headers,
          if (headers == null ||
              headers.isEmpty ||
              !headers.containsKey('Content-Type') ||
              !headers.containsKey('content-type'))
            'Content-Type': contentType,
        },
      ),
    );
  }

  /// Error
  static Future<shelf.Response> error(HttpException exception, {Map<String, String>? headers}) {
    final body = _responseEncoder.convert(exception.toJson());
    return Future<shelf.Response>.value(
      shelf.Response(
        exception.status,
        body: body,
        headers: <String, String>{..._headers, ...?headers, 'Content-Length': body.length.toString()},
      ),
    );
  }
}

/// HTTP exception enables to immediately stop request execution
/// and send an appropriate error message to the client. An option
/// [Map] data can be provided to add additional information as
/// the response body.
class HttpException implements Exception {
  const HttpException({
    this.status = io.HttpStatus.internalServerError,
    this.code = 'internal',
    this.message = 'Internal Server Error',
    this.data,
  });

  final int status;
  final String code;
  final String message;
  final Map<String, Object?>? data;

  HttpException copyWith({int? status, String? message, Map<String, Object?>? data}) =>
      HttpException(status: status ?? this.status, message: message ?? this.message, data: data ?? this.data);

  Map<String, Object?> toJson() => <String, Object?>{
    'status': _kStatus.error,
    'error': <String, Object?>{'status': status, 'code': code, 'message': message, if (data != null) 'details': data},
  };

  @override
  String toString() => 'HttpException ${status.toString()}: $message';
}

// 400 Bad Request
class BadRequestException extends HttpException {
  const BadRequestException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.badRequest,
        code: 'bad_request',
        message: "Bad Request${detail != '' ? ': ' : ''}$detail",
      );
}

// 401 Unauthorized
class UnauthorizedException extends HttpException {
  const UnauthorizedException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.unauthorized,
        code: 'unauthorized',
        message: "Unauthorized${detail != '' ? ': ' : ''}$detail",
      );
}

// 402 Payment Required
class PaymentRequiredException extends HttpException {
  const PaymentRequiredException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.paymentRequired,
        code: 'payment_required',
        message: "Payment Required${detail != '' ? ': ' : ''}$detail",
      );
}

// 403 Forbidden
class ForbiddenException extends HttpException {
  const ForbiddenException({super.data, String detail = ''})
    : super(status: io.HttpStatus.forbidden, code: 'forbidden', message: "Forbidden${detail != '' ? ': ' : ''}$detail");
}

// 404 Not Found
class NotFoundException extends HttpException {
  const NotFoundException({super.data, String detail = ''})
    : super(status: io.HttpStatus.notFound, code: 'not_found', message: "Not Found${detail != '' ? ': ' : ''}$detail");
}

// 405 Method Not Allowed
class MethodNotAllowed extends HttpException {
  const MethodNotAllowed({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.methodNotAllowed,
        code: 'method_not_allowed',
        message: "Method Not Allowed${detail != '' ? ': ' : ''}$detail",
      );
}

// 406 Not Acceptable
class NotAcceptableException extends HttpException {
  const NotAcceptableException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.notAcceptable,
        code: 'not_acceptable',
        message: "Not Acceptable${detail != '' ? ': ' : ''}$detail",
      );
}

// 409 Conflict
class ConflictException extends HttpException {
  const ConflictException({super.data, String detail = ''})
    : super(status: io.HttpStatus.conflict, code: 'conflict', message: "Conflict${detail != '' ? ': ' : ''}$detail");
}

// 410 Gone
class GoneException extends HttpException {
  const GoneException({super.data, String detail = ''})
    : super(status: io.HttpStatus.gone, code: 'gone', message: "Gone${detail != '' ? ': ' : ''}$detail");
}

// 412 Precondition Failed
class PreconditionFailedException extends HttpException {
  const PreconditionFailedException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.preconditionFailed,
        code: 'precondition_failed',
        message: "Precondition Failed${detail != '' ? ': ' : ''}$detail",
      );
}

// 415 Unsupported Media Type
class UnsupportedMediaTypeException extends HttpException {
  const UnsupportedMediaTypeException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.unsupportedMediaType,
        code: 'unsupported_media_type',
        message: "Unsupported Media Type${detail != '' ? ': ' : ''}$detail",
      );
}

// 429 Too Many Requests
class TooManyRequestsException extends HttpException {
  const TooManyRequestsException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.tooManyRequests,
        code: 'too_many_requests',
        message: "Too Many Requests${detail != '' ? ': ' : ''}$detail",
      );
}

/// 500 Internal Server Error
class InternalServerError extends HttpException {
  const InternalServerError({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.internalServerError,
        code: 'internal_server_error',
        message: "Internal Server Error${detail != '' ? ': ' : ''}$detail",
      );
}

// 501 Not Implemented
class NotimplementedException extends HttpException {
  const NotimplementedException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.notImplemented,
        code: 'not_implemented',
        message: "Not Implemented${detail != '' ? ': ' : ''}$detail",
      );
}

// 503 Service Unavailable
class ServiceUnavailableException extends HttpException {
  const ServiceUnavailableException({super.data, String detail = ''})
    : super(
        status: io.HttpStatus.serviceUnavailable,
        code: 'service_unavailable',
        message: "Service Unavailable${detail != '' ? ': ' : ''}$detail",
      );
}
