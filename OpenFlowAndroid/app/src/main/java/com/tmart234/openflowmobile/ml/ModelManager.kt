package com.tmart234.openflowmobile.ml

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * Owns the lifecycle of the active [ModelBundle]: load cached or bundled
 * fallback at startup, then check GitHub releases for a newer
 * model-YYYY.MM.DD and swap in when one is found.
 */
class ModelManager(
    private val context: Context,
    private val client: OkHttpClient = OkHttpClient(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    sealed interface State {
        object Idle : State
        object LoadingFromCache : State
        data class CheckingForUpdate(val currentVersion: String?) : State
        data class Downloading(val version: String) : State
        data class Ready(val version: String) : State
        object NotAvailable : State
        data class Error(val message: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _bundle = MutableStateFlow<ModelBundle?>(null)
    val bundle: StateFlow<ModelBundle?> = _bundle.asStateFlow()

    private val modelsDir: File = File(context.filesDir, "openflow-models").apply { mkdirs() }
    private val releasesUrl = "https://api.github.com/repos/tmart234/OpenFlow/releases"
    private val modelTagPrefix = "model-"

    /**
     * Load the latest cached bundle (or bundled fallback if present), then
     * check for updates async. Idempotent.
     */
    fun bootstrap() {
        scope.launch {
            _state.value = State.LoadingFromCache
            val loaded = loadCached() ?: loadBundledFallback()
            if (loaded != null) {
                swap(loaded)
                _state.value = State.Ready(loaded.version)
            } else {
                _state.value = State.NotAvailable
            }
            checkForUpdate()
        }
    }

    suspend fun checkForUpdate() {
        val resumeState = _state.value
        _state.value = State.CheckingForUpdate(_bundle.value?.version)
        try {
            val releases = fetchModelReleases()
            val latest = releases.firstOrNull()
            if (latest == null) {
                _state.value = if (_bundle.value == null) State.NotAvailable else resumeState
                return
            }
            if (_bundle.value?.version == latest.tagName) {
                _state.value = resumeState
                return
            }
            downloadAndInstall(latest)
            val updated = loadCached()
            if (updated != null) {
                swap(updated)
                _state.value = State.Ready(updated.version)
            } else {
                _state.value = State.Error("Downloaded ${latest.tagName} but could not load it")
            }
        } catch (t: Throwable) {
            _state.value = if (_bundle.value != null) resumeState
            else State.Error("Update check failed: ${t.message ?: t::class.simpleName}")
        }
    }

    private fun swap(newBundle: ModelBundle) {
        _bundle.value?.close()
        _bundle.value = newBundle
    }

    // region Local sources

    private fun loadCached(): ModelBundle? {
        val pointer = File(modelsDir, "current.txt")
        if (!pointer.exists()) return null
        val version = pointer.readText().trim().takeIf { it.isNotEmpty() } ?: return null
        val dir = File(modelsDir, version)
        if (!dir.isDirectory) return null
        return runCatching { ModelBundle.load(dir) }.getOrNull()
    }

    /**
     * Loads a model bundle shipped in assets/openflow-model/. Phase 1 ships
     * nothing here - populated when the first model-YYYY.MM.DD release is
     * snapshotted into the APK. Returns null if absent.
     */
    private suspend fun loadBundledFallback(): ModelBundle? = withContext(Dispatchers.IO) {
        val assets = context.assets
        val files = runCatching { assets.list("openflow-model")?.toSet() }.getOrNull() ?: return@withContext null
        val required = setOf(
            "manifest.json", "training_config.json", "scalers.json",
            "station_index.json", "basin_index.json", "lstm_model.tflite",
        )
        if (!files.containsAll(required)) return@withContext null

        val fallbackDir = File(modelsDir, "bundled")
        fallbackDir.mkdirs()
        for (name in required) {
            val target = File(fallbackDir, name)
            if (!target.exists()) {
                assets.open("openflow-model/$name").use { input ->
                    target.outputStream().use { input.copyTo(it) }
                }
            }
        }
        runCatching { ModelBundle.load(fallbackDir) }.getOrNull()
    }

    // endregion

    // region Remote

    private suspend fun fetchModelReleases(): List<GHRelease> = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url(releasesUrl)
            .header("Accept", "application/vnd.github+json")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw ModelManagerException("HTTP ${resp.code} fetching releases")
            val body = resp.body?.string().orEmpty()
            jsonParser.decodeFromString<List<GHRelease>>(body)
                .filter { it.tagName.startsWith(modelTagPrefix) && !it.draft && !it.prerelease }
                // ISO8601 strings sort lexicographically.
                .sortedByDescending { it.createdAt }
        }
    }

    private suspend fun downloadAndInstall(release: GHRelease) = withContext(Dispatchers.IO) {
        _state.value = State.Downloading(release.tagName)
        val targetDir = File(modelsDir, release.tagName).apply {
            if (exists()) deleteRecursively()
            mkdirs()
        }

        val manifestAsset = release.assets.firstOrNull { it.name == "manifest.json" }
            ?: throw ModelManagerException("Release missing manifest.json")
        val manifestBytes = downloadBytes(manifestAsset.browserDownloadUrl)
        File(targetDir, "manifest.json").writeBytes(manifestBytes)
        val manifest = jsonParser.decodeFromString(Manifest.serializer(), String(manifestBytes))

        val assetsByName = release.assets.associateBy { it.name }
        for (file in manifest.files) {
            if (file.name == "manifest.json") continue
            val asset = assetsByName[file.name]
                ?: throw ModelManagerException("Release missing asset: ${file.name}")
            val data = downloadBytes(asset.browserDownloadUrl)
            verifySha256(data, file.sha256, file.name)
            File(targetDir, file.name).writeBytes(data)
        }

        // The TFLite path is a single file - nothing to unzip there. The .mlpackage
        // zip is iOS-only but we still tolerate it if present.
        val zip = File(targetDir, "lstm_model.mlpackage.zip")
        if (zip.exists()) {
            unzipInto(zip, targetDir)
        }

        File(modelsDir, "current.txt").writeText(release.tagName)
    }

    private fun downloadBytes(url: String): ByteArray {
        val req = Request.Builder().url(url).build()
        return client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw ModelManagerException("HTTP ${resp.code} for $url")
            resp.body?.bytes() ?: throw ModelManagerException("Empty body for $url")
        }
    }

    private fun verifySha256(data: ByteArray, expected: String, name: String) {
        val actual = MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it) }
        if (!actual.equals(expected, ignoreCase = true)) {
            throw ModelManagerException(
                "SHA256 mismatch on $name (expected ${expected.take(12)}..., got ${actual.take(12)}...)"
            )
        }
    }

    private fun unzipInto(zip: File, dir: File) {
        ZipInputStream(zip.inputStream()).use { zin ->
            var entry = zin.nextEntry
            while (entry != null) {
                val out = File(dir, entry.name)
                if (entry.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    out.outputStream().use { zin.copyTo(it) }
                }
                zin.closeEntry()
                entry = zin.nextEntry
            }
        }
    }

    // endregion

    companion object {
        private val jsonParser = Json { ignoreUnknownKeys = true }
    }
}

class ModelManagerException(message: String) : RuntimeException(message)

@Serializable
private data class GHRelease(
    @SerialName("tag_name") val tagName: String,
    @SerialName("created_at") val createdAt: String,
    val draft: Boolean = false,
    val prerelease: Boolean = false,
    val assets: List<GHAsset> = emptyList(),
)

@Serializable
private data class GHAsset(
    val name: String,
    @SerialName("browser_download_url") val browserDownloadUrl: String,
)
