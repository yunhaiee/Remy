package com.yunha.remy

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CaptureRequest
import android.net.TrafficStats
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.provider.MediaStore
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
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.android.gms.tasks.Tasks
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.components.containers.Category
import com.google.mediapipe.tasks.components.containers.Landmark
import com.google.mediapipe.tasks.components.containers.NormalizedLandmark
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.yunha.remy.core.HandPoint3
import com.yunha.remy.core.ItemBox
import com.yunha.remy.core.KnifeAssociation
import com.yunha.remy.core.KnifeCandidate
import com.yunha.remy.core.PackageIngredientLabel
import com.yunha.remy.core.Point2
import com.yunha.remy.ui.AgentActivity.Kind
import com.yunha.remy.ui.RemyScreen
import com.yunha.remy.ui.RemyState
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One landscape screen, the iPhone app's loops on a Pixel: Gemma 4 E2B (LiteRT-LM on the Tensor NPU) for the recipe,
 * voice, looks and the dish review; MediaPipe Gesture Recognizer hands and EfficientDet-Lite0 objects (LiteRT, CPU) feed
 * the fast safety loop on every frame with no model call.
 */
class MainActivity : ComponentActivity(), com.yunha.remy.ui.RemyActions, RemyModel.Host, SensorEventListener {
    private val state = RemyState()
    private lateinit var preview: PreviewView
    private val analysis = Executors.newSingleThreadExecutor()
    private val detection = Executors.newSingleThreadExecutor()
    /** MediaPipe Gesture Recognizer, as on iPhone: the same hand landmarks plus a gesture class, one model per frame. */
    private var recognizer: GestureRecognizer? = null
    private var detector: ObjectDetector? = null
    private val detectorBusy = AtomicBoolean(false)
    private var lastDetectorSubmit = 0.0
    private lateinit var model: RemyModel
    private lateinit var safety: SafetyLoop
    @Volatile private var latestFrame: Bitmap? = null
    @Volatile private var latestFrameAt = 0.0
    /** CameraService.ingredientFocus: no hand or object inference while ingredients are checked. */
    @Volatile private var ingredientFocus = false
    private var lastTimestampMs = 0L
    private var handFrames = 0
    private var handStart = 0L
    /** One hand request in flight, as on iPhone: a busy tracker drops frames instead of queueing them. */
    @Volatile private var handBusy = false
    @Volatile private var submittedAt = 0L
    @Volatile private var pendingFrameTime = 0.0
    @Volatile private var pendingAspect = 1.0
    private var cameraGeneration = 0
    private val textRecognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }
    private var sensors: SensorManager? = null
    private var referenceRotation: FloatArray? = null
    private val trafficAtLaunch = TrafficStats.getUidRxBytes(Process.myUid()) + TrafficStats.getUidTxBytes(Process.myUid())

    private val permission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        val camera = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        if (granted[Manifest.permission.CAMERA] == true) startCameraUse() else if (!camera) state.line = "Allow the camera to watch the counter."
        if (granted[Manifest.permission.RECORD_AUDIO] == true && state.handsFree && state.isLoaded) model.setHandsFree(true)
    }

    @OptIn(ExperimentalApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Landscape on iPhone hides the status bar and the home indicator; the video is full bleed.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        restoreSettings()
        model = RemyModel(this, state, lifecycleScope, this)
        safety = SafetyLoop(this, state, lifecycleScope, model)
        model.safety = safety
        safety.sessionChanged()
        ingredientFocus = model.session.phase == com.yunha.remy.core.CookingSession.Phase.INGREDIENTS
        model.restoreDishSummary()
        setContent {
            RemyScreen(state, preview, this, session = { com.yunha.remy.ui.SessionContent(state, model) }, model = model)
        }
        model.syncPrimary()

        recognizer = runCatching {
            GestureRecognizer.createFromOptions(this, GestureRecognizer.GestureRecognizerOptions.builder()
                .setBaseOptions(BaseOptions.builder().setModelAssetPath("gesture_recognizer.task").setDelegate(Delegate.CPU).build())
                .setRunningMode(RunningMode.LIVE_STREAM).setNumHands(2)
                .setMinHandDetectionConfidence(0.5f).setMinHandPresenceConfidence(0.5f).setMinTrackingConfidence(0.6f)
                .setResultListener { result, _ -> onHands(result.landmarks(), result.worldLandmarks(), result.handedness(), result.gestures(), result.timestampMs()) }
                .setErrorListener { error -> handBusy = false; Log.e(TAG, "REMY_HANDS error", error) }.build())
        }.onFailure { Log.e(TAG, "REMY_GESTURE recognizer unavailable", it) }.getOrNull()
        state.gestureModel = if (recognizer != null) "Gesture Recognizer · MediaPipe · LiteRT · CPU (thumbs up, thumbs down, open palm)" else "not available on this build"
        detector = runCatching {
            ObjectDetector.createFromOptions(this, ObjectDetector.ObjectDetectorOptions.builder()
                .setBaseOptions(BaseOptions.builder().setModelAssetPath("efficientdet_lite0.tflite").setDelegate(Delegate.CPU).build())
                .setRunningMode(RunningMode.IMAGE).setMaxResults(16).setScoreThreshold(0.25f).build())
        }.onFailure { Log.e(TAG, "REMY_DETECTOR unavailable", it) }.getOrNull()
        state.detectorModel = if (detector != null) "EfficientDet-Lite0 int8 · MediaPipe · LiteRT · CPU, up to 10 Hz" else "EfficientDet-Lite0 failed to load"
        Log.i(TAG, "REMY_DETECTOR ${state.detectorModel}")

        sensors = getSystemService(SensorManager::class.java)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera()
        val missing = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            .filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) permission.launch(missing.toTypedArray())

        lifecycleScope.launch {
            ExperimentalFlags.enableBenchmark = true
            state.status = "Loading Gemma on this Pixel…"; state.working = true; state.isLoading = true; state.primaryTitle = "Loading Gemma…"
            val loaded = runCatching { TensorLmLoader.load(this@MainActivity) }
            state.working = false; state.isLoading = false
            loaded.onSuccess { lm ->
                val npu = lm.path == TensorLmLoader.Path.NPU
                state.onNpu = npu
                state.lmBackend = if (npu) "${Build.SOC_MODEL} NPU" else "CPU fallback"
                // The loader runs vision on the same backend as the language model.
                state.visionBackend = if (npu) "${Build.SOC_MODEL} NPU" else "CPU"
                state.loadMs = lm.loadTimeMs
                model.attach(lm)
                Log.i(TAG, "REMY_GEMMA loaded on ${state.lmBackend} in ${lm.loadTimeMs} ms" + (lm.npuError?.let { " · $it" } ?: ""))
                model.syncPrimary()
            }.onFailure {
                state.lmBackend = "not loaded"
                state.activity.log(Kind.SYSTEM, "Gemma not loaded", "Push the ${Build.SOC_MODEL.replace(' ', '_')} bundle over adb")
                state.status = "Push the Gemma bundle, then reopen Remy."
                Log.e(TAG, "REMY_GEMMA load failed", it)
            }
        }
        lifecycleScope.launch {
            // Live evidence, refreshed every 2 s; nothing on screen is assumed.
            val power = getSystemService(PowerManager::class.java)
            while (true) {
                state.airplaneMode = Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
                state.thermalHeadroom = power?.getThermalHeadroom(10)
                val uid = Process.myUid()
                state.networkBytes = (TrafficStats.getUidRxBytes(uid) + TrafficStats.getUidTxBytes(uid) - trafficAtLaunch).coerceAtLeast(0)
                model.syncPrimary()
                delay(2_000)
            }
        }
        lifecycleScope.launch {
            // Session phase drives the ingredient focus (no hand or object inference while ingredients are checked).
            while (true) {
                val focus = model.session.phase == com.yunha.remy.core.CookingSession.Phase.INGREDIENTS
                if (focus != ingredientFocus) { ingredientFocus = focus; if (focus) runOnUiThread { state.hands = emptyList() } }
                delay(200)
            }
        }
    }

    /** The settings the iPhone keeps in UserDefaults/AppStorage survive a relaunch here too. */
    private fun restoreSettings() {
        val prefs = getSharedPreferences("settings", MODE_PRIVATE)
        state.shortRecipes = prefs.getBoolean("shortRecipes", true)
        state.demoPreset = prefs.getBoolean("demoPreset", true)
        state.objectBoxes = prefs.getBoolean("showObjectBoxes", true)
        state.safetyAlerts = prefs.getBoolean("safetyBoxesEnabled", true)
        state.knifeTracking = prefs.getBoolean("knifeTrackingEnabled", true)
        state.gestures = prefs.getBoolean("gestures", true)
        state.gripHints = prefs.getBoolean("fingerCurlHintsEnabled", true)
        com.yunha.remy.ui.GlassStyle.light = prefs.getString("glassStyle", "dark") == "light"
        lifecycleScope.launch {
            androidx.compose.runtime.snapshotFlow {
                listOf(state.shortRecipes, state.demoPreset, state.objectBoxes, state.safetyAlerts, state.knifeTracking, state.gestures,
                    state.gripHints, com.yunha.remy.ui.GlassStyle.light)
            }.collect { v ->
                prefs.edit().putBoolean("shortRecipes", v[0]).putBoolean("demoPreset", v[1]).putBoolean("showObjectBoxes", v[2])
                    .putBoolean("safetyBoxesEnabled", v[3]).putBoolean("knifeTrackingEnabled", v[4]).putBoolean("gestures", v[5])
                    .putBoolean("fingerCurlHintsEnabled", v[6]).putString("glassStyle", if (v[7]) "light" else "dark").apply()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        sensors?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)?.let { sensors?.registerListener(this, it, 250_000) }
    }

    override fun onPause() {
        super.onPause()
        sensors?.unregisterListener(this); referenceRotation = null
    }

    /** CameraService.startMotion: a turn of more than 0.14 rad since the reference means the camera moved. */
    override fun onSensorChanged(event: SensorEvent) {
        val rotation = FloatArray(9).also { SensorManager.getRotationMatrixFromVector(it, event.values) }
        val reference = referenceRotation ?: run { referenceRotation = rotation; return }
        val angles = FloatArray(3).also { SensorManager.getAngleChange(it, rotation, reference) }
        if (abs(angles[0]) + abs(angles[1]) + abs(angles[2]) > 0.14f) {
            referenceRotation = rotation
            if (state.videoOn) { Log.i(TAG, "REMY_CAMERA moved"); model.cameraMoved() }
        }
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun startCameraUse() {
        val generation = ++cameraGeneration
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            if (generation != cameraGeneration) return@addListener
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
            state.videoOn = true; referenceRotation = null
            model.syncPrimary()
        }, ContextCompat.getMainExecutor(this))
    }

    override fun toggleMic() {
        if (!state.isLoaded) { state.settingsOpen = true; return }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permission.launch(arrayOf(Manifest.permission.RECORD_AUDIO)); state.handsFree = true; return
        }
        setHandsFree(!state.handsFree)
    }
    override fun setHandsFree(on: Boolean) = model.setHandsFree(on)
    override fun primary() = model.primary()
    override fun rescanHazards() { lifecycleScope.launch { model.scanForHazards() } }
    override fun setResolution(height: Int) { state.handResolution = height; startCamera() }
    override fun textTest() { lifecycleScope.launch { model.textTest() } }
    override fun describeCamera() { lifecycleScope.launch { model.describeCamera() } }
    override fun reset() { model.reset() }

    // RemyModel.Host
    override fun latestJpeg(): ByteArray? {
        val frame = latestFrame ?: return null
        if (!state.videoOn || uptime() - latestFrameAt > 2) return null
        return ByteArrayOutputStream().also { frame.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
    }
    override fun dishStill(): ByteArray? {
        val frame = latestFrame ?: return null
        if (!state.videoOn || uptime() - latestFrameAt > 0.5) return null
        return ByteArrayOutputStream().also { frame.compress(Bitmap.CompressFormat.JPEG, 95, it) }.toByteArray()
    }
    override fun startCamera() = startCameraUse()
    override fun stopCamera() {
        cameraGeneration++
        ProcessCameraProvider.getInstance(this).get().unbindAll()
        state.videoOn = false; state.hands = emptyList(); latestFrame = null
        safety.invalidateGeometry(); safety.clearFingerFlexion(); state.automaticChecks = false
        model.syncPrimary()
    }

    /** Package-label OCR (VNRecognizeTextRequest on iPhone): ML Kit's bundled Latin model, on this phone, no network. */
    override suspend fun packageLabels(jpeg: ByteArray): List<RemyModel.PackageLabel> = withContext(Dispatchers.Default) {
        val bitmap = android.graphics.BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return@withContext emptyList()
        val text = Tasks.await(textRecognizer.process(InputImage.fromBitmap(bitmap, 0)))
        text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
            val food = PackageIngredientLabel.food(line.text) ?: return@mapNotNull null
            val box = line.boundingBox ?: return@mapNotNull null
            RemyModel.PackageLabel(food, line.confidence.toDouble(), box.exactCenterX() / bitmap.width.toDouble(), box.exactCenterY() / bitmap.height.toDouble())
        }.also { if (it.isNotEmpty()) Log.i(TAG, "REMY_OCR package labels ${it.map { l -> l.name + " " + l.confidence }}") }
    }

    override fun toggleVideo() {
        safety.clearCookerContactAlarm()
        if (state.videoOn) {
            stopCamera()
            state.status = "Video off."
        } else startCameraUse()
    }

    override fun saveDishSummary(bitmap: Bitmap) {
        lifecycleScope.launch {
            val saved = withContext(Dispatchers.IO) {
                runCatching {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, "Remy-${System.currentTimeMillis()}.png")
                        put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                        put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Remy")
                    }
                    val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: error("no media store")
                    contentResolver.openOutputStream(uri)?.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } ?: error("no stream")
                }.isSuccess
            }
            state.dishSummaryMessage = if (saved) "Summary saved to Photos." else "The summary couldn't be saved to Photos. Please try again."
        }
    }

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
            latestFrame = upright; latestFrameAt = captured / 1e9
            val aspect = upright.width.toFloat() / upright.height
            if (aspect != state.imageAspect) runOnUiThread { state.imageAspect = aspect }
            if (ingredientFocus) return
            submitObjects(upright, captured / 1e9)
            val timestampMs = maxOf(captured / 1_000_000, lastTimestampMs + 1)
            lastTimestampMs = timestampMs
            val recognizer = recognizer ?: return
            handBusy = true
            submittedAt = SystemClock.elapsedRealtimeNanos(); pendingFrameTime = captured / 1e9; pendingAspect = aspect.toDouble()
            recognizer.recognizeAsync(BitmapImageBuilder(upright).build(), timestampMs)
        }
    }

    /** FastObjectDetector.submit: one request in flight, 10 Hz (5 Hz when the phone is hot); busy frames are dropped. */
    private fun submitObjects(frame: Bitmap, time: Double) {
        val detector = detector ?: return
        val hot = (getSystemService(PowerManager::class.java)?.currentThermalStatus ?: 0) >= PowerManager.THERMAL_STATUS_SEVERE
        if (time - lastDetectorSubmit < 1.0 / (if (hot) 5.0 else 10.0) || !detectorBusy.compareAndSet(false, true)) return
        lastDetectorSubmit = time
        detection.execute {
            try {
                val started = SystemClock.elapsedRealtimeNanos()
                val result = detector.detect(BitmapImageBuilder(frame).build())
                val elapsed = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
                val w = frame.width.toDouble(); val h = frame.height.toDouble()
                fun box(d: com.google.mediapipe.tasks.components.containers.Detection): ItemBox? {
                    val name = d.categories().firstOrNull()?.categoryName()?.takeIf { it.isNotEmpty() } ?: return null
                    val r = d.boundingBox()
                    val left = r.left.coerceIn(0f, w.toFloat()); val top = r.top.coerceIn(0f, h.toFloat())
                    val right = r.right.coerceIn(0f, w.toFloat()); val bottom = r.bottom.coerceIn(0f, h.toFloat())
                    if (right <= left || bottom <= top) return null
                    return ItemBox(name, left / w, top / h, (right - left) / w, (bottom - top) / h)
                }
                val detections = result.detections()
                val boxes = detections.filter { (it.categories().firstOrNull()?.score() ?: 0f) >= 0.5f }.take(8).mapNotNull(::box)
                val knives = detections.filter { KnifeAssociation.isKnife(it.categories().firstOrNull()?.categoryName() ?: "") }
                    .mapNotNull { d -> box(d)?.let { KnifeCandidate(it, d.categories().first().score().toDouble()) } }
                val sample = ObjectSample(boxes, knives, time, w / h, elapsed)
                runOnUiThread { if (state.videoOn && uptime() - time < 0.5 && !ingredientFocus) safety.receiveObjects(sample) }
            } catch (e: Throwable) {
                // Detection is optional. A failed frame must not stop video or hand tracking.
                Log.e(TAG, "REMY_DETECTOR frame failed", e)
            } finally { detectorBusy.set(false) }
        }
    }

    /** The fast loop: geometry against located boxes on every hand frame, no model call. */
    private fun onHands(landmarks: List<List<NormalizedLandmark>>, world: List<List<Landmark>>, handedness: List<List<Category>>,
                        gestures: List<List<Category>>, timestamp: Long) {
        handBusy = false
        val inferenceMs = (SystemClock.elapsedRealtimeNanos() - submittedAt) / 1e6
        val frameTime = pendingFrameTime
        val now = uptime()
        // A late callback cannot trigger an alert using stale hand positions.
        if (now - frameTime >= 0.25) return
        val hands = landmarks.mapIndexedNotNull { index, points ->
            if (points.size != 21) return@mapIndexedNotNull null
            val p = points.map { Point2(it.x().toDouble(), it.y().toDouble()) }
            if (!p.all { it.isValid }) return@mapIndexedNotNull null
            val category = handedness.getOrNull(index)?.firstOrNull()
            val name = category?.categoryName()?.lowercase() ?: "unknown"
            // This camera is unmirrored. Identity only needs to stay consistent; low confidence cannot arm a track.
            val id = if ((category?.score() ?: 0f) >= 0.7f && name in setOf("left", "right")) name else "unknown"
            val top = gestures.getOrNull(index)?.firstOrNull()
            val gesture = top?.takeIf { it.score() >= 0.7f && it.categoryName() != "None" }?.categoryName()
            val geometry = world.getOrNull(index)?.map { HandPoint3(it.x().toDouble(), it.y().toDouble(), it.z().toDouble()) } ?: emptyList()
            TrackedHand(id, p, geometry, gesture)
        }
        if (handStart == 0L) handStart = SystemClock.elapsedRealtime()
        handFrames++
        val elapsed = SystemClock.elapsedRealtime() - handStart
        var fps: Double? = null
        if (elapsed > 2000) {
            fps = handFrames * 1000.0 / elapsed; handFrames = 0; handStart = SystemClock.elapsedRealtime()
            Log.i(TAG, String.format("REMY_HANDS %.1f fps, %d hands, landmarks %.0f ms, sensor to result %.0f ms", fps, hands.size, inferenceMs, (now - frameTime) * 1000))
        }
        val aspect = pendingAspect
        runOnUiThread {
            if (!state.videoOn || ingredientFocus) return@runOnUiThread
            safety.receive(hands, frameTime, aspect)
            fps?.let { state.handFps = it; state.handMs = inferenceMs }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        recognizer?.close(); detector?.close(); analysis.shutdown(); detection.shutdown(); safety.shutdown()
        model.listener.stop(); model.speaker.shutdown()
    }

    companion object { private const val TAG = "Remy" }
}
