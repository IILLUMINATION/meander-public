package com.IILLUMINAT.meadner

import android.net.Uri
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import io.flutter.FlutterInjector
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val FILE_RESOLVER_CHANNEL = "meander/file_resolver"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        Log.i("MainActivity", "onCreate() called")
        
        // Fallback: ensure Flutter is initialized before calling super.onCreate()
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            Log.i("MainActivity", "FlutterLoader check: initialized=${loader.initialized()}")
            
            if (!loader.initialized()) {
                Log.w("MainActivity", "Flutter NOT initialized in Application! Initializing now...")
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
                Log.i("MainActivity", "Flutter initialization completed in MainActivity")
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "Flutter initialization check failed", e)
        }
        
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        // Прошивки вроде MIUI сбрасывают режим окна при возврате из фона.
        DisplayRefreshRate.apply(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        registerFilePickerPlugin(flutterEngine)
        OfflineApkBuilder.register(flutterEngine.dartExecutor.binaryMessenger, this)
        DisplayRefreshRate.register(flutterEngine.dartExecutor.binaryMessenger, this)
        DisplayRefreshRate.apply(this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_RESOLVER_CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method != "resolveSharedFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val uriRaw = call.argument<String>("uri")
            if (uriRaw.isNullOrBlank()) {
                result.error("invalid_args", "URI is missing", null)
                return@setMethodCallHandler
            }

            try {
                val path = resolveSharedFileUri(Uri.parse(uriRaw))
                if (path == null) {
                    result.error("resolve_failed", "Failed to resolve shared file URI", null)
                } else {
                    result.success(path)
                }
            } catch (e: Exception) {
                result.error("resolve_exception", e.message, null)
            }
        }
    }

    private fun registerFilePickerPlugin(flutterEngine: FlutterEngine) {
        try {
            val clazz = Class.forName("com.mr.flutter.plugin.filepicker.FilePickerPlugin")
            val plugin =
                clazz.getDeclaredConstructor().newInstance() as io.flutter.embedding.engine.plugins.FlutterPlugin
            flutterEngine.plugins.add(plugin)
        } catch (e: Exception) {
            Log.w("MainActivity", "FilePicker plugin not registered: ${e.message}")
        }
    }

    private fun resolveSharedFileUri(uri: Uri): String? {
        return when (uri.scheme?.lowercase()) {
            "file" -> uri.path
            "content" -> copyContentUriToCache(uri)
            else -> null
        }
    }

    private fun copyContentUriToCache(uri: Uri): String? {
        val resolver = contentResolver
        val fileName = buildFileName(uri)
        val target = File(cacheDir, fileName)

        val input = resolver.openInputStream(uri) ?: return null
        val output = FileOutputStream(target)
        try {
            input.copyTo(output)
            output.flush()
        } finally {
            try {
                input.close()
            } catch (_: Exception) {
                // ignore
            }
            try {
                output.close()
            } catch (_: Exception) {
                // ignore
            }
        }

        return target.absolutePath
    }

    private fun buildFileName(uri: Uri): String {
        val baseName = uri.lastPathSegment
            ?.substringAfterLast('/')
            ?.substringAfterLast(':')
            ?.ifBlank { null }
            ?: "shared_import_${System.currentTimeMillis()}.mnd"

        return if (baseName.endsWith(".mnd", ignoreCase = true)) {
            baseName
        } else {
            "${baseName}.mnd"
        }
    }
}
