package com.yunha.remy

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import android.hardware.camera2.CaptureRequest
import android.util.Range
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import android.util.Size
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.yunha.remy.core.HazardWatch
import com.yunha.remy.core.HazardZone
import com.yunha.remy.core.Point2
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One screen, the two loops on Pixel: Gemma 4 E2B (LiteRT-LM, Tensor NPU when verified) names and boxes what could be
 * hot; MediaPipe hands (LiteRT) feed the HazardWatch port on every frame, with no model call, and the pill shows the
 * frame-to-alarm time. No voice, recipes, drawer or tools.
 */
class MainActivity : ComponentActivity() {
    private lateinit var preview: PreviewView
    private lateinit var overlayView: OverlayView
    private val analysis = Executors.newSingleThreadExecutor()
    private var landmarker: HandLandmarker? = null
    private val watch = HazardWatch().apply {
        // The iPhone cooker rule: any landmark or finger segment on the box for one second, held until the hand leaves.
        anyPartOverlap = true; minimumContactDuration = 1.0; holdsAlertUntilExit = true
    }
    @Volatile private var zones: List<HazardZone> = emptyList()
    @Volatile private var latestFrame: Bitmap? = null
    private var gemma: GemmaHazards? = null
    private var engineLine = "Loading Gemma 4 E2B…"
    @Volatile private var scanning = false
    private var alarmActive = false
    private var lastTimestampMs = 0L
    private var handFrames = 0
    private var handStart = 0L
    private var handFps = 0.0
    @Volatile private var prepareMs = 0.0
    /** One hand request in flight, as on iPhone: a busy tracker drops frames instead of queueing them. */
    @Volatile private var handBusy = false
    @Volatile private var cameraFrames = 0
    @Volatile private var submittedAt = 0L
    @Volatile private var receivedAt = 0L
    private val tone by lazy { ToneGenerator(AudioManager.STREAM_ALARM, 80) }

    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else overlayView.line = "Allow the camera to watch the counter."
    }

    @OptIn(ExperimentalApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FIT_CENTER }
        overlayView = OverlayView(this)
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(android.graphics.Color.parseColor("#121317"))
            addView(preview, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(overlayView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        })
        // Tap to look again (the pot moved, or a new one is on the counter).
        overlayView.setOnClickListener { zones = emptyList(); watch.reset(); scanSoon() }

        landmarker = HandLandmarker.createFromOptions(this, HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("hand_landmarker.task").setDelegate(Delegate.CPU).build())
            .setRunningMode(RunningMode.LIVE_STREAM).setNumHands(2)
            .setMinHandDetectionConfidence(0.5f).setMinHandPresenceConfidence(0.5f).setMinTrackingConfidence(0.5f)
            .setResultListener(::onHands)
            .setErrorListener { error -> handBusy = false; Log.e(TAG, "REMY_HANDS error", error) }.build())

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera()
        else permission.launch(Manifest.permission.CAMERA)

        lifecycleScope.launch {
            ExperimentalFlags.enableBenchmark = true
            val loaded = runCatching { TensorLmLoader.load(this@MainActivity) }
            loaded.onSuccess { lm ->
                gemma = GemmaHazards(lm)
                engineLine = if (lm.path == TensorLmLoader.Path.NPU)
                    String.format("Gemma 4 E2B · LiteRT-LM · NPU (%s) · load %.1f s", android.os.Build.SOC_MODEL, lm.loadTimeMs / 1000.0)
                else String.format("Gemma 4 E2B · LiteRT-LM · CPU fallback · load %.1f s", lm.loadTimeMs / 1000.0)
                Log.i(TAG, "REMY_GEMMA $engineLine")
                overlayView.line = "Show me the counter."
                scanSoon()
            }.onFailure {
                engineLine = "Gemma not loaded: push the ${android.os.Build.SOC_MODEL.replace(' ', '_')} bundle"
                overlayView.line = "Push the Gemma bundle, then reopen Remy."
                Log.e(TAG, "REMY_GEMMA load failed", it)
            }
            refresh()
            // Retry the hot scan every 15 s while nothing hot is marked, as on iPhone.
            while (true) { delay(15_000); if (zones.isEmpty()) scanSoon() }
        }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            val selector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY).build()
            val previewUse = Preview.Builder().setResolutionSelector(selector).build().also { it.surfaceProvider = preview.surfaceProvider }
            // Hands track on a small frame (640x480), as on iPhone; full resolution only slows the reflex.
            val small = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)).build()
            val analysisBuilder = ImageAnalysis.Builder().setResolutionSelector(small)
            // Hold 30 fps; in dim light auto-exposure would otherwise halve the frame rate and double the reflex time.
            Camera2Interop.Extender(analysisBuilder).setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(30, 30))
            val analysisUse = analysisBuilder
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888).build()
            analysisUse.setAnalyzer(analysis, ::analyze)
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, previewUse, analysisUse)
            if (overlayView.line == "Starting the camera…") overlayView.line = engineLine.takeIf { gemma == null }?.let { "Loading Gemma…" } ?: "Show me the counter."
            refresh()
        }, ContextCompat.getMainExecutor(this))
    }

    /** Newest frame only: rotate upright, keep a copy for Gemma, hand it to MediaPipe with its capture time. */
    private fun analyze(image: ImageProxy) {
        image.use {
            cameraFrames++
            if (handBusy) return
            val now = SystemClock.elapsedRealtimeNanos()
            // CameraX timestamps share the elapsed-realtime base on Pixels; fall back to receipt time otherwise.
            val captured = image.imageInfo.timestamp.takeIf { it in (now - 1_000_000_000L)..now } ?: now
            val raw = image.toBitmap()
            val rotation = image.imageInfo.rotationDegrees
            val upright = if (rotation == 0) raw else Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height,
                Matrix().apply { postRotate(rotation.toFloat()) }, true)
            latestFrame = upright
            overlayView.imageAspect = upright.width.toFloat() / upright.height
            val timestampMs = maxOf(captured / 1_000_000, lastTimestampMs + 1)
            lastTimestampMs = timestampMs
            prepareMs = (SystemClock.elapsedRealtimeNanos() - now) / 1e6
            handBusy = true
            submittedAt = SystemClock.elapsedRealtimeNanos(); receivedAt = now
            landmarker?.detectAsync(BitmapImageBuilder(upright).build(), timestampMs)
        }
    }

    /** The fast loop: geometry against Gemma's boxes on every hand frame, no model call. */
    private fun onHands(result: HandLandmarkerResult, input: com.google.mediapipe.framework.image.MPImage) {
        handBusy = false
        val inferenceMs = (SystemClock.elapsedRealtimeNanos() - submittedAt) / 1e6
        val receiptMs = (SystemClock.elapsedRealtimeNanos() - receivedAt) / 1e6
        val frameTime = result.timestampMs() / 1000.0
        val hands = result.landmarks().mapIndexed { index, points ->
            val category = result.handedness().getOrNull(index)?.firstOrNull()
            val name = category?.categoryName()?.lowercase() ?: "unknown"
            val id = if ((category?.score() ?: 0f) >= 0.7f && name in setOf("left", "right")) name else "unknown"
            HazardWatch.Hand(id, points.map { Point2(it.x().toDouble(), it.y().toDouble()) }, id != "unknown")
        }
        val now = SystemClock.elapsedRealtimeNanos() / 1e9
        val hit = watch.check(hands, zones, frameTime, now)
        val latency = (now - frameTime) * 1000
        if (handStart == 0L) handStart = SystemClock.elapsedRealtime()
        handFrames++
        val elapsed = SystemClock.elapsedRealtime() - handStart
        if (elapsed > 2000) {
            handFps = handFrames * 1000.0 / elapsed; handFrames = 0; handStart = SystemClock.elapsedRealtime()
            Log.i(TAG, String.format("REMY_HANDS %.1f fps (camera %.1f fps), %d hands, landmarks %.0f ms, receipt to result %.0f ms, sensor to result %.0f ms",
                handFps, cameraFrames * 1000.0 / elapsed, hands.size, inferenceMs, receiptMs, latency))
            cameraFrames = 0
        }
        runOnUiThread {
            overlayView.hands = hands.map { it.points }
            if (hit != null && !alarmActive) {
                alarmActive = true
                overlayView.reflexMs = latency
                overlayView.line = "Hot: ${hit.label}. Hands back."
                Log.i(TAG, String.format("REMY_REFLEX hot %s %.0f ms after the frame", hit.label, latency))
                getSystemService(Vibrator::class.java)?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 180, 90, 180), -1))
                tone.startTone(ToneGenerator.TONE_PROP_BEEP2, 250)
            } else if (hit == null && alarmActive) {
                alarmActive = false
                overlayView.reflexMs = null
                overlayView.line = "Watching the ${zones.firstOrNull()?.label ?: "counter"}."
            }
            refresh()
        }
    }

    private fun scanSoon() {
        val gemma = gemma ?: return
        if (scanning) return
        val frame = latestFrame ?: return
        scanning = true
        overlayView.line = "Looking for anything hot…"; refresh()
        lifecycleScope.launch {
            val jpeg = withContext(Dispatchers.Default) {
                ByteArrayOutputStream().also { frame.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
            }
            val scan = withContext(Dispatchers.IO) { runCatching { gemma.scan(jpeg) } }
            scanning = false
            scan.onSuccess { s ->
                zones = s.zones; watch.reset()
                val seconds = (s.hazards.ms + (s.locate?.ms ?: 0)) / 1000.0
                overlayView.gemmaSeconds = seconds
                overlayView.line = if (s.zones.isEmpty()) "Nothing hot in view." else "Watching the ${s.zones.first().label}."
                lastCalls = String.format(" · hot %.1f s · box %.1f s", s.hazards.ms / 1000.0, (s.locate?.ms ?: 0) / 1000.0) +
                    (s.locate?.speed ?: s.hazards.speed)?.let { " · $it" }.orEmpty()
                Log.i(TAG, "REMY_GEMMA hazards ${s.hazards.ms} ms \"${s.hazards.text}\" → ${s.names}; " +
                    "locate ${s.locate?.ms} ms \"${s.locate?.text}\" → ${s.zones.map { it.label }}; ${s.hazards.speed}")
            }.onFailure {
                overlayView.line = "Gemma could not finish that look."
                Log.e(TAG, "REMY_GEMMA scan failed", it)
            }
            refresh()
        }
    }

    private var lastCalls = ""

    private fun refresh() {
        overlayView.zones = zones
        overlayView.evidence = engineLine + lastCalls + if (handFps > 0) String.format(" · hands %.0f fps (MediaPipe · LiteRT · CPU)", handFps) else ""
        overlayView.invalidate()
    }

    override fun onDestroy() {
        super.onDestroy()
        landmarker?.close(); analysis.shutdown()
    }

    companion object { private const val TAG = "Remy" }
}
