package app.airbridge.android

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import app.airbridge.core.PromptKind
import app.airbridge.core.PromptRequest
import app.airbridge.core.ReceivedText
import app.airbridge.core.Transfer
import app.airbridge.core.formatBytes
import java.io.File

/**
 * Notifications that make AirBridge usable from the background: accept or decline requests,
 * see a preview of received photos, open what arrived.
 */
class Notifications(private val context: Context) {
    private val manager = NotificationManagerCompat.from(context)

    init {
        val system = context.getSystemService(NotificationManager::class.java)
        system.createNotificationChannels(listOf(
            NotificationChannel(REQUESTS, "Requests", NotificationManager.IMPORTANCE_HIGH).apply { description = "Devices that want to send you files or pair" },
            NotificationChannel(RECEIVED, "Received", NotificationManager.IMPORTANCE_DEFAULT).apply { description = "Files and text that arrived" },
            NotificationChannel(SERVICE, "Ready to receive", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Shown while AirBridge keeps receiving in the background"
                setShowBadge(false)
            },
        ))
    }

    private val allowed get() = Build.VERSION.SDK_INT < 33 ||
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun openApp(extra: Intent.() -> Unit = {}) = PendingIntent.getActivity(
        context, System.nanoTime().toInt(),
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).apply(extra),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun action(prompt: String, accept: Boolean) = PendingIntent.getBroadcast(
        context, (prompt + accept).hashCode(),
        Intent(context, NotificationActionReceiver::class.java).putExtra("prompt", prompt).putExtra("accept", accept),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    @android.annotation.SuppressLint("MissingPermission")
    private fun post(id: Int, builder: NotificationCompat.Builder) { if (allowed) manager.notify(id, builder.build()) }

    fun prompt(prompt: PromptRequest) {
        val pairing = prompt.kind == PromptKind.Pairing
        val body = if (pairing) "Check that ${prompt.peerName} shows ${prompt.code?.chunked(3)?.joinToString(" ")}."
        else prompt.items.filter { !it.isDirectory }.map { it.path.substringAfterLast('/') }.let { names ->
            names.take(3).joinToString(", ") + if (names.size > 3) " and ${names.size - 3} more" else ""
        }
        post(prompt.id.hashCode(), NotificationCompat.Builder(context, REQUESTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(prompt.summary)
            .setContentText(body)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp())
            .setTimeoutAfter(120_000)
            .addAction(0, if (pairing) "Don't pair" else "Decline", action(prompt.id, false))
            .addAction(0, if (pairing) "Pair" else "Accept", action(prompt.id, true)))
    }

    fun removePrompt(id: String) = manager.cancel(id.hashCode())

    fun received(record: Transfer) {
        val first = record.savedPaths.firstOrNull()?.let(::File)
        val builder = NotificationCompat.Builder(context, RECEIVED)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Received ${record.title}")
            .setContentText("From ${record.peerName}, ${formatBytes(record.total.toDouble())}")
            .setAutoCancel(true)
            .setContentIntent(openApp { first?.let { putExtra("open", it.path) } })
        // Photos get a big preview right in the notification.
        if (record.savedPaths.size == 1 && first != null && mimeOf(first).startsWith("image/")) {
            decodePreview(first)?.let { bitmap ->
                builder.setLargeIcon(bitmap).setStyle(NotificationCompat.BigPictureStyle().bigPicture(bitmap).bigLargeIcon(null as android.graphics.Bitmap?))
            }
        }
        post(record.id.hashCode(), builder)
    }

    fun text(item: ReceivedText, copied: Boolean) {
        post(item.id.hashCode(), NotificationCompat.Builder(context, RECEIVED)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Text from ${item.from}")
            .setContentText(if (copied) "Copied to the clipboard" else item.text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(if (copied) "Copied to the clipboard" else item.text))
            .setAutoCancel(true)
            .setContentIntent(openApp { putExtra("tab", "received") }))
    }

    fun service() = NotificationCompat.Builder(context, SERVICE)
        .setSmallIcon(R.drawable.ic_notification)
        .setContentTitle("Ready to receive")
        .setContentText("Nearby devices can send to ${context.airBridge.node.settings.value.deviceName}")
        .setOngoing(true)
        .setSilent(true)
        .setContentIntent(openApp())
        .build()

    /** Downsampled so a 48-megapixel photo doesn't take the notification down with it. */
    private fun decodePreview(file: File) = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (bounds.outWidth / sample > 1440 || bounds.outHeight / sample > 1440) sample *= 2
        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }.getOrNull()

    companion object {
        const val REQUESTS = "requests"
        const val RECEIVED = "received"
        const val SERVICE = "service"
        const val SERVICE_ID = 1
    }
}

/** Accept / Decline buttons on request notifications. */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prompt = intent.getStringExtra("prompt") ?: return
        val node = context.airBridge.node
        node.respond(prompt, intent.getBooleanExtra("accept", false))
        context.airBridge.notifications.removePrompt(prompt)
    }
}

/** Keeps the process (and so the listener and discovery) alive while the app is closed. */
class AirBridgeService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ServiceCompat.startForeground(this, Notifications.SERVICE_ID, airBridge.notifications.service(),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0)
        airBridge.start()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        fun start(context: Context) = runCatching { context.startForegroundService(Intent(context, AirBridgeService::class.java)) }
        fun stop(context: Context) = context.stopService(Intent(context, AirBridgeService::class.java))
    }
}
