package app.airbridge.android.ui

import android.Manifest
import android.content.Context
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Inbox
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Radar
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.airbridge.android.AirBridge
import app.airbridge.android.BluetoothDiscovery
import app.airbridge.android.Feedback

enum class Tab(val label: String, val icon: ImageVector) {
    Devices("Nearby", Icons.Rounded.Radar),
    Transfers("Transfers", Icons.Rounded.SwapVert),
    Received("Received", Icons.Rounded.Inbox),
    Settings("Settings", Icons.Rounded.Settings),
}

/**
 * Bottom navigation bar on phones, a navigation rail on tablets and unfolded foldables
 * (NavigationSuiteScaffold picks from the window size), with app-wide dialogs on top.
 */
@Composable
fun AppRoot(model: AirBridge, requestedTab: Tab?, onTabConsumed: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("app", Context.MODE_PRIVATE) }
    var onboarded by remember { mutableStateOf(prefs.getBoolean("onboarded", false)) }
    if (!onboarded) {
        Onboarding {
            prefs.edit().putBoolean("onboarded", true).apply()
            onboarded = true
            model.start()
        }
        return
    }
    LaunchedEffect(Unit) { model.start() }

    var tab by rememberSaveable { mutableStateOf(Tab.Devices) }
    LaunchedEffect(requestedTab) { requestedTab?.let { tab = it; onTabConsumed() } }
    val transfers by model.node.transfers.collectAsState()
    val inbox by model.node.inbox.collectAsState()
    var seenInbox by rememberSaveable { mutableIntStateOf(0) }
    if (tab == Tab.Received && seenInbox != inbox.size) seenInbox = inbox.size
    val active = transfers.count { !it.isFinished }
    val unread = (inbox.size - seenInbox).coerceAtLeast(0)
    val view = LocalView.current
    val snackbar = remember { SnackbarHostState() }

    // Every event gets its haptic; the ones with words also get a banner.
    LaunchedEffect(Unit) {
        model.feedback.collect { f ->
            Haptics.perform(view, f.kind)
            f.text?.let { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(it) }
        }
    }

    Box(Modifier.fillMaxSize()) {
        NavigationSuiteScaffold(
            navigationSuiteItems = {
                Tab.entries.forEach { t ->
                    item(
                        selected = tab == t,
                        onClick = { if (tab != t) Haptics.tick(view); tab = t },
                        icon = {
                            val count = when (t) { Tab.Transfers -> active; Tab.Received -> unread; else -> 0 }
                            BadgedBox(badge = { if (count > 0) Badge { Text("$count") } }) { Icon(t.icon, contentDescription = null) }
                        },
                        label = { Text(t.label) },
                    )
                }
            },
        ) {
            when (tab) {
                Tab.Devices -> DevicesScreen(model)
                Tab.Transfers -> TransfersScreen(model)
                Tab.Received -> ReceivedScreen(model)
                Tab.Settings -> SettingsScreen(model)
            }
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 80.dp))
    }

    val prompts by model.node.prompts.collectAsState()
    prompts.firstOrNull()?.let { PromptDialog(model, it) }
    model.pairingCode.collectAsState().value?.let { PairingCodeDialog(it) }
    model.sharedLink.collectAsState().value?.let { LinkDialog(model, it) }
    ShareTargetSheet(model)
    model.error.collectAsState().value?.let { message ->
        AlertDialog(
            onDismissRequest = { model.error.value = null },
            title = { Text("Something went wrong") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { model.error.value = null }) { Text("OK") } },
        )
    }
}

/** First launch: what AirBridge does, then the permissions it needs to find devices. */
@Composable
private fun Onboarding(onDone: () -> Unit) {
    val permissions = buildList {
        if (Build.VERSION.SDK_INT >= 31) addAll(BluetoothDiscovery.permissions)
        if (Build.VERSION.SDK_INT >= 33) { add(Manifest.permission.POST_NOTIFICATIONS); add(Manifest.permission.NEARBY_WIFI_DEVICES) }
    }.toTypedArray()
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { onDone() }
    val view = LocalView.current
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 28.dp).widthIn(max = 520.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(48.dp))
                Row(horizontalArrangement = Arrangement.spacedBy((-14).dp)) {
                    listOf("mac", "ios", "win", "android").forEach { DeviceAvatar(it, online = true, size = 64.dp) }
                }
                Spacer(Modifier.height(28.dp))
                Text("AirBridge", style = MaterialTheme.typography.displayMediumEmphasized)
                Spacer(Modifier.height(8.dp))
                Text("Send anything to your Mac, PC, iPhone or another Android, nearby or over the internet.",
                    style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(36.dp))
                Feature(Icons.Rounded.Wifi, "Finds devices nearby", "On the same Wi-Fi, or with Bluetooth when Wi-Fi blocks discovery.")
                Feature(Icons.Rounded.Lock, "Private by design", "Every transfer is end-to-end encrypted. Pair a device once to trust it.")
                Feature(Icons.Rounded.Bolt, "As fast as your network", "Big files go over several connections at once.")
                Spacer(Modifier.height(24.dp))
                Text("Next, Android asks to let AirBridge use Bluetooth, nearby Wi-Fi devices and notifications.",
                    style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(24.dp))
            }
            Button(
                onClick = { Haptics.perform(view, Feedback.Kind.Crisp); if (permissions.isEmpty()) onDone() else request.launch(permissions) },
                shapes = ButtonDefaults.shapes(),
                modifier = Modifier.padding(24.dp).widthIn(max = 520.dp).fillMaxWidth().height(ButtonDefaults.MediumContainerHeight),
            ) { Text("Continue", style = ButtonDefaults.textStyleFor(ButtonDefaults.MediumContainerHeight)) }
        }
    }
}

@Composable
private fun Feature(icon: ImageVector, title: String, text: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
        Spacer(Modifier.width(16.dp))
        Column {
            Text(title, style = MaterialTheme.typography.titleMediumEmphasized)
            Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
