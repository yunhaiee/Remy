package com.yunha.remy

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.camera2.CaptureRequest
import android.net.TrafficStats
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.yunha.remy.core.HazardWatch
import com.yunha.remy.core.HazardZone
import com.yunha.remy.core.Point2
import com.yunha.remy.ui.AgentActivity.Kind
import com.yunha.remy.ui.RemyScreen
import com.yunha.remy.ui.RemyState
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One screen, the two loops on Pixel, in the iPhone app's landscape layout: Gemma 4 E2B (LiteRT-LM, Tensor NPU when
 * verified) names and boxes what could be hot; MediaPipe hands (LiteRT) feed the HazardWatch port on every frame, with
 * no model call, and the pill shows the frame-to-alarm time. No voice input, recipes or tools.
 */
class MainActivity : ComponentActivity(), com.yunha.remy.ui.RemyActions {
    private val state = RemyState()
    private lateinit var preview: PreviewView
    private val analysis = Executors.newSingleThreadExecutor()
    private var landmarker: HandLandmarker? = null
    private val watch = HazardWatch().apply {
        // The iPhone cooker rule: any landmark or finger segment on the box for one second, held until the hand leaves.
        anyPartOverlap = true; minimumContactDuration = 1.0; holdsAlertUntilExit = true
    }
    @Volatile private var zones: List<HazardZone> = emptyList()
    @Volatile private var safetyOn = true
    @Volatile private var latestFrame: Bitmap? = null
    private var gemma: GemmaHazards? = null
    @Volatile private var scanning = false
    private var lastTimestampMs = 0L
    private var handFrames = 0
    private var handStart = 0L
    /** One hand request in flight, as on iPhone: a busy tracker drops frames instead of queueing them. */
    @Volatile private var handBusy = false
    @Volatile private var submittedAt = 0L
    private val reflex by lazy { ReflexAlarm(this, state) }
    private val trafficAtLaunch = TrafficStats.getUidRxBytes(Process.myUid()) + TrafficStats.getUidTxBytes(Process.myUid())

    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else state.line = "Allow the camera to watch the counter."
    }

    @OptIn(ExperimentalApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        setContent {
            RemyScreen(state, preview, this, session = { com.yunha.remy.ui.AppText("Tell me what we're making.", com.yunha.remy.ui.appText(androidx.compose.ui.unit.TextUnit(17f, androidx.compose.ui.unit.TextUnitType.Sp))) })
        }
        reflex.prepare()

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
            state.line = "Loading Gemma 4 E2B…"; state.working = true; state.isLoading = true; state.primaryTitle = "Loading Gemma…"
            val entry = state.activity.begin(Kind.GEMMA, "Loading Gemma 4 E2B")
            val loaded = runCatching { TensorLmLoader.load(this@MainActivity) }
            state.working = false; state.isLoading = false
            loaded.onSuccess { lm ->
                state.isLoaded = true; state.primaryTitle = "Plan ingredients"; state.status = "Say Remy, then what we're making."
                gemma = GemmaHazards(lm)
                val npu = lm.path == TensorLmLoader.Path.NPU
                state.onNpu = npu
                state.lmBackend = if (npu) "${Build.SOC_MODEL} NPU" else "CPU fallback"
                // The loader runs vision on the same backend as the language model.
                state.visionBackend = if (npu) "${Build.SOC_MODEL} NPU" else "CPU"
                state.loadMs = lm.loadTimeMs
                state.activity.finish(entry, "LiteRT-LM · ${state.lmBackend}" + (lm.npuError?.let { " · $it" } ?: ""), lm.loadTimeMs.toDouble())
                Log.i(TAG, "REMY_GEMMA loaded on ${state.lmBackend} in ${lm.loadTimeMs} ms")
                state.line = "Show me the counter."
                scanSoon()
            }.onFailure {
                state.lmBackend = "not loaded"
                state.activity.finish(entry, "Push the ${Build.SOC_MODEL.replace(' ', '_')} bundle over adb", failed = true)
                state.line = "Push the Gemma bundle, then reopen Remy."
                Log.e(TAG, "REMY_GEMMA load failed", it)
            }
        }
        lifecycleScope.launch {
            // Live evidence, refreshed every 2 s; nothing on screen is assumed.
            val power = getSystemService(PowerManager::class.java)
            var since = SystemClock.elapsedRealtime()
            while (true) {
                state.airplaneMode = Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
                state.thermalHeadroom = power?.getThermalHeadroom(10)
                val uid = Process.myUid()
                state.networkBytes = (TrafficStats.getUidRxBytes(uid) + TrafficStats.getUidTxBytes(uid) - trafficAtLaunch).coerceAtLeast(0)
                safetyOn = state.safetyAlerts
                if (!state.safetyAlerts && zones.isNotEmpty()) { zones = emptyList(); state.zones = emptyList(); clearAlarm() }
                // Retry the hot scan every 15 s while nothing hot is marked, as on iPhone.
                if (SystemClock.elapsedRealtime() - since > 15_000) { since = SystemClock.elapsedRealtime(); if (zones.isEmpty()) scanSoon() }
                delay(2_000)
            }
        }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            val selector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY).build()
            val previewUse = Preview.Builder().setResolutionSelector(selector).build().also { it.surfaceProvider = preview.surfaceProvider }
            // Hands track on a small frame (480p by default, as on iPhone); Settings can raise it to 720p.
            val height = state.handResolution
            val small = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(ResolutionStrategy(Size(height * 4 / 3, height), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)).build()
            val analysisBuilder = ImageAnalysis.Builder().setResolutionSelector(small)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            // Hold 30 fps; in dim light auto-exposure would otherwise halve the frame rate and double the reflex time.
            Camera2Interop.Extender(analysisBuilder).setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(30, 30))
            val analysisUse = analysisBuilder.build()
            analysisUse.setAnalyzer(analysis, ::analyze)
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, previewUse, analysisUse)
            state.videoOn = true
        }, ContextCompat.getMainExecutor(this))
    }

    override fun toggleMic() {
        if (!state.isLoaded) { state.settingsOpen = true; return }
        setHandsFree(!state.handsFree)
    }
    override fun setHandsFree(on: Boolean) { state.handsFree = on; state.listenerOn = on }
    override fun primary() { if (!state.isLoaded) state.settingsOpen = true else state.sessionOpen = true }
    override fun rescanHazards() = lookAgain()
    override fun setResolution(height: Int) { state.handResolution = height; startCamera() }
    override fun textTest() {}
    override fun describeCamera() {}
    override fun reset() {}

    override fun toggleVideo() {
        if (state.videoOn) {
            ProcessCameraProvider.getInstance(this).get().unbindAll()
            state.videoOn = false; state.hands = emptyList(); latestFrame = null; clearAlarm()
            state.line = "Video off."
        } else { startCamera(); state.line = "Show me the counter." }
    }

    private fun lookAgain() { zones = emptyList(); state.zones = emptyList(); watch.reset(); clearAlarm(); scanSoon() }

    /** Newest frame only: rotate upright, keep a copy for Gemma, hand it to MediaPipe with its capture time. */
    private fun analyze(image: ImageProxy) {
        image.use {
            if (handBusy) return
            val now = SystemClock.elapsedRealtimeNanos()
            // CameraX timestamps share the elapsed-realtime base on Pixels; fall back to receipt time otherwise.
            val captured = image.imageInfo.timestamp.takeIf { it in (now - 1_000_000_000L)..now } ?: now
            val raw = image.toBitmap()
            val rotation = image.imageInfo.rotationDegrees
            val upright = if (rotation == 0) raw else Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height,
                Matrix().apply { postRotate(rotation.toFloat()) }, true)
            latestFrame = upright
            val aspect = upright.width.toFloat() / upright.height
            if (aspect != state.imageAspect) runOnUiThread { state.imageAspect = aspect }
            val timestampMs = maxOf(captured / 1_000_000, lastTimestampMs + 1)
            lastTimestampMs = timestampMs
            handBusy = true
            submittedAt = SystemClock.elapsedRealtimeNanos()
            landmarker?.detectAsync(BitmapImageBuilder(upright).build(), timestampMs)
        }
    }

    /** The fast loop: geometry against Gemma's boxes on every hand frame, no model call. */
    private fun onHands(result: HandLandmarkerResult, input: MPImage) {
        handBusy = false
        val inferenceMs = (SystemClock.elapsedRealtimeNanos() - submittedAt) / 1e6
        val frameTime = result.timestampMs() / 1000.0
        val hands = result.landmarks().mapIndexed { index, points ->
            val category = result.handedness().getOrNull(index)?.firstOrNull()
            val name = category?.categoryName()?.lowercase() ?: "unknown"
            val id = if ((category?.score() ?: 0f) >= 0.7f && name in setOf("left", "right")) name else "unknown"
            HazardWatch.Hand(id, points.map { Point2(it.x().toDouble(), it.y().toDouble()) }, id != "unknown")
        }
        val now = SystemClock.elapsedRealtimeNanos() / 1e9
        val hit = if (safetyOn) watch.check(hands, zones, frameTime, now) else null
        val latency = (now - frameTime) * 1000
        if (handStart == 0L) handStart = SystemClock.elapsedRealtime()
        handFrames++
        val elapsed = SystemClock.elapsedRealtime() - handStart
        var fps: Double? = null
        if (elapsed > 2000) {
            fps = handFrames * 1000.0 / elapsed; handFrames = 0; handStart = SystemClock.elapsedRealtime()
            Log.i(TAG, String.format("REMY_HANDS %.1f fps, %d hands, landmarks %.0f ms, sensor to result %.0f ms", fps, hands.size, inferenceMs, latency))
        }
        runOnUiThread {
            if (!state.videoOn) return@runOnUiThread
            state.hands = hands.map { it.points }
            fps?.let { state.handFps = it; state.handMs = inferenceMs }
            if (hit != null && state.reflexMs == null) alarm(hit, latency)
            else if (hit == null && state.reflexMs != null) clearAlarm()
        }
    }

    private fun alarm(zone: HazardZone, latency: Double) = reflex.fire(zone, latency)

    private fun clearAlarm() {
        if (state.reflexMs == null) return
        reflex.clear()
        state.line = zones.firstOrNull()?.let { "Watching the ${it.label}." } ?: "Show me the counter."
    }

    private fun scanSoon() {
        val gemma = gemma ?: return
        if (scanning || !state.safetyAlerts) return
        val frame = latestFrame ?: return
        scanning = true; state.working = true
        state.line = "Looking for anything hot…"
        val entry = state.activity.begin(Kind.VISION, "What here is hot?", "hazards → locate with box_2d")
        lifecycleScope.launch {
            val jpeg = withContext(Dispatchers.Default) {
                ByteArrayOutputStream().also { frame.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
                    // The exact picture Gemma saw, for checking orientation and framing (adb pull, never uploaded).
                    .also { bytes -> runCatching { java.io.File(getExternalFilesDir(null), "last-scan.jpg").writeBytes(bytes) } }
            }
            val scan = withContext(Dispatchers.IO) { runCatching { gemma.scan(jpeg) } }
            scanning = false; state.working = false
            scan.onSuccess { s ->
                zones = s.zones; state.zones = s.zones
                watch.reset()
                val total = s.hazards.ms + (s.locate?.ms ?: 0)
                state.gemmaSeconds = total / 1000.0
                state.callMs.add(s.hazards.ms); s.locate?.let { state.callMs.add(it.ms) }
                while (state.callMs.size > 20) state.callMs.removeAt(0)
                s.hazards.prefillTps?.let { state.prefillTps = it }
                s.hazards.decodeTps?.let { state.decodeTps = it }
                s.hazards.ttft?.let { state.ttft = it }
                state.activity.finish(entry, "named: ${s.names.joinToString()} · boxed: ${s.zones.joinToString { it.label }.ifEmpty { "nothing" }}", total.toDouble())
                state.line = if (s.zones.isEmpty()) "Nothing hot in view." else "Watching the ${s.zones.first().label}."
                Log.i(TAG, "REMY_GEMMA hazards ${s.hazards.ms} ms \"${s.hazards.text}\" → ${s.names}; " +
                    "locate ${s.locate?.ms} ms \"${s.locate?.text}\" → ${s.zones.map { it.label }}; ${s.hazards.speed}")
            }.onFailure {
                state.activity.finish(entry, it.message ?: "failed", failed = true)
                state.line = "Gemma could not finish that look."
                Log.e(TAG, "REMY_GEMMA scan failed", it)
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        landmarker?.close(); analysis.shutdown(); reflex.shutdown()
    }

    companion object { private const val TAG = "Remy" }
}
