plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.yunha.remy"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.yunha.remy"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters.add("arm64-v8a") }
        // Shown on Evidence; keep in step with the litertlm-android dependency below.
        buildConfigField("String", "LITERT_LM_VERSION", "\"0.18.0\"")
    }
    buildFeatures { compose = true; buildConfig = true }
    buildTypes {
        // Debug-signed so the Release build installs on the bench Pixel without a keystore.
        release { signingConfig = signingConfigs.getByName("debug") }
    }
    // The hand landmarker task is the same pinned bundle the iPhone app ships.
    sourceSets["main"].assets.srcDir("../../iOS/Remy/Resources/HandLandmarker")
    sourceSets["main"].assets.srcDir("../../iOS/Remy/Resources/GestureRecognizer")
    // EfficientDet-Lite0 int8, the iPhone's MediaPipe object detector, fetched and verified by scripts/download_detector.py.
    sourceSets["main"].assets.srcDir("../../iOS/Remy/Resources/ObjectDetector")
    // LiteRT-LM and Google Tensor dispatch find native libraries in
    // context.applicationInfo.nativeLibraryDir, so extract them at install time.
    packaging { jniLibs { useLegacyPackaging = true } }
    androidResources { noCompress += listOf("litertlm", "tflite", "task") }
}

kotlin { jvmToolchain(21) }

// The knife box and the cup/bowl hot boxes are seeded from detector boxes; never ship a build without the detector.
val detectorModel = rootProject.file("../iOS/Remy/Resources/ObjectDetector/efficientdet_lite0.tflite")
if (!detectorModel.isFile || detectorModel.length() != 4602795L) {
    throw GradleException("Missing ${detectorModel.path} (EfficientDet-Lite0). Run: python3 scripts/download_detector.py from the repository root.")
}

dependencies {
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.0")
    implementation("com.google.ai.edge.litert:litert-npu-runtime-google-tensor:2.3.0")
    implementation("com.google.mediapipe:tasks-vision:0.10.21")
    // Package-label OCR with the bundled Latin model: runs on the phone, no download at run time.
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.activity:activity-compose:1.10.1")
    testImplementation("junit:junit:4.13.2")
    // Android's org.json is a stub in local unit tests; ItemBox.parse needs the real one there.
    testImplementation("org.json:json:20240303")
}
