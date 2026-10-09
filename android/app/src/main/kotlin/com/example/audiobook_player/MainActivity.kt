package com.example.audiobook_player

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
    }
    private var transcription: TranscriptionEngine? = null
    private val storageWorker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        transcription = TranscriptionEngine(flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.audiobook_player/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "resolveContentUri" -> {
                    val uriString = call.argument<String>("uri")
                    val displayName = call.argument<String>("name") ?: "audio"
                    if (uriString == null) {
                        result.error("bad_args", "uri is required", null)
                    } else {
                        storageWorker.execute {
                            try {
                                val resolved = resolveReadableUri(Uri.parse(uriString), displayName)
                                runOnUiThread { result.success(resolved) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("unreadable_uri", error.message, null) }
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        transcription?.dispose()
        storageWorker.shutdownNow()
        super.onDestroy()
    }

    private fun resolveReadableUri(uri: Uri, displayName: String): String? {
        val candidate = try { getRealPathFromUri(uri) } catch (_: Exception) { null }
        if (candidate != null) {
            try {
                FileInputStream(candidate).use { it.read() }
                return candidate
            } catch (_: Exception) { /* SAF access may still permit a stream copy. */ }
        }
        if (uri.scheme != "content") return null
        var name = displayName
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) name = it.getString(0) ?: name
            }
        } catch (_: Exception) { }
        name = name.substringAfterLast('/').replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").takeLast(160)
        val directory = File(filesDir, "picked/${UUID.randomUUID()}")
        require(directory.mkdirs()) { "Cannot create app-owned audio storage" }
        val copy = File(directory, ".import.partial")
        val destination = File(directory, name.ifEmpty { "audio" })
        try {
            val input = contentResolver.openInputStream(uri) ?: error("Provider did not supply a readable audio stream")
            input.use { source ->
                copy.outputStream().use { target ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        if (Thread.currentThread().isInterrupted) throw InterruptedException("URI copy cancelled")
                        val count = source.read(buffer)
                        if (count < 0) break
                        target.write(buffer, 0, count)
                    }
                    target.fd.sync()
                }
            }
            require(copy.renameTo(destination)) { "Cannot complete app-owned audio import" }
            return destination.path
        } catch (error: Exception) {
            copy.delete()
            directory.delete()
            throw error
        }
    }

    /**
     * Resolves a `content://` URI to its real filesystem path.
     *
     * file_picker returns a cache copy of a picked file, so subtitle sibling
     * lookup needs the original location. This covers the Storage Access
     * Framework document providers (external storage, downloads, media store)
     * plus plain `file://` URIs. Requires "All files access" on Android 11+
     * for the resulting path to be readable.
     */
    private fun getRealPathFromUri(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        if (uri.scheme != "content") return null

        val context = applicationContext

        if (DocumentsContract.isDocumentUri(context, uri)) {
            val docId = DocumentsContract.getDocumentId(uri)
            when (uri.authority) {
                "com.android.externalstorage.documents" -> {
                    val split = docId.split(":")
                    if (split.size < 2) return null
                    val type = split[0]
                    val path = split[1]
                    return if ("primary" == type) {
                        "${Environment.getExternalStorageDirectory()}/$path"
                    } else {
                        "/storage/$type/$path"
                    }
                }

                "com.android.providers.downloads.documents" -> {
                    if (docId.startsWith("raw:")) return docId.substring(4)
                    val id = docId.substringAfter(":").toLongOrNull() ?: return null
                    val contentUri: Uri? = if (
                        docId.startsWith("msf:") || docId.startsWith("msd:")
                    ) {
                        MediaStore.Files.getContentUri("external")
                    } else {
                        ContentUris.withAppendedId(
                            Uri.parse("content://downloads/public_downloads"),
                            id
                        )
                    }
                    if (contentUri == null) return null
                    return getDataColumn(context, contentUri, "_id=?", arrayOf(id.toString()))
                }

                "com.android.providers.media.documents" -> {
                    val split = docId.split(":")
                    if (split.size < 2) return null
                    val type = split[0]
                    val contentUri = when (type) {
                        "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                        "document" -> MediaStore.Files.getContentUri("external")
                        else -> null
                    } ?: return null
                    return getDataColumn(
                        context,
                        contentUri,
                        "_id=?",
                        arrayOf(split[1])
                    )
                }
            }
        } else if (uri.authority == "media") {
            return getDataColumn(context, uri, null, null)
        }

        return getDataColumn(context, uri, null, null)
    }

    private fun getDataColumn(
        context: Context,
        uri: Uri,
        selection: String?,
        selectionArgs: Array<String>?
    ): String? {
        var cursor: Cursor? = null
        try {
            cursor = context.contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DATA),
                selection,
                selectionArgs,
                null
            )
            if (cursor != null && cursor.moveToFirst()) {
                return cursor.getString(0)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resolve content URI $uri: $e")
        } finally {
            cursor?.close()
        }
        return null
    }
}
