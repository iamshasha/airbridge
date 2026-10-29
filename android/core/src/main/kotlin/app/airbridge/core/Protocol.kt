package app.airbridge.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.Transient
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.util.Base64

enum class AirBridgeError { ConnectionClosed, ConnectFailed, ProtocolViolation, AuthenticationFailed, Declined, NotTrusted, Timeout }

/** Errors surfaced by the engine. Mirrors AirBridgeError in the Swift core. */
class AirBridgeException(val kind: AirBridgeError, val detail: String? = null) : Exception(describe(kind, detail)) {
    companion object {
        private fun describe(kind: AirBridgeError, detail: String?) = when (kind) {
            AirBridgeError.ConnectionClosed -> "Connection closed"
            AirBridgeError.ConnectFailed -> "Could not connect: $detail"
            AirBridgeError.ProtocolViolation -> "Protocol error: $detail"
            AirBridgeError.AuthenticationFailed -> "Device authentication failed"
            AirBridgeError.Declined -> if (detail.isNullOrEmpty()) "Declined" else "Declined: $detail"
            AirBridgeError.NotTrusted -> "The other device is no longer paired with this one. Pair again to continue."
            AirBridgeError.Timeout -> "Timed out"
        }
    }
}

/** Byte arrays travel as standard base64, like Swift's `Data`. */
object Base64Bytes : KSerializer<ByteArray> {
    override val descriptor = PrimitiveSerialDescriptor("Base64Bytes", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(Base64.getEncoder().encodeToString(value))
    override fun deserialize(decoder: Decoder): ByteArray =
        try { Base64.getDecoder().decode(decoder.decodeString()) } catch (e: IllegalArgumentException) {
            throw AirBridgeException(AirBridgeError.ProtocolViolation, "bad base64")
        }
}

/** Handshake hello (PROTOCOL.md §2.2). */
@Serializable
data class Hello(
    val v: Int,
    val id: String,
    val name: String,
    val platform: String,
    val port: Int,
    @Serializable(with = Base64Bytes::class) val sigKey: ByteArray,
    @Serializable(with = Base64Bytes::class) val ephKey: ByteArray,
    @Serializable(with = Base64Bytes::class) val nonce: ByteArray,
) {
    @Transient val fingerprint: String = DeviceIdentity.fingerprintOf(sigKey)
}

@Serializable
internal data class Auth(@Serializable(with = Base64Bytes::class) val sig: ByteArray)

/** Flat control message (PROTOCOL.md §3); unused fields are omitted on the wire. */
@Serializable
data class ControlMessage(
    val t: String,
    val transferId: String? = null,
    val items: List<FileItem>? = null,
    val total: Long? = null,
    val streams: Int? = null,
    val sync: Boolean? = null,
    val text: String? = null,
    val path: String? = null,
    val paths: List<String>? = null,
    val entries: List<RemoteEntry>? = null,
    val reason: String? = null,
    /** `speedtest`: "upload" (client sends) or "download" (server sends). */
    val mode: String? = null,
) {
    companion object {
        fun error(reason: String) = ControlMessage("error", reason = reason)
        val notPaired get() = ControlMessage("notPaired", reason = "This device is not paired")
    }
}

@Serializable
data class FileItem(val i: Int, val path: String, val size: Long, val dir: Boolean? = null) {
    val isDirectory get() = dir == true
}

@Serializable
data class RemoteEntry(val name: String, val size: Long, val dir: Boolean)

internal val WireJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
}

/** "Holiday Photos" for one folder, "3 files" otherwise. */
internal fun titleOf(items: List<FileItem>): String {
    val tops = items.map { it.path.substringBefore('/') }.distinct()
    return if (tops.size == 1) tops[0] else "${items.count { !it.isDirectory }} files"
}
