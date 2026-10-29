package app.airbridge.android

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.provider.Settings
import androidx.core.content.IntentCompat
import app.airbridge.core.AppUpdate
import app.airbridge.core.UpdateChecker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Checks GitHub Releases for a newer AirBridge and installs it through Android's package installer,
 * which asks the user to confirm (Android requires that for apps installed outside a store).
 */
class Updater(private val context: Context) {
    sealed interface State {
        data object Idle : State
        data object Checking : State
        data object UpToDate : State
        data class Available(val update: AppUpdate) : State
        data class Downloading(val fraction: Float) : State
        data object Installing : State
        /** Android needs "Install unknown apps" allowed for AirBridge first. */
        data class NeedsPermission(val update: AppUpdate) : State
        data class Failed(val message: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state = _state.asStateFlow()
    /** True when an automatic check found something, so the app offers it once. */
    val offer = MutableStateFlow(false)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)

    val currentVersion: String = context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"

    var checksAutomatically: Boolean
        get() = prefs.getBoolean("checkUpdates", true)
        set(value) { prefs.edit().putBoolean("checkUpdates", value).apply() }

    val lastChecked: Long? get() = prefs.getLong("lastUpdateCheck", 0).takeIf { it > 0 }

    /** Once a day at launch, quietly. */
    fun checkInBackground() {
        if (!checksAutomatically || !UpdateChecker.isDue(lastChecked)) return
        scope.launch {
            val update = runCatching { withContext(Dispatchers.IO) { UpdateChecker.check(currentVersion, ASSET) } }.getOrNull()
            prefs.edit().putLong("lastUpdateCheck", System.currentTimeMillis()).apply()
            if (update != null) { _state.value = State.Available(update); offer.value = true }
        }
    }

    fun check() {
        _state.value = State.Checking
        scope.launch {
            _state.value = try {
                val update = withContext(Dispatchers.IO) { UpdateChecker.check(currentVersion, ASSET) }
                prefs.edit().putLong("lastUpdateCheck", System.currentTimeMillis()).apply()
                if (update == null) State.UpToDate else State.Available(update)
            } catch (e: Exception) {
                State.Failed("Couldn't check for updates: ${e.message}")
            }
        }
    }

    fun dismiss() {
        offer.value = false
        if (_state.value !is State.Downloading && _state.value !is State.Installing) _state.value = State.Idle
    }

    fun install(update: AppUpdate) {
        val url = update.downloadUrl ?: run { openPage(update); return }
        if (!context.packageManager.canRequestPackageInstalls()) { _state.value = State.NeedsPermission(update); return }
        scope.launch {
            try {
                val apk = File(context.cacheDir, "updates/AirBridge-${update.version}.apk")
                _state.value = State.Downloading(0f)
                withContext(Dispatchers.IO) { UpdateChecker.download(url, apk) { f -> _state.value = State.Downloading(f) } }
                _state.value = State.Installing
                withContext(Dispatchers.IO) { commit(apk) }
            } catch (e: Exception) {
                _state.value = State.Failed("Couldn't install the update: ${e.message}")
            }
        }
    }

    /** Opens Settings › Install unknown apps for AirBridge. */
    fun openInstallPermission() {
        context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun openPage(update: AppUpdate) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(update.pageUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun commit(apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("base.apk", 0, apk.length()).use { out -> apk.inputStream().use { it.copyTo(out) }; session.fsync(out) }
            val callback = PendingIntent.getBroadcast(
                context, id, Intent(context, UpdateReceiver::class.java),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            session.commit(callback.intentSender)
        }
    }

    internal fun installerResult(status: Int, message: String?) {
        if (status != PackageInstaller.STATUS_SUCCESS && status != PackageInstaller.STATUS_PENDING_USER_ACTION)
            _state.value = State.Failed(if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "The update was cancelled." else "Couldn't install the update: ${message ?: status}")
    }

    companion object {
        const val ASSET = "AirBridge-android.apk"
    }
}

/** Package installer callbacks: show Android's confirmation screen, or report a failure. */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)
                ?.let { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
        context.airBridge.updater.installerResult(status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE))
    }
}
