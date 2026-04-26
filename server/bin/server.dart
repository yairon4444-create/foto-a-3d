import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

Future<void> main() async {
  final meshyClient = MeshyClient.fromEnvironment();
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  final router = Router()
    ..get('/health', (_) {
      return _jsonResponse({
        'status': 'ok',
        'service': 'photo-to-3d-api',
        'timestamp': DateTime.now().toIso8601String(),
        'meshyConfigured': meshyClient.isConfigured,
      });
    })
    ..post('/v1/jobs', (Request request) async {
      if (!meshyClient.isConfigured) {
        return _jsonResponse(
          {
            'error':
                'MESHY_API_KEY is not configured on the server environment.',
          },
          statusCode: HttpStatus.serviceUnavailable,
        );
      }

      try {
        final payload = await _readJson(request);
        final imageBase64 = payload['imageBase64'] as String?;
        final fileName = (payload['fileName'] as String?)?.trim();
        final prompt = (payload['prompt'] as String?)?.trim();

        if (imageBase64 == null || imageBase64.isEmpty) {
          return _jsonResponse(
            {'error': 'imageBase64 is required'},
            statusCode: HttpStatus.badRequest,
          );
        }

        final resolvedName =
            (fileName == null || fileName.isEmpty) ? 'upload.jpg' : fileName;
        final imageBytes = base64Decode(imageBase64);
        final job = await meshyClient.createImageTo3DTask(
          fileName: resolvedName,
          imageBytes: imageBytes,
          prompt: prompt,
        );

        return _jsonResponse(
          {
            'jobId': job.jobId,
            'status': job.status,
            'message': 'Image received. Processing started in Meshy.',
          },
          statusCode: HttpStatus.accepted,
        );
      } on FormatException {
        return _jsonResponse(
          {'error': 'Request must contain valid JSON and Base64 image data'},
          statusCode: HttpStatus.badRequest,
        );
      } on MeshyApiException catch (error) {
        return _jsonResponse(
          {'error': error.message},
          statusCode: error.statusCode,
        );
      } catch (error) {
        return _jsonResponse(
          {'error': 'Unexpected server error: $error'},
          statusCode: HttpStatus.internalServerError,
        );
      }
    })
    ..get('/v1/jobs/<jobId>', (Request request, String jobId) async {
      if (!meshyClient.isConfigured) {
        return _jsonResponse(
          {
            'error':
                'MESHY_API_KEY is not configured on the server environment.',
          },
          statusCode: HttpStatus.serviceUnavailable,
        );
      }

      try {
        final job = await meshyClient.getImageTo3DTask(jobId);
        return _jsonResponse(job.toJson());
      } on MeshyApiException catch (error) {
        return _jsonResponse(
          {'error': error.message},
          statusCode: error.statusCode,
        );
      } catch (error) {
        return _jsonResponse(
          {'error': 'Unexpected server error: $error'},
          statusCode: HttpStatus.internalServerError,
        );
      }
    })
    ..get('/v1/jobs/<jobId>/stream', (Request request, String jobId) {
      if (!meshyClient.isConfigured) {
        return Response(
          HttpStatus.serviceUnavailable,
          body: 'event: error\ndata: {"message":"MESHY_API_KEY is not configured on the server environment."}\n\n',
          headers: {
            HttpHeaders.contentTypeHeader: 'text/event-stream',
            HttpHeaders.cacheControlHeader: 'no-cache',
          },
        );
      }

      return Response.ok(
        _streamJobUpdates(meshyClient, jobId),
        headers: {
          HttpHeaders.contentTypeHeader: 'text/event-stream',
          HttpHeaders.cacheControlHeader: 'no-cache',
          HttpHeaders.connectionHeader: 'keep-alive',
          'X-Accel-Buffering': 'no',
        },
      );
    });

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addHandler(router.call);

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('API listening on http://${server.address.host}:${server.port}');
}

Stream<List<int>> _streamJobUpdates(MeshyClient meshyClient, String jobId) async* {
  yield utf8.encode('retry: 2000\n\n');

  while (true) {
    try {
      final job = await meshyClient.getImageTo3DTask(jobId);
      final payload = jsonEncode(job.toJson());
      yield utf8.encode('event: message\ndata: $payload\n\n');

      if (job.status == 'completed' || job.status == 'failed') {
        break;
      }
    } on MeshyApiException catch (error) {
      final payload = jsonEncode({
        'message': error.message,
        'statusCode': error.statusCode,
      });
      yield utf8.encode('event: error\ndata: $payload\n\n');
      break;
    } catch (error) {
      final payload = jsonEncode({
        'message': 'Unexpected stream error: $error',
      });
      yield utf8.encode('event: error\ndata: $payload\n\n');
      break;
    }

    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

class MeshyClient {
  MeshyClient({
    required String? apiKey,
    http.Client? httpClient,
  })  : _apiKey = apiKey?.trim(),
        _httpClient = httpClient ?? http.Client();

  factory MeshyClient.fromEnvironment() {
    return MeshyClient(apiKey: Platform.environment['MESHY_API_KEY']);
  }

  static final Uri _createTaskUri =
      Uri.parse('https://api.meshy.ai/openapi/v1/image-to-3d');

  final String? _apiKey;
  final http.Client _httpClient;

  bool get isConfigured => (_apiKey ?? '').isNotEmpty;

  Future<JobView> createImageTo3DTask({
    required String fileName,
    required List<int> imageBytes,
    String? prompt,
  }) async {
    _ensureConfigured();

    final mimeType = _guessMimeType(fileName);
    final imageDataUri = 'data:$mimeType;base64,${base64Encode(imageBytes)}';

    final payload = <String, Object?>{
      'image_url': imageDataUri,
      'ai_model': 'latest',
      'model_type': 'standard',
      'should_texture': true,
      'enable_pbr': true,
      'should_remesh': true,
      'target_polycount': 50000,
      'image_enhancement': true,
      'remove_lighting': true,
      'target_formats': ['glb'],
    };

    if (prompt != null && prompt.isNotEmpty) {
      payload['texture_prompt'] = prompt;
    }

    final response = await _httpClient.post(
      _createTaskUri,
      headers: _headers,
      body: jsonEncode(payload),
    );

    final body = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MeshyApiException.fromResponse(
        response.statusCode,
        body,
        fallbackMessage: 'Meshy rejected the task creation request.',
      );
    }

    final jobId = body['result'] as String?;
    if (jobId == null || jobId.isEmpty) {
      throw const MeshyApiException(
        statusCode: 502,
        message: 'Meshy did not return a task id.',
      );
    }

    return JobView(
      jobId: jobId,
      status: 'queued',
      prompt: prompt,
    );
  }

  Future<JobView> getImageTo3DTask(String jobId) async {
    _ensureConfigured();

    final response = await _httpClient.get(
      Uri.parse('https://api.meshy.ai/openapi/v1/image-to-3d/$jobId'),
      headers: _headers,
    );

    final body = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MeshyApiException.fromResponse(
        response.statusCode,
        body,
        fallbackMessage: 'Meshy could not retrieve this task.',
      );
    }

    return JobView.fromMeshy(body);
  }

  Map<String, String> get _headers {
    return {
      HttpHeaders.authorizationHeader: 'Bearer $_apiKey',
      HttpHeaders.contentTypeHeader: 'application/json',
    };
  }

  void _ensureConfigured() {
    if (!isConfigured) {
      throw const MeshyApiException(
        statusCode: 503,
        message: 'MESHY_API_KEY is not configured on the server environment.',
      );
    }
  }
}

class JobView {
  const JobView({
    required this.jobId,
    required this.status,
    this.createdAt,
    this.completedAt,
    this.modelUrl,
    this.thumbnailUrl,
    this.prompt,
    this.progress,
    this.errorMessage,
  });

  factory JobView.fromMeshy(Map<String, dynamic> body) {
    final modelUrls = body['model_urls'];
    final taskError = body['task_error'];

    return JobView(
      jobId: body['id'] as String? ?? '',
      status: _mapMeshyStatus(body['status'] as String?),
      createdAt: _millisToIsoString(body['created_at']),
      completedAt: _millisToIsoString(body['finished_at']),
      modelUrl:
          modelUrls is Map<String, dynamic> ? modelUrls['glb'] as String? : null,
      thumbnailUrl: body['thumbnail_url'] as String?,
      prompt: body['texture_prompt'] as String?,
      progress: body['progress'] as int?,
      errorMessage: taskError is Map<String, dynamic>
          ? taskError['message'] as String?
          : null,
    );
  }

  final String jobId;
  final String status;
  final String? createdAt;
  final String? completedAt;
  final String? modelUrl;
  final String? thumbnailUrl;
  final String? prompt;
  final int? progress;
  final String? errorMessage;

  Map<String, Object?> toJson() {
    return {
      'jobId': jobId,
      'status': status,
      'createdAt': createdAt,
      'completedAt': completedAt,
      'modelUrl': modelUrl,
      'thumbnailUrl': thumbnailUrl,
      'prompt': prompt,
      'progress': progress,
      'errorMessage': errorMessage,
    };
  }
}

class MeshyApiException implements Exception {
  const MeshyApiException({
    required this.statusCode,
    required this.message,
  });

  factory MeshyApiException.fromResponse(
    int statusCode,
    Map<String, dynamic> body, {
    required String fallbackMessage,
  }) {
    final directMessage = body['message'] as String?;
    final nestedError = body['error'];
    final errorMessage = nestedError is Map<String, dynamic>
        ? nestedError['message'] as String?
        : null;

    return MeshyApiException(
      statusCode: statusCode,
      message: directMessage ?? errorMessage ?? fallbackMessage,
    );
  }

  final int statusCode;
  final String message;
}

Middleware _corsMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }

      final response = await innerHandler(request);
      return response.change(headers: {
        ...response.headers,
        ..._corsHeaders,
      });
    };
  };
}

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

Response _jsonResponse(
  Map<String, Object?> body, {
  int statusCode = HttpStatus.ok,
}) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
    },
  );
}

Future<Map<String, dynamic>> _readJson(Request request) async {
  final rawBody = await request.readAsString();
  if (rawBody.trim().isEmpty) {
    return <String, dynamic>{};
  }

  final decoded = jsonDecode(rawBody);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Body must be a JSON object');
  }

  return decoded;
}

Map<String, dynamic> _decodeJson(String responseBody) {
  if (responseBody.trim().isEmpty) {
    return <String, dynamic>{};
  }

  final decoded = jsonDecode(responseBody);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Response body must be a JSON object');
  }

  return decoded;
}

String _guessMimeType(String fileName) {
  switch (p.extension(fileName).toLowerCase()) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    default:
      return 'image/jpeg';
  }
}

String? _millisToIsoString(Object? millis) {
  if (millis is int) {
    return DateTime.fromMillisecondsSinceEpoch(millis).toIso8601String();
  }

  return null;
}

String _mapMeshyStatus(String? status) {
  switch (status) {
    case 'PENDING':
      return 'queued';
    case 'IN_PROGRESS':
      return 'processing';
    case 'SUCCEEDED':
      return 'completed';
    case 'FAILED':
    case 'CANCELED':
    case 'CANCELLED':
      return 'failed';
    default:
      return 'processing';
  }
}
