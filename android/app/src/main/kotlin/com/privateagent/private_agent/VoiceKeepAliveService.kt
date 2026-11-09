package com.privateagent.private_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import java.util.Locale

/**
 * Owns continuous speech recognition independently of MainActivity/Flutter.
 * This is a user-started, visible microphone foreground service.
 */
class VoiceKeepAliveService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var recognizer: SpeechRecognizer? = null
    private var running = false
    private var generation = 0
    private var languageTag: String? = null
    private var retryCount = 0
    private var retryRunnable: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopRecognition()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
                return START_NOT_STICKY
            }
            ACTION_START, null -> {
                languageTag = intent?.getStringExtra(EXTRA_LANGUAGE) ?: languageTag
                if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    publish(ACTION_ERROR, "Microphone permission is required", true)
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                startAsForeground()
                acquireWakeLock()
                running = true
                if (recognizer == null) scheduleRecognition(150L)
            }
            else -> return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun startAsForeground() {
        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 4101, openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0),
        )
        val notification = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }).setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("JARVIS listening service active")
            .setContentText("Microphone listening is enabled. Tap to open JARVIS.")
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "JARVIS voice session", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Visible notification while user-enabled microphone listening is active."
                setShowBadge(false)
            },
        )
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "JARVIS:VoiceSession").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun scheduleRecognition(delay: Long) {
        if (!running) return
        retryRunnable?.let { handler.removeCallbacks(it) }
        val task = Runnable { startRecognition() }
        retryRunnable = task
        handler.postDelayed(task, delay)
    }

    private fun startRecognition() {
        if (!running) return
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            publish(ACTION_ERROR, "Speech recognition service is unavailable", true)
            return
        }
        try {
            val currentGeneration = ++generation
            recognizer?.destroy()
            recognizer = SpeechRecognizer.createSpeechRecognizer(this).also { speech ->
                speech.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        if (!isCurrent(currentGeneration)) return
                        retryCount = 0
                        publish(ACTION_STATUS, "listening")
                    }
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {
                        if (isCurrent(currentGeneration)) publishLevel(rmsdB)
                    }
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {
                        if (isCurrent(currentGeneration)) publish(ACTION_STATUS, "endOfSpeech")
                    }
                    override fun onError(error: Int) {
                        if (!isCurrent(currentGeneration)) return
                        Log.w(TAG, "SpeechRecognizer error=$error")
                        publishError("Speech recognizer error: $error", false)
                        releaseRecognizer()
                        if (running) scheduleRecognition(retryDelay(error))
                    }
                    override fun onResults(results: Bundle?) {
                        if (!isCurrent(currentGeneration)) return
                        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: arrayListOf()
                        val best = matches.firstOrNull { containsWakeWord(it) } ?: matches.firstOrNull().orEmpty()
                        if (best.isNotBlank()) publishResult(best, true, matches)
                        releaseRecognizer()
                        if (running) scheduleRecognition(250L)
                    }
                    override fun onPartialResults(results: Bundle?) {
                        if (!isCurrent(currentGeneration)) return
                        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: arrayListOf()
                        val best = matches.firstOrNull().orEmpty()
                        if (best.isNotBlank()) publishResult(best, false, matches)
                    }
                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })
            }
            val locale = languageTag?.takeIf { it.isNotBlank() } ?: Locale.getDefault().toLanguageTag()
            val speechIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
            }
            publish(ACTION_STATUS, "starting")
            recognizer?.startListening(speechIntent)
        } catch (e: Exception) {
            Log.e(TAG, "Could not start recognition", e)
            publishError("Could not start speech recognition: ${e.message}", false)
            releaseRecognizer()
            if (running) scheduleRecognition(retryDelay(-1))
        }
    }

    private fun isCurrent(value: Int) = running && value == generation

    private fun retryDelay(error: Int): Long {
        retryCount = (retryCount + 1).coerceAtMost(6)
        val base = when (error) {
            SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> 30_000L
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
            SpeechRecognizer.ERROR_SERVER, SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> 2_000L
            else -> 600L
        }
        return (base * (1L shl (retryCount - 1))).coerceAtMost(30_000L)
    }

    private fun releaseRecognizer() {
        generation++
        try { recognizer?.cancel() } catch (_: Exception) {}
        try { recognizer?.destroy() } catch (_: Exception) {}
        recognizer = null
    }

    private fun stopRecognition() {
        running = false
        retryRunnable?.let { handler.removeCallbacks(it) }
        retryRunnable = null
        releaseRecognizer()
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wakeLock = null
        publish(ACTION_STATUS, "notListening")
    }

    private fun publish(action: String, value: String, fatal: Boolean = false) {
        sendBroadcast(Intent(action).setPackage(packageName).putExtra(EXTRA_VALUE, value).putExtra(EXTRA_FATAL, fatal))
    }

    private fun publishError(message: String, fatal: Boolean) = publish(ACTION_ERROR, message, fatal)

    private fun publishLevel(level: Float) {
        sendBroadcast(Intent(ACTION_LEVEL).setPackage(packageName).putExtra(EXTRA_LEVEL, level.toDouble()))
    }

    private fun containsWakeWord(text: String): Boolean {
        val value = text.lowercase(Locale.ROOT)
        return listOf("jarvis", "javis", "jervis", "jarves", "jarvice", "charvis", "travis", "service", "davis", "davies", "harvest", "jarvi", "google", "j.a.r.v.i.s").any { value.contains(it) }
    }

    private fun publishResult(text: String, isFinal: Boolean, candidates: ArrayList<String>) {
        sendBroadcast(
            Intent(ACTION_RESULT).setPackage(packageName)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_FINAL, isFinal)
                .putStringArrayListExtra(EXTRA_CANDIDATES, candidates),
        )
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Keep the explicitly enabled foreground voice session alive when the task is swiped away.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopRecognition()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_START = "com.privateagent.private_agent.action.START_VOICE_SESSION"
        const val ACTION_STOP = "com.privateagent.private_agent.action.STOP_VOICE_SESSION"
        const val ACTION_STATUS = "com.privateagent.private_agent.action.VOICE_STATUS"
        const val ACTION_RESULT = "com.privateagent.private_agent.action.VOICE_RESULT"
        const val ACTION_ERROR = "com.privateagent.private_agent.action.VOICE_ERROR"
        const val ACTION_LEVEL = "com.privateagent.private_agent.action.VOICE_LEVEL"
        const val EXTRA_LANGUAGE = "language"
        const val EXTRA_VALUE = "value"
        const val EXTRA_FATAL = "fatal"
        const val EXTRA_TEXT = "text"
        const val EXTRA_FINAL = "isFinal"
        const val EXTRA_CANDIDATES = "candidates"
        const val EXTRA_LEVEL = "level"
        private const val CHANNEL_ID = "jarvis_voice_session"
        private const val NOTIFICATION_ID = 4101
        private const val TAG = "JARVIS_VOICE_SERVICE"
    }
}
