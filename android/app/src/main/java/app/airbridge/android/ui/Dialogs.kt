package app.airbridge.android.ui

import android.content.Intent
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ContainedLoadingIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.airbridge.android.AirBridge
import app.airbridge.android.PairingCode
import app.airbridge.android.SharedLink
import app.airbridge.core.PromptKind
import app.airbridge.core.PromptRequest
import app.airbridge.core.formatBytes
import kotlinx.coroutines.delay

@Composable
fun ConfirmDialog(title: String, text: String, confirm: String, destructive: Boolean = false, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(confirm, color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun ComposeTextDialog(peerName: String, onDismiss: () -> Unit, onSend: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Send to $peerName") },
        text = { OutlinedTextField(text, { text = it }, label = { Text("Message, link or note") }, minLines = 3, maxLines = 8) },
        confirmButton = { TextButton(enabled = text.isNotBlank(), onClick = { onSend(text) }) { Text("Send") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Six digits that pop in one after another: the same code must show on both screens. */
@Composable
fun CodeView(code: String) {
    Row(Modifier.semantics { contentDescription = "Code ${code.toList().joinToString(" ")}" }, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        code.forEachIndexed { index, digit ->
            val scale = remember { Animatable(0.4f) }
            LaunchedEffect(code) {
                delay(index * 60L)
                scale.animateTo(1f, androidx.compose.animation.core.spring(dampingRatio = 0.45f, stiffness = 500f))
            }
            Box(
                Modifier.size(width = 40.dp, height = 54.dp)
                    .graphicsLayer { scaleX = scale.value; scaleY = scale.value }
                    .background(MaterialTheme.colorScheme.secondaryContainer, RoundedCornerShape(14.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(digit.toString(), fontSize = 30.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSecondaryContainer)
            }
            if (index == 2) Spacer(Modifier.width(10.dp))
        }
    }
}

/** Incoming file offer or pairing request. */
@Composable
fun PromptDialog(model: AirBridge, prompt: PromptRequest) {
    val pairing = prompt.kind == PromptKind.Pairing
    val view = LocalView.current
    LaunchedEffect(prompt.id) { Haptics.perform(view, app.airbridge.android.Feedback.Kind.Arrival) }
    AlertDialog(
        onDismissRequest = {},
        icon = {
            DeviceAvatar(prompt.peerPlatform, online = true, size = 64.dp)
        },
        title = { Text(prompt.summary, textAlign = TextAlign.Center) },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                if (pairing) {
                    Text("Pair only if ${prompt.peerName} shows the same code.", textAlign = TextAlign.Center)
                    Spacer(Modifier.height(16.dp))
                    CodeView(prompt.code.orEmpty())
                } else {
                    val files = prompt.items.filter { !it.isDirectory }
                    files.take(5).forEach { item ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                            Text(item.path, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Text(formatBytes(item.size.toDouble()), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    if (files.size > 5) Text("and ${files.size - 5} more", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.height(12.dp))
                Text("Fingerprint ${prompt.fingerprint.take(12)}…", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            Button(onClick = { Haptics.perform(view, app.airbridge.android.Feedback.Kind.Success); model.node.respond(prompt.id, true) },
                shapes = ButtonDefaults.shapes()) { Text(if (pairing) "Pair" else "Accept") }
        },
        dismissButton = {
            TextButton(onClick = { model.node.respond(prompt.id, false) }) { Text(if (pairing) "Don't pair" else "Decline") }
        },
    )
}

/** Shown on this side while the other device decides whether to pair. */
@Composable
fun PairingCodeDialog(code: PairingCode) {
    AlertDialog(
        onDismissRequest = {},
        icon = { Icon(Icons.Rounded.Shield, contentDescription = null) },
        title = { Text("Pairing with ${code.peer}") },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                Text("Check that ${code.peer} shows this code, then confirm there.", textAlign = TextAlign.Center)
                Spacer(Modifier.height(16.dp))
                CodeView(code.code)
                Spacer(Modifier.height(16.dp))
                ContainedLoadingIndicator(Modifier.size(44.dp))
            }
        },
        confirmButton = {},
    )
}

@Composable
fun LinkDialog(model: AirBridge, link: SharedLink) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = { if (link.finished) model.sharedLink.value = null },
        title = { Text(if (link.finished) "Sent ${link.title}" else "Share ${link.title}") },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                when {
                    link.finished -> Text("The recipient has everything.")
                    link.link == null -> ContainedLoadingIndicator()
                    else -> {
                        Text("Anyone with this link can receive the files once. Keep AirBridge open until they do.", textAlign = TextAlign.Center)
                        Spacer(Modifier.height(12.dp))
                        Text(link.link, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.MiddleEllipsis,
                            color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        },
        confirmButton = {
            if (link.finished) TextButton(onClick = { model.sharedLink.value = null }) { Text("Done") }
            else if (link.link != null) Button(onClick = {
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                    .putExtra(Intent.EXTRA_TEXT, link.link), "Share link"))
            }, shapes = ButtonDefaults.shapes()) { Text("Share link") }
        },
        dismissButton = { if (!link.finished) TextButton(onClick = { model.sharedLink.value = null }) { Text("Close") } },
    )
}

/** Files shared from another app: pick one or more devices to send them to. */
@Composable
fun ShareTargetSheet(model: AirBridge) {
    val share by model.pendingShare.collectAsState()
    val peers by model.node.peers.collectAsState()
    if (share == null) return
    val chosen = remember { mutableStateListOf<String>() }
    val view = LocalView.current
    ModalBottomSheet(onDismissRequest = { model.pendingShare.value = null }) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 16.dp)) {
            val s = share!!
            Text(
                if (s.uris.isNotEmpty()) "Send ${s.uris.size} ${if (s.uris.size == 1) "item" else "items"}" else "Send text",
                style = MaterialTheme.typography.headlineSmallEmphasized, modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(16.dp))
            if (peers.isEmpty()) {
                Row(Modifier.padding(horizontal = 24.dp, vertical = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.material3.LoadingIndicator(Modifier.size(40.dp))
                    Spacer(Modifier.width(12.dp))
                    Text("Looking for devices…")
                }
            }
            LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                items(peers, key = { it.id }) { peer ->
                    val selected = peer.id in chosen
                    Column(
                        Modifier.width(96.dp).clickable {
                            Haptics.tick(view)
                            if (selected) chosen.remove(peer.id) else chosen.add(peer.id)
                        }.padding(8.dp).alpha(if (peer.isOnline) 1f else 0.6f),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        DeviceAvatar(peer.platform, peer.isOnline, size = 64.dp, morphed = selected)
                        Spacer(Modifier.height(6.dp))
                        Text(peer.name, style = MaterialTheme.typography.labelLarge, maxLines = 2, textAlign = TextAlign.Center, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
            Row(Modifier.padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    enabled = chosen.isNotEmpty(), shapes = ButtonDefaults.shapes(), modifier = Modifier.weight(1f),
                    onClick = { model.deliverPendingShare(peers.filter { it.id in chosen }) },
                ) { Text(if (chosen.size > 1) "Send to ${chosen.size}" else "Send") }
                if (s.uris.isNotEmpty()) OutlinedButton(shapes = ButtonDefaults.shapes(), onClick = {
                    model.pendingShare.value = null; model.shareViaLink(s.uris)
                }) { Text("Share link") }
            }
        }
    }
}

/** Download icon reused by the Received list. */
val ReceivedIcon = Icons.Rounded.Download
