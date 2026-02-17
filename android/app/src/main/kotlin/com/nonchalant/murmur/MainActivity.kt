package com.nonchalant.murmur

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.android.play.core.assetpacks.AssetPackManagerFactory
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nonchalant.murmur/assets"
    private val TAG = "MurmurAssets"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copyAssetToFiles" -> {
                        val assetName = call.argument<String>("assetName")
                        val destName = call.argument<String>("destName") ?: assetName
                        if (assetName == null || destName == null) {
                            result.error("INVALID_ARGS", "assetName is required", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val destFile = File(filesDir, destName)

                            // Skip copy if already exists and has content
                            if (destFile.exists() && destFile.length() > 0) {
                                Log.d(TAG, "$destName already cached (${destFile.length()} bytes)")
                                result.success(destFile.absolutePath)
                                return@setMethodCallHandler
                            }

                            // Try Play Asset Delivery first (release builds)
                            var copied = tryPadAsset(assetName, destFile)

                            // Fall back to regular Android assets (debug builds)
                            if (!copied) {
                                copied = tryAndroidAsset(assetName, destFile)
                            }

                            if (copied) {
                                Log.d(TAG, "Copied $assetName -> ${destFile.absolutePath} (${destFile.length()} bytes)")
                                result.success(destFile.absolutePath)
                            } else {
                                result.error("COPY_FAILED", "Could not find or copy $assetName", null)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Error copying $assetName", e)
                            result.error("COPY_FAILED", e.message, null)
                        }
                    }

                    "getFilePath" -> {
                        val fileName = call.argument<String>("fileName")
                        if (fileName == null) {
                            result.error("INVALID_ARGS", "fileName is required", null)
                            return@setMethodCallHandler
                        }

                        val file = File(filesDir, fileName)
                        if (file.exists() && file.length() > 0) {
                            result.success(file.absolutePath)
                        } else {
                            result.success(null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Try to copy from Play Asset Delivery install-time pack "modelAssets".
     */
    private fun tryPadAsset(assetName: String, destFile: File): Boolean {
        return try {
            val assetPackManager = AssetPackManagerFactory.getInstance(this)
            val packLocation = assetPackManager.getPackLocation("modelAssets")

            if (packLocation == null) {
                Log.d(TAG, "PAD: modelAssets pack not installed or not available")
                return false
            }

            val assetsPath = packLocation.assetsPath()
            val sourceFile = File(assetsPath, assetName)

            if (!sourceFile.exists()) {
                Log.d(TAG, "PAD: $assetName not found at ${sourceFile.absolutePath}")
                return false
            }

            Log.d(TAG, "PAD: Copying $assetName from ${sourceFile.absolutePath}")
            FileInputStream(sourceFile).use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output, bufferSize = 8192)
                }
            }

            destFile.length() > 0
        } catch (e: Exception) {
            Log.w(TAG, "PAD: Failed to read $assetName: ${e.message}")
            false
        }
    }

    /**
     * Try to copy from regular Android assets (works in debug builds).
     */
    private fun tryAndroidAsset(assetName: String, destFile: File): Boolean {
        return try {
            assets.open(assetName).use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output, bufferSize = 8192)
                }
            }
            Log.d(TAG, "Android assets: Copied $assetName (${destFile.length()} bytes)")
            destFile.length() > 0
        } catch (e: Exception) {
            Log.w(TAG, "Android assets: $assetName not found: ${e.message}")
            false
        }
    }
}
