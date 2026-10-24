plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
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
    }
    // The hand landmarker task is the same pinned bundle the iPhone app ships.
    sourceSets["main"].assets.srcDir("../../iOS/Remy/Resources/HandLandmarker")
    // LiteRT-LM and Google Tensor dispatch find native libraries in
    // context.applicationInfo.nativeLibraryDir, so extract them at install time.
    packaging { jniLibs { useLegacyPackaging = true } }
    androidResources { noCompress += listOf("litertlm", "tflite", "task") }
}

kotlin { jvmToolchain(21) }

dependencies {
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.0")
    implementation("com.google.ai.edge.litert:litert-npu-runtime-google-tensor:2.3.0")
    implementation("com.google.mediapipe:tasks-vision:0.10.21")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    // Android's org.json is a stub in local unit tests; ItemBox.parse needs the real one there.
    testImplementation("org.json:json:20240303")
}
