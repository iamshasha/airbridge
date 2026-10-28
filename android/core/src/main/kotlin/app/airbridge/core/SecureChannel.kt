package app.airbridge.core

import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object FrameType {
    const val CONTROL: Byte = 1
    const val CHUNK: Byte = 2
}

/** Authenticated, encrypted channel over a [Wire] (PROTOCOL.md §2.2–2.3). Blocking. */
class SecureChannel private constructor(
    val wire: Wire,
    val peer: Hello,
    val isClient: Boolean,
    sendKey: ByteArray,
    recvKey: ByteArray,
    /** 6-digit pairing code both sides derive from the transcript. */
    val sas: String,
) : AutoCloseable {
    private val sendKey = SecretKeySpec(sendKey, "AES")
    private val recvKey = SecretKeySpec(recvKey, "AES")
    private val sendCipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val recvCipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val sendLock = Any()
    private var sendCounter = 0L
    private var recvCounter = 0L

    data class LocalInfo(val identity: DeviceIdentity, val name: String, val platform: String, val port: Int)

    class Frame(val type: Byte, val data: ByteArray, val offset: Int) {
        val length get() = data.size - offset
    }

    companion object {
        private val LABEL = "AirBridge/1".toByteArray()

        fun handshake(wire: Wire, local: LocalInfo, isClient: Boolean): SecureChannel {
            val eph = P256.generate()
            val hello = Hello(1, local.identity.id, local.name, local.platform, local.port,
                local.identity.publicKeyRaw, P256.raw(eph.public), P256.randomBytes(32))
            val myHello = WireJson.encodeToString(Hello.serializer(), hello).toByteArray()
            wire.sendFrame(myHello)
            val theirHello = wire.receiveFrame()

            val peer = try { WireJson.decodeFromString(Hello.serializer(), theirHello.decodeToString()) } catch (e: AirBridgeException) {
                throw e
            } catch (e: Exception) {
                throw AirBridgeException(AirBridgeError.ProtocolViolation, "bad hello")
            }
            if (peer.v != 1) throw AirBridgeException(AirBridgeError.ProtocolViolation, "unsupported version ${peer.v}")
            if (peer.id == local.identity.id) throw AirBridgeException(AirBridgeError.ProtocolViolation, "connected to self")

            val transcript = transcriptHash(if (isClient) myHello else theirHello, if (isClient) theirHello else myHello)
            wire.sendFrame(WireJson.encodeToString(Auth.serializer(), Auth(P256.sign(local.identity.keys.private, transcript))).toByteArray())
            val auth = try { WireJson.decodeFromString(Auth.serializer(), wire.receiveFrame().decodeToString()) } catch (e: AirBridgeException) {
                throw e
            } catch (e: Exception) {
                throw AirBridgeException(AirBridgeError.ProtocolViolation, "bad auth")
            }
            if (!P256.verify(peer.sigKey, transcript, auth.sig)) throw AirBridgeException(AirBridgeError.AuthenticationFailed)

            val shared = P256.agree(eph.private, peer.ephKey)
            val c2s = hkdf(shared, transcript, "AirBridge/1 c2s".toByteArray())
            val s2c = hkdf(shared, transcript, "AirBridge/1 s2c".toByteArray())
            return SecureChannel(wire, peer, isClient, if (isClient) c2s else s2c, if (isClient) s2c else c2s, sasCode(transcript))
        }

        internal fun transcriptHash(client: ByteArray, server: ByteArray): ByteArray {
            val cl = ByteArray(4).also { it.putU32(0, client.size.toLong()) }
            val sl = ByteArray(4).also { it.putU32(0, server.size.toLong()) }
            return sha256(LABEL, cl, client, sl, server)
        }

        internal fun sasCode(transcript: ByteArray): String {
            val digest = sha256("AirBridge/SAS".toByteArray(), transcript)
            return "%06d".format(digest.u32(0) % 1_000_000)
        }

        private fun nonce(counter: Long) = ByteArray(12).also { it.putU64(4, counter) }
    }

    // MARK: encrypted frames

    fun send(type: Byte, payload: ByteArray) {
        val plain = ByteArray(payload.size + 1)
        plain[0] = type
        payload.copyInto(plain, 1)
        sendPlaintext(plain)
    }

    /** [plain] must already start with the frame type byte. */
    fun sendPlaintext(plain: ByteArray) {
        // Sealing and writing under one lock keeps the nonce counter in wire order.
        synchronized(sendLock) {
            val frame = ByteArray(4 + plain.size + 16)
            frame.putU32(0, (plain.size + 16).toLong())
            sendCipher.init(Cipher.ENCRYPT_MODE, sendKey, GCMParameterSpec(128, nonce(sendCounter++)))
            sendCipher.doFinal(plain, 0, plain.size, frame, 4)
            wire.write(frame)
        }
    }

    /** Receives one frame. Only one reader per channel. */
    fun receive(): Frame {
        val body = wire.receiveFrame()
        if (body.size < 17) throw AirBridgeException(AirBridgeError.ProtocolViolation, "short frame")
        val plain = try {
            recvCipher.init(Cipher.DECRYPT_MODE, recvKey, GCMParameterSpec(128, nonce(recvCounter++)))
            recvCipher.doFinal(body)
        } catch (e: AEADBadTagException) {
            throw AirBridgeException(AirBridgeError.AuthenticationFailed)
        }
        if (plain[0] != FrameType.CONTROL && plain[0] != FrameType.CHUNK)
            throw AirBridgeException(AirBridgeError.ProtocolViolation, "unknown frame type")
        return Frame(plain[0], plain, 1)
    }

    fun send(message: ControlMessage) = send(FrameType.CONTROL, WireJson.encodeToString(ControlMessage.serializer(), message).toByteArray())

    fun receiveControl(): ControlMessage {
        val frame = receive()
        if (frame.type != FrameType.CONTROL) throw AirBridgeException(AirBridgeError.ProtocolViolation, "expected control frame")
        return try {
            WireJson.decodeFromString(ControlMessage.serializer(), frame.data.decodeToString(frame.offset, frame.data.size))
        } catch (e: Exception) {
            throw AirBridgeException(AirBridgeError.ProtocolViolation, "bad control message")
        }
    }

    override fun close() = wire.close()
}
