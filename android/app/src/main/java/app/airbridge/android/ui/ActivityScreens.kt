package app.airbridge.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material.icons.rounded.TextSnippet
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.airbridge.android.AirBridge
import app.airbridge.core.ReceivePolicy
import app.airbridge.core.Transfer
import app.airbridge.core.TransferDirection
import app.airbridge.core.TransferState
import app.airbridge.core.formatBytes
import java.io.File
import java.text.DateFormat
import java.util.Date

@Composable
private fun ScreenScaffold(title: String, actions: @Composable () -> Unit = {}, content: @Composable (androidx.compose.foundation.layout.PaddingValues) -> Unit) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = { LargeFlexibleTopAppBar(title = { Text(title) }, actions = { actions() }, scrollBehavior = scrollBehavior) },
        content = content,
    )
}

@Composable
private fun EmptyState(icon: ImageVector, title: String, text: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 64.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(56.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(16.dp))
        Text(title, style = MaterialTheme.typography.titleMediumEmphasized)
        Spacer(Modifier.height(6.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
fun TransfersScreen(model: AirBridge) {
    val transfers by model.node.transfers.collectAsState()
    val unit = model.node.settings.collectAsState().value.speedUnit
    val context = LocalContext.current
    ScreenScaffold("Transfers", actions = {
        if (transfers.any { it.isFinished }) TextButton(onClick = { model.node.clearFinishedTransfers() }) { Text("Clear finished") }
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize(), contentPadding = padding) {
            if (transfers.isEmpty()) item {
                EmptyState(Icons.Rounded.SwapVert, "No transfers yet", "Files you send and receive show up here, with their progress.")
            }
            items(transfers, key = { it.id }) { t -> TransferRow(t, unit, onOpen = { file -> runCatching { context.startActivity(model.viewIntent(file)) } }) }
        }
    }
}

@Composable
private fun TransferRow(t: Transfer, unit: app.airbridge.core.SpeedUnit, onOpen: (File) -> Unit) {
    val first = t.savedPaths.firstOrNull()?.let(::File)
    ListItem(
        modifier = if (first != null && first.isFile) Modifier.clickable { onOpen(first) } else Modifier,
        leadingContent = {
            Icon(
                when {
                    t.state == TransferState.Failed -> Icons.Rounded.ErrorOutline
                    t.state == TransferState.Done -> Icons.Rounded.CheckCircle
                    t.direction == TransferDirection.Outgoing -> Icons.Rounded.ArrowUpward
                    else -> Icons.Rounded.ArrowDownward
                },
                contentDescription = null,
                tint = when (t.state) {
                    TransferState.Failed, TransferState.Declined -> MaterialTheme.colorScheme.error
                    TransferState.Done -> MaterialTheme.colorScheme.secondary
                    else -> MaterialTheme.colorScheme.primary
                },
            )
        },
        headlineContent = { Text(t.title, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
        supportingContent = {
            Column {
                Text("${if (t.direction == TransferDirection.Outgoing) "To" else "From"} ${t.peerName}, ${formatBytes(t.total.toDouble())}")
                if (t.state == TransferState.Active) {
                    Spacer(Modifier.height(8.dp))
                    LinearWavyProgressIndicator(progress = { t.fraction }, modifier = Modifier.fillMaxWidth())
                }
                t.error?.takeIf { t.state == TransferState.Failed }?.let { Text(it, color = MaterialTheme.colorScheme.error, maxLines = 2) }
            }
        },
        trailingContent = {
            Text(
                when (t.state) {
                    TransferState.Connecting -> "Connecting"
                    TransferState.WaitingForAcceptance -> "Waiting"
                    TransferState.Active -> unit.format(t.bytesPerSecond)
                    TransferState.Done -> if (first != null && first.isFile) "Open" else "Done"
                    TransferState.Failed -> "Failed"
                    TransferState.Declined -> "Declined"
                },
                style = MaterialTheme.typography.labelLarge,
                color = if (t.state == TransferState.Done && first != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
    )
}

/** Text that arrived, and the files received this session. */
@Composable
fun ReceivedScreen(model: AirBridge) {
    val inbox by model.node.inbox.collectAsState()
    val transfers by model.node.transfers.collectAsState()
    val files = transfers.filter { it.direction == TransferDirection.Incoming && it.state == TransferState.Done }
        .flatMap { it.savedPaths }.map(::File).filter { it.exists() }
    val context = LocalContext.current
    val view = LocalView.current
    var confirmClear by remember { mutableStateOf(false) }
    ScreenScaffold("Received", actions = {
        if (inbox.isNotEmpty()) IconButton(onClick = { confirmClear = true }) { Icon(Icons.Rounded.DeleteSweep, contentDescription = "Delete all text") }
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize(), contentPadding = padding) {
            if (inbox.isEmpty() && files.isEmpty()) item {
                EmptyState(Icons.Rounded.TextSnippet, "Nothing received yet",
                    "Text, links and files other devices send you appear here. Files are saved to Downloads › AirBridge.")
            }
            items(inbox, key = { it.id }) { item ->
                val state = rememberSwipeToDismissBoxState()
                SwipeToDismissBox(
                    state = state,
                    enableDismissFromStartToEnd = false,
                    onDismiss = { if (it == SwipeToDismissBoxValue.EndToStart) { Haptics.tick(view); model.node.deleteText(item.id) } },
                    backgroundContent = {
                        Row(Modifier.fillMaxSize().padding(horizontal = 24.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
                        }
                    },
                ) {
                    ListItem(
                        overlineContent = { Text("${item.from}, ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(item.date))}") },
                        headlineContent = { Text(item.text, maxLines = 6, overflow = TextOverflow.Ellipsis) },
                        trailingContent = {
                            IconButton(onClick = {
                                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("AirBridge", item.text))
                                Haptics.perform(view, app.airbridge.android.Feedback.Kind.Success)
                            }) { Icon(Icons.Rounded.ContentCopy, contentDescription = "Copy") }
                        },
                    )
                }
            }
            if (files.isNotEmpty()) {
                item { Text("Files", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp)) }
                items(files, key = { it.path }) { file ->
                    ListItem(
                        modifier = Modifier.clickable(enabled = file.isFile) { runCatching { context.startActivity(model.viewIntent(file)) } },
                        leadingContent = { Icon(ReceivedIcon, contentDescription = null) },
                        headlineContent = { Text(file.name, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
                        supportingContent = { Text(if (file.isDirectory) "Folder in Downloads › AirBridge" else formatBytes(file.length().toDouble())) },
                        trailingContent = {
                            if (file.isFile) Row {
                                IconButton(onClick = { runCatching { context.startActivity(model.shareIntent(file)) } }) {
                                    Icon(Icons.Rounded.Share, contentDescription = "Share")
                                }
                                IconButton(onClick = { runCatching { context.startActivity(model.viewIntent(file)) } }) {
                                    Icon(Icons.AutoMirrored.Rounded.OpenInNew, contentDescription = "Open")
                                }
                            }
                        },
                    )
                }
            }
        }
    }
    if (confirmClear) ConfirmDialog("Delete all received text?", "Files you received stay in Downloads.", "Delete all", destructive = true,
        onDismiss = { confirmClear = false }) { confirmClear = false; model.node.clearInbox() }
}

@Composable
fun SettingsScreen(model: AirBridge) {
    val settings by model.node.settings.collectAsState()
    val keepRunning by model.keepRunning.collectAsState()
    val port by model.node.listeningPort.collectAsState()
    val view = LocalView.current
    var name by rememberSaveable(settings.deviceName) { mutableStateOf(settings.deviceName) }
    var relay by rememberSaveable(settings.relayUrl) { mutableStateOf(settings.relayUrl) }
    var link by rememberSaveable { mutableStateOf("") }
    ScreenScaffold("Settings") { padding ->
        LazyColumn(Modifier.fillMaxSize(), contentPadding = padding) {
            item {
                Column(Modifier.padding(horizontal = 16.dp).widthIn(max = 640.dp)) {
                    OutlinedTextField(name, { name = it }, label = { Text("Device name") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        supportingText = { Text("How other devices see this one") },
                        trailingIcon = { if (name != settings.deviceName) TextButton(onClick = { model.rename(name) }) { Text("Save") } })
                }
            }
            item { Section("Who can send to you") }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
                    val options = listOf(ReceivePolicy.Everyone to "Everyone", ReceivePolicy.TrustedOnly to "Paired only", ReceivePolicy.Off to "No one")
                    options.forEachIndexed { i, (policy, label) ->
                        SegmentedButton(
                            selected = settings.receivePolicy == policy,
                            onClick = { Haptics.tick(view); model.node.updateSettings { it.copy(receivePolicy = policy) } },
                            shape = SegmentedButtonDefaults.itemShape(i, options.size),
                        ) { Text(label) }
                    }
                }
            }
            item { Section("Show speeds in") }
            item {
                UnitSwitch(settings.speedUnit, Modifier.padding(horizontal = 16.dp).fillMaxWidth()) { new ->
                    Haptics.tick(view); model.node.updateSettings { it.copy(speedUnit = new) }
                }
            }
            item { Section("Background") }
            item {
                SwitchRow("Keep receiving when closed", "Shows a quiet notification while AirBridge stays ready", keepRunning) {
                    Haptics.tick(view); model.setKeepRunning(it)
                }
            }
            item {
                SwitchRow("Find devices with Bluetooth", "Also works when Wi-Fi blocks discovery", settings.bluetoothDiscovery) {
                    Haptics.tick(view); model.setBluetooth(it)
                }
            }
            item { Section("Internet links") }
            item {
                Column(Modifier.padding(horizontal = 16.dp)) {
                    OutlinedTextField(relay, { relay = it }, label = { Text("Relay address") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("https://airbridge-relay.example.workers.dev") },
                        supportingText = { Text("Your Cloudflare relay, for sending to anyone with a link") },
                        trailingIcon = { if (relay != settings.relayUrl) TextButton(onClick = { model.node.updateSettings { it.copy(relayUrl = relay.trim()) } }) { Text("Save") } })
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(link, { link = it }, label = { Text("Open a link someone sent you") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        trailingIcon = { if (link.isNotBlank()) TextButton(onClick = { model.openLink(link); link = "" }) { Text("Receive") } })
                }
            }
            item { Section("This device") }
            item {
                ListItem(
                    headlineContent = { Text("Fingerprint") },
                    supportingContent = { Text(model.node.identity.fingerprint.chunked(4).joinToString(" "), style = MaterialTheme.typography.bodySmall) },
                )
            }
            item { ListItem(headlineContent = { Text("Listening on port") }, supportingContent = { Text(port?.toString() ?: "Not listening") }) }
            item { ListItem(headlineContent = { Text("Received files") }, supportingContent = { Text(model.node.downloadFolder.path) }) }
            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmallEmphasized, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 8.dp))
}

@Composable
private fun SwitchRow(title: String, detail: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        modifier = Modifier.clickable { onChange(!checked) },
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange) },
    )
}
