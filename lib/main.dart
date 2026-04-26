import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';
import 'package:http/http.dart' as http;
import 'package:model_viewer_plus/model_viewer_plus.dart';

void main() {
  runApp(const PhotoTo3DApp());
}

const _defaultApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080',
);

class PhotoTo3DApp extends StatelessWidget {
  const PhotoTo3DApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Foto a 3D',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F4EE),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _baseUrlController = TextEditingController(
    text: _defaultApiBaseUrl,
  );
  final TextEditingController _promptController = TextEditingController(
    text: 'high detail object reconstruction',
  );
  final Flutter3DController _viewerController = Flutter3DController();

  Uint8List? _imageBytes;
  String? _fileName;
  String? _jobId;
  String? _jobStatus;
  DateTime? _jobStartedAt;
  String? _modelUrl;
  String? _thumbnailUrl;
  String? _errorMessage;
  String? _viewerMessage;
  String _statusText = 'Selecciona una imagen para iniciar un trabajo.';
  int? _progress;
  bool _isPicking = false;
  bool _isSubmitting = false;
  Timer? _pollingTimer;
  StreamSubscription<String>? _jobStreamSubscription;

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _jobStreamSubscription?.cancel();
    _baseUrlController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() {
      _isPicking = true;
      _errorMessage = null;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );

      if (!mounted) {
        return;
      }

      if (result == null || result.files.isEmpty) {
        setState(() {
          _statusText = 'No se selecciono ninguna imagen.';
        });
        return;
      }

      final file = result.files.single;
      if (file.bytes == null) {
        setState(() {
          _errorMessage =
              'No pude leer la imagen en memoria. Prueba con otra imagen.';
        });
        return;
      }

      setState(() {
        _imageBytes = file.bytes;
        _fileName = file.name;
        _jobId = null;
        _jobStatus = null;
        _jobStartedAt = null;
        _modelUrl = null;
        _thumbnailUrl = null;
        _progress = null;
        _errorMessage = null;
        _statusText = 'Imagen lista para enviar.';
      });

      await _stopTracking();
    } catch (error) {
      setState(() {
        _errorMessage = 'Error al seleccionar la imagen: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPicking = false;
        });
      }
    }
  }

  Future<void> _submitJob() async {
    if (_imageBytes == null || _fileName == null) {
      setState(() {
        _errorMessage = 'Primero elige una imagen.';
      });
      return;
    }

    final baseUrl = _normalizedBaseUrl;
    if (baseUrl == null) {
      setState(() {
        _errorMessage = 'Escribe una URL valida para la API.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _jobId = null;
      _jobStatus = null;
      _jobStartedAt = DateTime.now();
      _modelUrl = null;
      _thumbnailUrl = null;
      _progress = null;
      _viewerMessage = null;
      _statusText = 'Subiendo imagen al backend...';
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/v1/jobs'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'fileName': _fileName,
          'prompt': _promptController.text.trim(),
          'imageBase64': base64Encode(_imageBytes!),
        }),
      );

      final body = _decodeJson(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(body['error'] ?? 'La API devolvio ${response.statusCode}.');
      }

      final jobId = body['jobId'] as String?;
      if (jobId == null || jobId.isEmpty) {
        throw Exception('La API no devolvio un jobId.');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _jobId = jobId;
        _jobStatus = 'queued';
        _statusText = 'Trabajo creado. Consultando estado...';
      });

      await _startTracking(jobId, baseUrl);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = 'No pude enviar la imagen: $error';
        _jobStatus = 'failed';
        _statusText = 'Fallo la subida.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _startTracking(String jobId, String baseUrl) async {
    await _stopTracking();
    final streamStarted = await _startJobStream(jobId, baseUrl);
    if (!streamStarted) {
      _startPolling(jobId, baseUrl);
    }
  }

  Future<void> _stopTracking() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    await _jobStreamSubscription?.cancel();
    _jobStreamSubscription = null;
  }

  void _startPolling(String jobId, String baseUrl) {
    _pollingTimer?.cancel();

    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _fetchJobStatus(jobId, baseUrl);
    });

    unawaited(_fetchJobStatus(jobId, baseUrl));
  }

  Future<bool> _startJobStream(String jobId, String baseUrl) async {
    try {
      final request = http.Request(
        'GET',
        Uri.parse('$baseUrl/v1/jobs/$jobId/stream'),
      );
      final response = await http.Client().send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }

      String? currentEvent;
      final dataLines = <String>[];

      _jobStreamSubscription = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.startsWith('event:')) {
            currentEvent = line.substring(6).trim();
            return;
          }

          if (line.startsWith('data:')) {
            dataLines.add(line.substring(5).trimLeft());
            return;
          }

          if (line.isEmpty && dataLines.isNotEmpty) {
            final data = dataLines.join('\n');
            final eventName = currentEvent ?? 'message';
            dataLines.clear();
            currentEvent = null;
            _handleStreamEvent(eventName, data);
          }
        },
        onError: (_) {
          if (_jobId == jobId) {
            _startPolling(jobId, baseUrl);
          }
        },
        onDone: () {
          final doneStatus = _jobStatus;
          if (_jobId == jobId &&
              doneStatus != 'completed' &&
              doneStatus != 'failed') {
            _startPolling(jobId, baseUrl);
          }
        },
        cancelOnError: true,
      );

      return true;
    } catch (_) {
      return false;
    }
  }

  void _handleStreamEvent(String eventName, String data) {
    try {
      final body = _decodeJson(data);
      if (eventName == 'error') {
        if (!mounted) {
          return;
        }

        setState(() {
          _jobStatus = 'failed';
          _errorMessage = body['message'] as String? ?? 'Error en el stream.';
        });
        return;
      }

      final status = (body['status'] as String?) ?? 'unknown';
      final modelUrl = body['modelUrl'] as String?;
      final thumbnailUrl = body['thumbnailUrl'] as String?;
      final progress = body['progress'] as int?;

      if (!mounted) {
        return;
      }

      setState(() {
        _jobStatus = status;
        _statusText = _statusLabel(status, progress);
        _modelUrl = modelUrl;
        _thumbnailUrl = thumbnailUrl;
        _progress = progress;
        _viewerMessage = null;
      });

      if (status == 'completed' || status == 'failed') {
        unawaited(_stopTracking());
      }
    } catch (_) {
      // Ignore malformed partial events and continue listening.
    }
  }

  Future<void> _fetchJobStatus(String jobId, String baseUrl) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/v1/jobs/$jobId'));
      final body = _decodeJson(response.body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(body['error'] ?? 'No se pudo consultar el job.');
      }

      final status = (body['status'] as String?) ?? 'unknown';
      final modelUrl = body['modelUrl'] as String?;
      final thumbnailUrl = body['thumbnailUrl'] as String?;
      final progress = body['progress'] as int?;

      if (!mounted) {
        return;
      }

      setState(() {
        _jobStatus = status;
        _statusText = _statusLabel(status, progress);
        _modelUrl = modelUrl;
        _thumbnailUrl = thumbnailUrl;
        _progress = progress;
        _viewerMessage = null;
      });

      if (status == 'completed' || status == 'failed') {
        _pollingTimer?.cancel();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      _pollingTimer?.cancel();
      setState(() {
        _jobStatus = 'failed';
        _errorMessage = 'Error consultando el job: $error';
      });
    }
  }

  String _statusLabel(String status, int? progress) {
    switch (status) {
      case 'queued':
        return 'En cola. Esperando procesamiento...';
      case 'processing':
        final suffix = progress == null ? '' : ' ($progress%)';
        return 'Procesando imagen para convertirla en 3D...$suffix';
      case 'completed':
        return 'Modelo generado. Ya puedes verlo en la app.';
      case 'failed':
        return 'El backend marco el trabajo como fallido.';
      default:
        return 'Estado actual: $status';
    }
  }

  String? get _normalizedBaseUrl {
    final raw = _baseUrlController.text.trim();
    if (raw.isEmpty) {
      return null;
    }

    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  double? get _progressValue {
    final progress = _progress;
    if (progress == null) {
      return null;
    }

    return (progress.clamp(0, 100)) / 100;
  }

  Color _progressColor(ColorScheme colorScheme) {
    switch (_jobStatus) {
      case 'completed':
        return const Color(0xFF15803D);
      case 'failed':
        return colorScheme.error;
      case 'queued':
        return const Color(0xFF2563EB);
      case 'processing':
        return colorScheme.primary;
      default:
        return colorScheme.primary;
    }
  }

  String _progressHeadline() {
    switch (_jobStatus) {
      case 'completed':
        return 'Completado';
      case 'failed':
        return 'Error';
      case 'queued':
        return 'En cola';
      case 'processing':
        return _progress != null ? '${_progress!}%' : 'Procesando';
      default:
        return 'Listo para enviar';
    }
  }

  String _progressCaption() {
    switch (_jobStatus) {
      case 'completed':
        return 'Meshy termino de generar el modelo 3D.';
      case 'failed':
        return 'La generacion fallo. Revisa el mensaje de error.';
      case 'queued':
        return 'Meshy recibio la imagen y la puso en cola.';
      case 'processing':
        return _processingStageLabel();
      default:
        return 'Selecciona una imagen y enviala al backend.';
    }
  }

  String _processingStageLabel() {
    final progress = _progress;
    if (progress == null) {
      return 'Meshy esta preparando el trabajo...';
    }

    if (progress < 10) {
      return 'Meshy esta analizando la imagen base.';
    }

    if (progress < 35) {
      return 'Meshy esta levantando la geometria inicial.';
    }

    if (progress < 60) {
      return 'Meshy esta refinando la forma y el volumen.';
    }

    if (progress < 85) {
      return 'Meshy esta aplicando texturas y materiales.';
    }

    if (progress < 100) {
      return 'Meshy esta exportando y cerrando el modelo.';
    }

    return 'Meshy termino de generar el modelo 3D.';
  }

  String _elapsedLabel() {
    final startedAt = _jobStartedAt;
    if (startedAt == null) {
      return 'Tiempo transcurrido: 0s';
    }

    final elapsed = DateTime.now().difference(startedAt);
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;

    if (minutes > 0) {
      return 'Tiempo transcurrido: ${minutes}m ${seconds}s';
    }

    return 'Tiempo transcurrido: ${elapsed.inSeconds}s';
  }

  bool get _supportsEmbeddedViewer {
    if (kIsWeb) {
      return true;
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => true,
      TargetPlatform.iOS => true,
      TargetPlatform.macOS => true,
      TargetPlatform.fuchsia => false,
      TargetPlatform.linux => false,
      TargetPlatform.windows => false,
    };
  }

  Map<String, dynamic> _decodeJson(String responseBody) {
    if (responseBody.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    throw const FormatException('La respuesta no es un JSON valido.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Foto a 3D'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  SizedBox(
                    width: 420,
                    child: _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Fuente',
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Selecciona una foto y enviala al backend local.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: _baseUrlController,
                            decoration: const InputDecoration(
                              labelText: 'URL de la API',
                              hintText: 'http://localhost:8080',
                              border: OutlineInputBorder(),
                              helperText:
                                  'En emulador Android suele ser http://10.0.2.2:8080',
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _promptController,
                            minLines: 2,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: 'Prompt de textura',
                              hintText: 'wooden chair, high detail, realistic texture',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.tonalIcon(
                            onPressed: _isPicking ? null : _pickImage,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: Text(
                              _isPicking ? 'Abriendo selector...' : 'Elegir imagen',
                            ),
                          ),
                          const SizedBox(height: 20),
                          if (_fileName != null)
                            _InfoRow(label: 'Archivo', value: _fileName!),
                          _InfoRow(
                            label: 'Estado',
                            value: _statusText,
                          ),
                          if (_jobId != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              _progressHeadline(),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: _progressColor(theme.colorScheme),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 10,
                                value:
                                    _jobStatus == 'completed' ? 1 : _progressValue,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _progressColor(theme.colorScheme),
                                ),
                                backgroundColor: const Color(0xFFE5E7EB),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _progressCaption(),
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                          if (_jobId != null)
                            _InfoRow(label: 'Job ID', value: _jobId!),
                          if (_progress != null)
                            _InfoRow(label: 'Progreso', value: '$_progress%'),
                          if (_modelUrl != null)
                            Text(
                              'El modelo ya se cargo dentro de la vista previa.',
                              style: theme.textTheme.bodyMedium,
                            ),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              _errorMessage!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _isSubmitting ? null : _submitJob,
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text(
                                _isSubmitting ? 'Enviando...' : 'Enviar a convertir',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 460,
                    child: _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Vista previa',
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 16),
                          AspectRatio(
                            aspectRatio: 1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFD1FAE5),
                                    Color(0xFFEFF6FF),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: _buildPreview(theme),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _supportsEmbeddedViewer
                                ? 'Cuando Meshy termina, aqui se carga el `.glb` para rotarlo y hacer zoom.'
                                : 'El visor embebido no esta soportado en Windows por este paquete. Si quieres verlo dentro de la app, ejecuta `flutter run -d chrome`.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    if (_modelUrl != null) {
      if (kIsWeb) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ModelViewer(
            key: ValueKey(_modelUrl),
            src: _modelUrl!,
            alt: 'Modelo 3D generado',
            autoRotate: true,
            autoPlay: true,
            disableZoom: false,
            disableTap: false,
            cameraControls: true,
            backgroundColor: const Color(0xFFF8FAFC),
            loading: Loading.eager,
          ),
        );
      }

      if (_supportsEmbeddedViewer) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Flutter3DViewer(
            controller: _viewerController,
            src: _modelUrl!,
            activeGestureInterceptor: true,
            enableTouch: true,
            progressBarColor: theme.colorScheme.primary,
            onProgress: (double value) {
              if (!mounted) {
                return;
              }

              setState(() {
                _viewerMessage =
                    'Cargando visor 3D: ${(value * 100).round()}%';
              });
            },
            onLoad: (_) {
              if (!mounted) {
                return;
              }

              setState(() {
                _viewerMessage = 'Modelo 3D cargado en el visor.';
              });
            },
            onError: (String error) {
              if (!mounted) {
                return;
              }

              setState(() {
                _viewerMessage = 'El visor no pudo abrir el modelo: $error';
              });
            },
          ),
        );
      }

      return _UnsupportedViewer(
        modelUrl: _modelUrl!,
        thumbnailUrl: _thumbnailUrl,
        message:
            'El modelo ya existe, pero este visor embebido no funciona en Windows con el paquete elegido.',
      );
    }

    if (_imageBytes == null) {
      return const _EmptyPreview();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Image.memory(
            _imageBytes!,
            fit: BoxFit.cover,
          ),
        ),
        if (_jobId != null)
          Center(
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.68),
                borderRadius: BorderRadius.circular(20),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _progressHeadline(),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 10,
                        value: _jobStatus == 'completed' ? 1 : _progressValue,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _progressColor(theme.colorScheme),
                        ),
                        backgroundColor: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _progressCaption(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _elapsedLabel(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_viewerMessage != null && _jobId == null)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _viewerMessage!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: child,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodyMedium,
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.image_search_outlined,
            size: 64,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'Tu imagen aparecera aqui',
            style: theme.textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _UnsupportedViewer extends StatelessWidget {
  const _UnsupportedViewer({
    required this.modelUrl,
    required this.message,
    this.thumbnailUrl,
  });

  final String modelUrl;
  final String message;
  final String? thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (thumbnailUrl != null)
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.network(
                  thumbnailUrl!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                ),
              ),
            )
          else
            Icon(
              Icons.view_in_ar,
              size: 72,
              color: theme.colorScheme.primary,
            ),
          const SizedBox(height: 16),
          Text(
            message,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Prueba esta misma app en Chrome para tener visor integrado.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          SelectableText(
            modelUrl,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
