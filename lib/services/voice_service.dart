import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'edge_tts_service.dart';
import 'settings_service.dart';

/// Voice interaction: native continuous speech-to-text for commands,
/// and high-quality studio text-to-speech for vocal responses.
class VoiceService {
  VoiceService._() {
    _initNativeSpeechChannel();
  }
  static final VoiceService instance = VoiceService._();

  static const MethodChannel _nativeSpeechChannel =
      MethodChannel('com.privateagent/speech');
  final FlutterTts _tts = FlutterTts();

  bool _speechReady = false;
  bool _ttsReady = false;
  bool _listening = false;
  bool _nativeReady = false;
  Completer<void>? _speakCompleter;
  Completer<bool>? _startCompleter;
  String? _lastError;

  final Map<Object, void Function(String, bool, List<String>)> _continuousHandlers =
      <Object, void Function(String, bool, List<String>)>{};
  final Map<Object, void Function(String, bool, List<String>)> _manualHandlers =
      <Object, void Function(String, bool, List<String>)>{};
  void Function(String, bool, List<String>)? _legacyContinuousHandler;
  void Function(String, bool, List<String>)? _legacyManualHandler;
  bool _manualSessionActive = false;
  bool _continuousSessionRequested = false;
  String? _activeLanguage;

  final ValueNotifier<bool> isSpeaking = ValueNotifier<bool>(false);
  final ValueNotifier<double> soundLevel = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> listeningNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> manualSessionActive = ValueNotifier<bool>(false);

  void Function(bool isListening)? onListeningChanged;
  void Function(String status)? onSpeechStatus;
  void Function(String message)? onSpeechError;
  void Function(String words, bool isFinal, List<String> candidates)? onSpeechResult;

  bool get _settingsSpeechEngineIsSystem => SettingsService.instance.speechEngine == 'system';
  bool get isListening => _listening;
  bool get isAvailable => _speechReady;
  String? get lastError => _lastError;
  bool get hasContinuousListeners =>
      _continuousHandlers.isNotEmpty || _legacyContinuousHandler != null;

  void _initNativeSpeechChannel() {
    _nativeSpeechChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onSystemSttResult':
          final args = call.arguments as Map?;
          final text = (args?['text'] ?? '').toString();
          final candidates = (args?['candidates'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
          if (text.isNotEmpty) _dispatchSpeechResult(text, true, candidates.isEmpty ? [text] : candidates);
          _nativeReady = false;
          _endManualSession();
          _setListening(false);
          _completeStart(true);
          break;
        case 'onSystemSttCancelled':
          _nativeReady = false;
          _endManualSession();
          _setListening(false);
          _completeStart(false);
          break;
        case 'onSpeechResult':
          final args = call.arguments as Map?;
          final text = (args?['text'] ?? '').toString();
          final isFinal = args?['isFinal'] == true;
          if (isFinal) _nativeReady = false;
          final candidates = (args?['candidates'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              (text.isNotEmpty ? [text] : <String>[]);
          if (text.isNotEmpty || candidates.isNotEmpty) {
            _dispatchSpeechResult(text, isFinal, candidates);
          }
          break;
        case 'onSpeechStatus':
          final status = call.arguments.toString();
          onSpeechStatus?.call(status);
          switch (status) {
            case 'listening':
              _lastError = null;
              _nativeReady = true;
              _setListening(true);
              _completeStart(true);
              break;
            case 'starting':
              _lastError = null;
              _nativeReady = false;
              break;
            case 'endOfSpeech':
              _nativeReady = false;
              break;
            case 'manualEnded':
              _nativeReady = false;
              _endManualSession();
              _setListening(false);
              _completeStart(false);
              break;
            case 'notListening':
              _nativeReady = false;
              _setListening(false);
              _endManualSession();
              _completeStart(false);
              break;
            case 'mediaActive':
              _lastError = 'Microphone is paused while media is playing';
              _nativeReady = false;
              _setListening(false);
              _endManualSession();
              _completeStart(false);
              break;
            case 'unavailable':
              _speechReady = false;
              _nativeReady = false;
              _lastError = 'Speech recognition is unavailable on this device';
              _setListening(false);
              _endManualSession();
              _completeStart(false);
              break;
            case 'permissionDenied':
              _nativeReady = false;
              _lastError = 'Microphone permission is required';
              _setListening(false);
              _endManualSession();
              _completeStart(false);
              break;
            default:
              if (status.startsWith('error:')) _nativeReady = false;
              break;
          }
          break;
        case 'onSpeechError':
          final args = call.arguments as Map?;
          final message =
              (args?['message'] ?? 'Speech recognition failed').toString();
          _nativeReady = false;
          _lastError = message;
          onSpeechError?.call(message);
          _completeStart(false);
          break;
        case 'onSoundLevel':
          final level = (call.arguments as num?)?.toDouble() ?? 0.0;
          soundLevel.value = level;
          break;
      }
    });
  }

  Future<bool> _ensureMicPermission() async {
    try {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      return status.isGranted;
    } catch (e) {
      debugPrint('[VoiceService] Microphone permission error: $e');
      return false;
    }
  }

  Future<bool> initSpeech() async {
    if (_speechReady) return true;
    if (!await _ensureMicPermission()) {
      _lastError = 'Microphone permission is required';
      return false;
    }
    try {
      final available =
          await _nativeSpeechChannel.invokeMethod<bool>('isAvailable') ?? false;
      _speechReady = available;
      if (!available) {
        _lastError = 'Speech recognition is unavailable on this device';
      }
    } catch (e) {
      debugPrint('[VoiceService] Speech availability check failed: $e');
      _speechReady = false;
      _lastError = 'Speech recognition is unavailable on this device';
    }
    return _speechReady;
  }

  Future<void> initTts({String? voiceProfile}) async {
    final profile = voiceProfile ?? SettingsService.instance.jarvisVoice;
    try {
      switch (profile) {
        case 'friday':
          await _tts.setLanguage('en-IE');
          await _tts.setPitch(1.05);
          await _tts.setSpeechRate(0.52);
          break;
        case 'stark':
          await _tts.setLanguage('en-US');
          await _tts.setPitch(0.95);
          await _tts.setSpeechRate(0.55);
          break;
        case 'kip':
          await _tts.setLanguage('en-GB');
          await _tts.setPitch(0.78);
          await _tts.setSpeechRate(0.48);
          break;
        case 'cortana':
          await _tts.setLanguage('en-US');
          await _tts.setPitch(1.10);
          await _tts.setSpeechRate(0.52);
          break;
        case 'paul':
        default:
          await _tts.setLanguage('en-GB');
          await _tts.setPitch(0.86);
          await _tts.setSpeechRate(0.48);

          try {
            final dynamic voices = await _tts.getVoices;
            if (voices is List && voices.isNotEmpty) {
              for (final v in voices) {
                if (v is Map) {
                  final name = (v['name'] ?? '').toString().toLowerCase();
                  final locale = (v['locale'] ?? '').toString().toLowerCase();
                  if (locale.contains('en-gb') || locale.contains('en_gb')) {
                    if (name.contains('gbd') ||
                        name.contains('gbb') ||
                        name.contains('male') ||
                        name.contains('-r-') ||
                        name.contains('language') && name.contains('b')) {
                      await _tts.setVoice({
                        'name': v['name'].toString(),
                        'locale': v['locale'].toString(),
                      });
                      break;
                    }
                  }
                }
              }
            }
          } catch (_) {}
          break;
      }

      await _tts.awaitSpeakCompletion(true);

      _tts.setStartHandler(() {
        isSpeaking.value = true;
      });
      _tts.setCompletionHandler(() {
        isSpeaking.value = false;
        if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
          _speakCompleter!.complete();
        }
      });
      _tts.setErrorHandler((_) {
        isSpeaking.value = false;
        if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
          _speakCompleter!.complete();
        }
      });
      _tts.setCancelHandler(() {
        isSpeaking.value = false;
        if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
          _speakCompleter!.complete();
        }
      });

      _ttsReady = true;
    } catch (_) {
      try {
        await _tts.setLanguage('en-US');
        _ttsReady = true;
      } catch (_) {
        _ttsReady = false;
      }
    }
  }

  /// Forces re-initialization of TTS with a new voice profile.
  Future<void> reconfigureVoice([String? profile]) async {
    _ttsReady = false;
    await initTts(voiceProfile: profile);
  }

  void _setListening(bool value) {
    if (_listening == value && listeningNotifier.value == value) return;
    _listening = value;
    listeningNotifier.value = value;
    onListeningChanged?.call(value);
  }

  void _completeStart(bool value) {
    final completer = _startCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(value);
    }
  }

  void _registerResultHandler({
    required bool continuous,
    required Object? owner,
    required void Function(String, bool, List<String>) handler,
  }) {
    if (continuous) {
      if (owner != null) {
        _continuousHandlers[owner] = handler;
      } else {
        _legacyContinuousHandler = handler;
        onSpeechResult = handler;
      }
    } else {
      if (owner != null) {
        _manualHandlers[owner] = handler;
      } else {
        _legacyManualHandler = handler;
        onSpeechResult = handler;
      }
      _setManualSessionActive(true);
    }
  }

  void _setManualSessionActive(bool value) {
    _manualSessionActive = value;
    if (manualSessionActive.value != value) {
      manualSessionActive.value = value;
    }
  }

  void _endManualSession() {
    final legacyManual = _legacyManualHandler;
    _setManualSessionActive(false);
    _manualHandlers.clear();
    _legacyManualHandler = null;
    if (legacyManual != null && identical(onSpeechResult, legacyManual)) {
      onSpeechResult = _legacyContinuousHandler;
    }
  }

  void _dispatchSpeechResult(
    String text,
    bool isFinal,
    List<String> candidates,
  ) {
    final handlers = <void Function(String, bool, List<String>)>{};
    if (_manualSessionActive) {
      handlers.addAll(_manualHandlers.values);
      final legacy = _legacyManualHandler;
      if (legacy != null) handlers.add(legacy);
    } else {
      handlers.addAll(_continuousHandlers.values);
      final legacy = _legacyContinuousHandler;
      if (legacy != null) handlers.add(legacy);
      final fieldHandler = onSpeechResult;
      if (fieldHandler != null) handlers.add(fieldHandler);
    }
    for (final handler in handlers) {
      try {
        handler(text, isFinal, candidates);
      } catch (e) {
        debugPrint('[VoiceService] Speech result handler failed: $e');
      }
    }
  }

  /// Removes a screen's speech handlers without touching global callbacks.
  void releaseResultHandler(Object owner) {
    _continuousHandlers.remove(owner);
    _manualHandlers.remove(owner);
  }

  String _messageForStartReason(String? reason) {
    switch (reason) {
      case 'mediaActive':
        return 'Microphone is paused while media is playing';
      case 'unavailable':
        return 'Speech recognition is unavailable on this device';
      case 'permissionDenied':
        return 'Microphone permission is required';
      default:
        return 'Speech recognition could not start';
    }
  }

  /// Starts native speech recognition and only succeeds once the engine
  /// confirms it is actually listening.
  /// [onResult] receives primary recognized words, isFinal, and N-best candidates.
  Future<bool> startListening({
    required void Function(String words, bool isFinal, List<String> candidates) onResult,
    bool continuous = true,
    bool manual = false,
    Object? owner,
    String? language,
  }) async {
    if (_settingsSpeechEngineIsSystem) {
      if (!await _ensureMicPermission()) return false;
      _registerResultHandler(continuous: false, owner: owner, handler: onResult);
      _completeStart(false);
      final raw = await _nativeSpeechChannel.invokeMethod<dynamic>('startSystemStt', <String, dynamic>{if (language != null && language.isNotEmpty) 'language': language});
      final response = raw is Map ? raw : const <Object?, Object?>{};
      if (response['accepted'] != true) {
        _endManualSession();
        _lastError = 'Android System STT is unavailable';
        return false;
      }
      return true;
    }
    if (!await initSpeech()) return false;

    // An explicit manual capture owns the microphone until it finishes. Do
    // not let a background continuous restart silently replace its handler.
    if (!manual && _manualSessionActive) return false;

    if (continuous) {
      _endManualSession();
    }
    _registerResultHandler(
      continuous: continuous,
      owner: owner,
      handler: onResult,
    );
    if (continuous && !manual) {
      _continuousSessionRequested = true;
      _activeLanguage = language;
    }

    if (_listening && _nativeReady && continuous && !manual && !_manualSessionActive) {
      return true;
    }

    _completeStart(false);
    final completer = Completer<bool>();
    _startCompleter = completer;

    try {
      final raw = await _nativeSpeechChannel.invokeMethod<dynamic>(
        'startListening',
        <String, dynamic>{
          'continuous': continuous,
          'manual': manual,
          if (language != null && language.isNotEmpty) 'language': language,
        },
      );
      final response = raw is Map ? raw : const <Object?, Object?>{};
      final accepted = response['accepted'] != false;
      final deferred = response['deferred'] == true;
      final alreadyListening = response['alreadyListening'] == true;
      final reason = response['reason']?.toString();

      if (!accepted || deferred) {
        if (continuous && !manual) _continuousSessionRequested = false;
        _nativeReady = false;
        _lastError = _messageForStartReason(reason);
        if (manual) _endManualSession();
        _completeStart(false);
        _startCompleter = null;
        return false;
      }

      if (alreadyListening) {
        _lastError = null;
        _nativeReady = true;
        _setListening(true);
        _completeStart(true);
        _startCompleter = null;
        return true;
      }

      final ready = await completer.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () {
          _lastError = 'Speech engine did not become ready';
          return false;
        },
      );
      if (!ready) {
        _nativeReady = false;
        debugPrint('[VoiceService] startListening not ready: $_lastError');
      }
      return ready;
    } catch (e) {
      debugPrint('[VoiceService] startListening error: $e');
      _nativeReady = false;
      _lastError = 'Speech recognition could not start';
      if (manual) _endManualSession();
      _setListening(false);
      _completeStart(false);
      return false;
    } finally {
      if (identical(_startCompleter, completer)) {
        _startCompleter = null;
      }
    }
  }

  /// Notifies the native audio engine that media/music playback has started
  /// so that speech recognition yields audio focus to YouTube/Spotify.
  Future<void> notifyMediaPlaybackStarted({Duration duration = const Duration(seconds: 45)}) async {
    try {
      await _nativeSpeechChannel.invokeMethod('notifyMediaStarted', {
        'durationMs': duration.inMilliseconds,
      });
    } catch (_) {}
  }

  /// Stops speech recognition immediately.
  Future<void> stopListening() async {
    _continuousSessionRequested = false;
    _endManualSession();
    _nativeReady = false;
    _setListening(false);
    _completeStart(false);
    try {
      await _nativeSpeechChannel.invokeMethod('stopListening');
    } catch (_) {}
  }

  /// Sanitizes text so speech synthesizers pronounce acronyms like Jarvis naturally
  /// instead of spelling out letters like "J dot A dot R dot V dot I dot S".
  String sanitizeForSpeech(String text) {
    return text
        .replaceAll(RegExp(r'J\.A\.R\.V\.I\.S\.?', caseSensitive: false), 'Jarvis')
        .replaceAll(RegExp(r'\bJ\.A\.R\.V\.I\.S\b', caseSensitive: false), 'Jarvis')
        .replaceAll(RegExp(r'J\s*\.\s*A\s*\.\s*R\s*\.\s*V\s*\.\s*I\s*\.\s*S\.?', caseSensitive: false), 'Jarvis')
        .replaceAll(RegExp(r'\bJARVIS\b'), 'Jarvis')
        .replaceAll('*', '')
        .replaceAll('#', '')
        .replaceAll('`', '')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
  }

  Future<void> speak(String text) async {
    final clean = sanitizeForSpeech(text);
    if (clean.isEmpty) return;

    // Pause microphone while speaking to eliminate echo and feedback. Keep the
    // user's continuous-session intent so it can resume after TTS completes.
    final resumeContinuous = _continuousSessionRequested;
    if (_listening || resumeContinuous) {
      await stopListening();
    }

    await stopSpeaking();
    isSpeaking.value = true;

    try {
      // 1. Try Ultra-Realistic Studio Neural Voice if enabled
      if (SettingsService.instance.useNeuralVoice) {
        try {
          final played = await EdgeTtsService.instance.speak(clean);
          if (played) {
            return;
          }
        } catch (e) {
          debugPrint('[VoiceService] Neural voice error, falling back to local TTS: $e');
        }
      }

      // 2. Fall back to local FlutterTts (offline safe)
      await initTts();
      if (!_ttsReady) {
        return;
      }
      try {
        _speakCompleter = Completer<void>();
        await _tts.speak(clean);
        // Wait for audio synthesis and speaker playback to finish completely
        await _speakCompleter?.future;
      } catch (_) {
      } finally {
        _speakCompleter = null;
      }
    } finally {
      isSpeaking.value = false;
      if (resumeContinuous) {
        _continuousSessionRequested = true;
        try {
          final raw = await _nativeSpeechChannel.invokeMethod<dynamic>(
            'startListening',
            <String, dynamic>{
              'continuous': true,
              'manual': false,
              if (_activeLanguage != null && _activeLanguage!.isNotEmpty)
                'language': _activeLanguage,
            },
          );
          final response = raw is Map ? raw : const <Object?, Object?>{};
          if (response['accepted'] == false || response['deferred'] == true) {
            _continuousSessionRequested = false;
            _lastError = 'Continuous listening could not resume after speaking';
          }
        } catch (e) {
          _continuousSessionRequested = false;
          _lastError = 'Continuous listening could not resume: $e';
          debugPrint('[VoiceService] Resume after TTS failed: $e');
        }
      }
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await EdgeTtsService.instance.stop();
      await _tts.stop();
      isSpeaking.value = false;
      if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
        _speakCompleter!.complete();
      }
    } catch (_) {}
  }
}
