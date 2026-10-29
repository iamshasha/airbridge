package app.airbridge.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/** A newer AirBridge published on GitHub Releases. */
data class AppUpdate(
    val version: String,
    val notes: String,
    val pageUrl: String,
    /** This platform's download, if the release has one. */
    val downloadUrl: String?,
    val downloadSize: Long,
)

/** Checks github.com/iamshasha/airbridge for a newer release. Public repo, so no sign-in is needed. */
object UpdateChecker {
    const val LATEST_URL = "https://api.github.com/repos/iamshasha/airbridge/releases/latest"

    @Serializable
    private data class Release(
        @SerialName("tag_name") val tag: String,
        val body: String? = null,
        @SerialName("html_url") val page: String,
        val draft: Boolean = false,
        val prerelease: Boolean = false,
        val assets: List<Asset> = emptyList(),
    )

    @Serializable
    private data class Asset(val name: String, val size: Long, @SerialName("browser_download_url") val url: String)

    private val client by lazy { OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build() }

    /** Returns the latest release when it is newer than [current], or null when this is up to date. Blocking. */
    fun check(current: String, asset: String?, url: String = LATEST_URL): AppUpdate? {
        val request = Request.Builder().url(url)
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "AirBridge/$current")
            .build()
        client.newCall(request).execute().use { response ->
            if (response.code == 404) return null // no releases yet
            if (!response.isSuccessful) throw AirBridgeException(AirBridgeError.ProtocolViolation, "GitHub answered ${response.code}")
            return parse(response.body.string(), current, asset)
        }
    }

    fun parse(json: String, current: String, asset: String?): AppUpdate? {
        val release = WireJson.decodeFromString(Release.serializer(), json)
        if (release.draft || release.prerelease || !isNewer(release.tag, current)) return null
        val file = release.assets.firstOrNull { it.name == asset }
        return AppUpdate(normalized(release.tag), release.body.orEmpty(), release.page, file?.url, file?.size ?: 0)
    }

    private fun normalized(v: String) = v.removePrefix("v").removePrefix("V")

    /** Numeric comparison, part by part: 0.10.0 is newer than 0.9.2. */
    fun isNewer(candidate: String, current: String): Boolean {
        fun parts(v: String) = normalized(v).substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
        val a = parts(candidate)
        val b = parts(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    /** Automatic checks happen at most once a day. */
    fun isDue(lastCheckMillis: Long?, now: Long = System.currentTimeMillis()) =
        lastCheckMillis == null || now - lastCheckMillis > 24 * 3600 * 1000L

    /** Downloads [url] to [target], reporting progress 0..1. Blocking. */
    fun download(url: String, target: File, progress: (Float) -> Unit) {
        val request = Request.Builder().url(url).header("User-Agent", "AirBridge").build()
        OkHttpClient.Builder().readTimeout(60, TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw AirBridgeException(AirBridgeError.ProtocolViolation, "download failed (${response.code})")
            val body = response.body
            val total = body.contentLength()
            target.parentFile?.mkdirs()
            body.byteStream().use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(1 shl 16)
                    var done = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        done += n
                        if (total > 0) progress(done.toFloat() / total)
                    }
                }
            }
        }
    }
}
