package app.airbridge.android.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Bluetooth
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Lan
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.airbridge.android.AirBridge
import app.airbridge.core.DiscoverySource
import app.airbridge.core.Peer
import app.airbridge.core.RemoteEntry
import app.airbridge.core.TrustedDevice
import app.airbridge.core.formatBytes
import kotlinx.coroutines.launch

fun DiscoverySource.icon() = when (this) {
    DiscoverySource.Lan -> Icons.Rounded.Wifi
    DiscoverySource.PeerToPeer -> Icons.Rounded.Lan
    DiscoverySource.Bluetooth -> Icons.Rounded.Bluetooth
    DiscoverySource.Manual -> Icons.Rounded.Language
    DiscoverySource.Trusted -> Icons.Rounded.Link
}

/** Devices list with the selected device beside it on tablets and unfolded foldables, or on top of it on phones. */
@Composable
fun DevicesScreen(model: AirBridge) {
    val navigator = rememberListDetailPaneScaffoldNavigator<String>()
    val scope = rememberCoroutineScope()
    NavigableListDetailPaneScaffold(
        navigator = navigator,
        listPane = {
            AnimatedPane {
                DeviceList(model, selected = navigator.currentDestination?.contentKey) { id ->
                    scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, id) }
                }
            }
        },
        detailPane = {
            AnimatedPane {
                val id = navigator.currentDestination?.contentKey
                if (id == null) {
                    EmptyDetail()
                } else {
                    DeviceDetail(model, id, showBack = navigator.canNavigateBack()) { scope.launch { navigator.navigateBack() } }
                }
            }
        },
    )
}

@Composable
private fun EmptyDetail() {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Choose a device to send to it", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun DeviceList(model: AirBridge, selected: String?, onSelect: (String) -> Unit) {
    val peers by model.node.peers.collectAsState()
    val trusted by model.node.trusted.collectAsState()
    val transfers by model.node.transfers.collectAsState()
    val settings by model.node.settings.collectAsState()
    var adding by remember { mutableStateOf(false) }
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text("Nearby") },
                subtitle = { Text("Visible as ${settings.deviceName}") },
                actions = {
                    IconButton(onClick = { adding = true }) { Icon(Icons.Rounded.Add, contentDescription = "Add by address") }
                },
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize(), contentPadding = padding) {
            if (peers.isEmpty()) {
                item {
                    Column(Modifier.fillMaxWidth().padding(vertical = 56.dp, horizontal = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        LoadingIndicator(Modifier.size(72.dp))
                        Spacer(Modifier.height(20.dp))
                        Text("Looking for devices", style = MaterialTheme.typography.titleMediumEmphasized)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "Open AirBridge on your Mac, PC, iPhone or another Android device on the same Wi-Fi, or nearby with Bluetooth on.",
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        )
                    }
                }
            }
            items(peers, key = { it.id }) { peer ->
                val active = transfers.firstOrNull { !it.isFinished && it.peerName == peer.name }
                PeerRow(peer, trusted = model.node.isTrusted(peer), selected = peer.id == selected,
                    progress = active?.fraction, onClick = { onSelect(peer.id) })
            }
        }
    }
    if (adding) AddDeviceDialog(model, onDismiss = { adding = false }) { peer -> adding = false; onSelect(peer.id) }
}

@Composable
private fun PeerRow(peer: Peer, trusted: Boolean, selected: Boolean, progress: Float?, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val view = LocalView.current
    ListItem(
        modifier = Modifier.clickable(interaction, indication = androidx.compose.material3.ripple()) { Haptics.tick(view); onClick() },
        colors = if (selected) ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer) else ListItemDefaults.colors(),
        leadingContent = { DeviceAvatar(peer.platform, peer.isOnline, size = 52.dp, morphed = pressed || progress != null, progress = progress) },
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(peer.name, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (trusted) Icon(Icons.Rounded.Verified, contentDescription = "Paired", tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 6.dp).size(18.dp))
            }
        },
        supportingContent = {
            if (peer.isOnline) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(platformLabel(peer.platform))
                    peer.sources.filter { it != DiscoverySource.Trusted }.forEach {
                        Icon(it.icon(), contentDescription = it.label, modifier = Modifier.size(14.dp))
                    }
                }
            } else {
                Text("Not nearby")
            }
        },
    )
}

@Composable
private fun DeviceDetail(model: AirBridge, id: String, showBack: Boolean, onBack: () -> Unit) {
    val peers by model.node.peers.collectAsState()
    val trustedMap by model.node.trusted.collectAsState()
    val transfers by model.node.transfers.collectAsState()
    val peer = peers.firstOrNull { it.id == id }
    val view = LocalView.current
    var composing by remember { mutableStateOf(false) }
    var browsing by remember { mutableStateOf(false) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        if (peer != null && uris.isNotEmpty()) model.send(uris, listOf(peer))
    }
    Scaffold(topBar = {
        TopAppBar(
            title = {},
            navigationIcon = { if (showBack) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back") } },
        )
    }) { padding ->
        if (peer == null) { EmptyDetail(); return@Scaffold }
        val trusted = model.node.isTrusted(peer)
        val active = transfers.firstOrNull { !it.isFinished && it.peerName == peer.name }
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            DeviceAvatar(peer.platform, peer.isOnline, size = 132.dp, morphed = active != null, progress = active?.fraction)
            Spacer(Modifier.height(20.dp))
            Text(peer.name, style = MaterialTheme.typography.headlineLargeEmphasized, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(4.dp))
            Text(
                when {
                    active != null -> "${(active.fraction * 100).toInt()}% · ${formatBytes(active.bytesPerSecond)}/s"
                    peer.isOnline -> peer.sources.filter { it != DiscoverySource.Trusted }.joinToString(" and ") { it.label }
                    else -> "Not nearby. AirBridge will try its last known address."
                },
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(28.dp))

            // Main actions: Expressive buttons that change shape as they're pressed.
            Column(Modifier.widthIn(max = 480.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = { Haptics.tick(view); pickFiles.launch(arrayOf("*/*")) },
                    shapes = ButtonDefaults.shapes(),
                    contentPadding = ButtonDefaults.contentPaddingFor(ButtonDefaults.MediumContainerHeight),
                    modifier = Modifier.fillMaxWidth().height(ButtonDefaults.MediumContainerHeight),
                ) {
                    Icon(Icons.Rounded.Folder, contentDescription = null)
                    Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                    Text("Send files", style = ButtonDefaults.textStyleFor(ButtonDefaults.MediumContainerHeight))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FilledTonalButton(onClick = { composing = true }, shapes = ButtonDefaults.shapes(), modifier = Modifier.weight(1f)) {
                        Icon(Icons.AutoMirrored.Rounded.Send, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                        Spacer(Modifier.size(ButtonDefaults.IconSpacing)); Text("Text")
                    }
                    FilledTonalButton(onClick = { model.sendClipboard(listOf(peer)) }, shapes = ButtonDefaults.shapes(), modifier = Modifier.weight(1f)) {
                        Icon(Icons.Rounded.ContentPaste, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                        Spacer(Modifier.size(ButtonDefaults.IconSpacing)); Text("Clipboard")
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
            val device = trustedMap[peer.id]
            if (trusted && device != null) TrustedSettings(model, device, onBrowse = { browsing = true })
            else PairCard { model.pair(peer) }
            Spacer(Modifier.height(24.dp))
        }
        if (composing) ComposeTextDialog(peer.name, onDismiss = { composing = false }) { text -> composing = false; model.sendText(text, listOf(peer)) }
        if (browsing) BrowseDialog(model, peer, onDismiss = { browsing = false })
    }
}

@Composable
private fun PairCard(onPair: () -> Unit) {
    Card(
        Modifier.widthIn(max = 480.dp).fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer),
        shape = RoundedCornerShape(28.dp),
    ) {
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Shield, contentDescription = null, tint = MaterialTheme.colorScheme.onTertiaryContainer)
                Spacer(Modifier.size(10.dp))
                Text("Trust this device", style = MaterialTheme.typography.titleMediumEmphasized, color = MaterialTheme.colorScheme.onTertiaryContainer)
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "Paired devices send and receive without asking, and can open each other's shared folder.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onTertiaryContainer,
            )
            Spacer(Modifier.height(14.dp))
            Button(onClick = onPair, shapes = ButtonDefaults.shapes()) { Text("Pair") }
        }
    }
}

@Composable
private fun TrustedSettings(model: AirBridge, device: TrustedDevice, onBrowse: () -> Unit) {
    val view = LocalView.current
    var confirmUnpair by remember { mutableStateOf(false) }
    Card(Modifier.widthIn(max = 480.dp).fillMaxWidth(), shape = RoundedCornerShape(28.dp)) {
        Column(Modifier.padding(vertical = 8.dp)) {
            @Composable
            fun toggle(title: String, detail: String, value: Boolean, change: (Boolean) -> TrustedDevice) = ListItem(
                colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
                headlineContent = { Text(title) },
                supportingContent = { Text(detail) },
                trailingContent = { Switch(checked = value, onCheckedChange = { Haptics.tick(view); model.node.updateTrusted(change(it)) }) },
            )
            toggle("Accept files automatically", "No prompt when ${device.name} sends", device.autoAccept) { device.copy(autoAccept = it) }
            toggle("Let it open my shared folder", "Browse and download from this device", device.allowBrowse) { device.copy(allowBrowse = it) }
            toggle("Copy received text", "Put text straight on the clipboard", device.autoClipboard) { device.copy(autoClipboard = it) }
            HorizontalDivider(Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
            FlowRow(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onBrowse, shapes = ButtonDefaults.shapes()) {
                    Icon(Icons.Rounded.FolderOpen, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                    Spacer(Modifier.size(ButtonDefaults.IconSpacing)); Text("Browse its files")
                }
                TextButton(onClick = { confirmUnpair = true }) { Text("Unpair", color = MaterialTheme.colorScheme.error) }
            }
        }
    }
    if (confirmUnpair) ConfirmDialog(
        title = "Unpair ${device.name}?",
        text = "Automatic transfers with this device stop until you pair again. ${device.name} is told too.",
        confirm = "Unpair", destructive = true,
        onDismiss = { confirmUnpair = false },
    ) { confirmUnpair = false; model.node.unpair(device.id) }
}

@Composable
private fun AddDeviceDialog(model: AirBridge, onDismiss: () -> Unit, onAdded: (Peer) -> Unit) {
    var address by rememberSaveable { mutableStateOf("") }
    var connecting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add by address") },
        text = {
            Column {
                Text("For devices on a VPN such as Tailscale, or another network. The default port is 47820.",
                    style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(address, { address = it }, singleLine = true, label = { Text("Address") },
                    placeholder = { Text("100.101.102.103:47820") })
            }
        },
        confirmButton = {
            if (connecting) LoadingIndicator(Modifier.size(36.dp))
            else TextButton(enabled = address.isNotBlank(), onClick = {
                connecting = true
                scope.launch { model.addManualDevice(address)?.let(onAdded); connecting = false }
            }) { Text("Connect") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun BrowseDialog(model: AirBridge, peer: Peer, onDismiss: () -> Unit) {
    var path by remember { mutableStateOf("") }
    var entries by remember { mutableStateOf<List<RemoteEntry>?>(null) }
    val scope = rememberCoroutineScope()
    androidx.compose.runtime.LaunchedEffect(path) { entries = null; entries = model.browse(peer, path) ?: emptyList() }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (path.isEmpty()) "${peer.name} shared" else path.substringAfterLast('/')) },
        text = {
            val list = entries
            if (list == null) LoadingIndicator(Modifier.fillMaxWidth().height(96.dp))
            else if (list.isEmpty()) Text("Nothing shared here yet.")
            else LazyColumn(Modifier.height(360.dp)) {
                items(list, key = { it.name }) { entry ->
                    val full = if (path.isEmpty()) entry.name else "$path/${entry.name}"
                    ListItem(
                        modifier = Modifier.clickable { if (entry.dir) path = full },
                        leadingContent = { Icon(if (entry.dir) Icons.Rounded.Folder else Icons.Rounded.Link, contentDescription = null) },
                        headlineContent = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        supportingContent = { if (!entry.dir) Text(formatBytes(entry.size.toDouble())) },
                        trailingContent = {
                            TextButton(onClick = { model.pull(listOf(full), peer); scope.launch { onDismiss() } }) { Text("Download") }
                        },
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = { if (path.isNotEmpty()) TextButton(onClick = { path = path.substringBeforeLast('/', "") }) { Text("Up") } },
    )
}
