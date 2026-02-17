# Keep ML Kit Text Recognition classes
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

-keep class com.google.mlkit.vision.text.** { *; }

# ONNX Runtime
-keep class ai.onnxruntime.** { *; }
-keep class com.masicai.flutteronnxruntime.** { *; }

# Play Asset Delivery
-keep class com.google.android.play.core.assetpacks.** { *; }
