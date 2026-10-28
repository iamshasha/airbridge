package app.airbridge.core

import kotlinx.serialization.Serializable
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.UUID
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * P-256 primitives in the formats CryptoKit uses: raw 64-byte X||Y public keys and raw r||s signatures
 * (the JCA speaks X.509 and DER, and Android has no P1363 signature format).
 */
internal object P256 {
    private val random = SecureRandom()

    fun generate(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()

    private val params: ECParameterSpec by lazy { (generate().public as ECPublicKey).params }

    fun raw(key: PublicKey): ByteArray {
        val w = (key as ECPublicKey).w
        return unsigned32(w.affineX) + unsigned32(w.affineY)
    }

    fun publicKey(raw: ByteArray): PublicKey {
        if (raw.size != 64) throw AirBridgeException(AirBridgeError.ProtocolViolation, "bad public key")
        val point = ECPoint(BigInteger(1, raw.copyOfRange(0, 32)), BigInteger(1, raw.copyOfRange(32, 64)))
        return try {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, params))
        } catch (e: Exception) {
            throw AirBridgeException(AirBridgeError.AuthenticationFailed)
        }
    }

    fun sign(key: PrivateKey, data: ByteArray): ByteArray {
        val der = Signature.getInstance("SHA256withECDSA").run { initSign(key); update(data); sign() }
        return derToRaw(der)
    }

    fun verify(raw: ByteArray, data: ByteArray, signature: ByteArray): Boolean = try {
        Signature.getInstance("SHA256withECDSA").run { initVerify(publicKey(raw)); update(data); verify(rawToDer(signature)) }
    } catch (e: Exception) {
        false
    }

    /** ECDH shared secret: the raw X coordinate, as CryptoKit and .NET return it. */
    fun agree(private: PrivateKey, peerRaw: ByteArray): ByteArray = try {
        KeyAgreement.getInstance("ECDH").run { init(private); doPhase(publicKey(peerRaw), true); generateSecret() }
    } catch (e: AirBridgeException) {
        throw e
    } catch (e: Exception) {
        throw AirBridgeException(AirBridgeError.AuthenticationFailed)
    }

    fun randomBytes(n: Int) = ByteArray(n).also { random.nextBytes(it) }

    private fun unsigned32(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == 32 -> bytes
            bytes.size > 32 -> bytes.copyOfRange(bytes.size - 32, bytes.size)
            else -> ByteArray(32 - bytes.size) + bytes
        }
    }

    private fun derToRaw(der: ByteArray): ByteArray {
        // SEQUENCE { INTEGER r, INTEGER s }
        var i = 2
        if (der[1].toInt() and 0x80 != 0) i += der[1].toInt() and 0x7F
        fun integer(): BigInteger {
            require(der[i].toInt() == 0x02)
            val len = der[i + 1].toInt() and 0xFF
            val value = BigInteger(1, der.copyOfRange(i + 2, i + 2 + len))
            i += 2 + len
            return value
        }
        val r = integer()
        val s = integer()
        return unsigned32(r) + unsigned32(s)
    }

    private fun rawToDer(raw: ByteArray): ByteArray {
        if (raw.size != 64) throw AirBridgeException(AirBridgeError.AuthenticationFailed)
        fun integer(part: ByteArray): ByteArray {
            val body = BigInteger(1, part).toByteArray() // minimal two's complement, positive
            return byteArrayOf(0x02, body.size.toByte()) + body
        }
        val content = integer(raw.copyOfRange(0, 32)) + integer(raw.copyOfRange(32, 64))
        return byteArrayOf(0x30, content.size.toByte()) + content
    }
}

internal fun sha256(vararg parts: ByteArray): ByteArray =
    MessageDigest.getInstance("SHA-256").run { parts.forEach { update(it) }; digest() }

/** HKDF-SHA256 (RFC 5869) for outputs up to 32 bytes. */
internal fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
    val prk = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(salt, "HmacSHA256")); doFinal(ikm) }
    val okm = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(prk, "HmacSHA256")); update(info); update(1); doFinal() }
    return okm.copyOf(length)
}

/** Long-term device identity: a stable id plus a P-256 signing key whose fingerprint peers trust. */
class DeviceIdentity private constructor(val id: String, internal val keys: KeyPair) {
    val publicKeyRaw: ByteArray = P256.raw(keys.public)
    val fingerprint: String get() = fingerprintOf(publicKeyRaw)

    @Serializable
    private data class Stored(val id: String, @Serializable(with = Base64Bytes::class) val pkcs8: ByteArray,
                              @Serializable(with = Base64Bytes::class) val publicKey: ByteArray)

    companion object {
        fun fingerprintOf(rawPublicKey: ByteArray): String =
            sha256(rawPublicKey).copyOf(16).joinToString("") { "%02x".format(it) }

        fun generate() = DeviceIdentity(UUID.randomUUID().toString().uppercase(), P256.generate())

        /** Loads the identity from [file], creating it on first launch. */
        fun loadOrCreate(file: File): DeviceIdentity {
            runCatching {
                val stored = WireJson.decodeFromString<Stored>(file.readText())
                val factory = KeyFactory.getInstance("EC")
                val private = factory.generatePrivate(PKCS8EncodedKeySpec(stored.pkcs8))
                return DeviceIdentity(stored.id, KeyPair(P256.publicKey(stored.publicKey), private))
            }
            val identity = generate()
            file.parentFile?.mkdirs()
            val stored = Stored(identity.id, identity.keys.private.encoded, identity.publicKeyRaw)
            file.writeText(WireJson.encodeToString(Stored.serializer(), stored))
            file.setReadable(false, false); file.setReadable(true, true)
            return identity
        }
    }
}
