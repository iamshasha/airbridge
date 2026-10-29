package app.airbridge.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import app.airbridge.android.Feedback
import app.airbridge.android.Updater
import app.airbridge.android.Updater.State

/** Result of a check: up to date, or what's new with an Update button and download progress. */
@Composable
fun UpdateDialog(updater: Updater, onDismiss: () -> Unit) {
    val state by updater.state.collectAsState()
    val view = LocalView.current
    LaunchedEffect(state) {
        when (state) {
            is State.Available -> Haptics.perform(view, Feedback.Kind.Arrival)
            is State.UpToDate -> Haptics.perform(view, Feedback.Kind.Success)
            is State.Failed -> Haptics.perform(view, Feedback.Kind.Error)
            else -> {}
        }
    }
    val busy = state is State.Downloading || state is State.Installing
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        icon = {
            when (state) {
                is State.UpToDate -> Icon(Icons.Rounded.CheckCircle, contentDescription = null)
                is State.Failed -> Icon(Icons.Rounded.Warning, contentDescription = null)
                else -> Icon(Icons.Rounded.SystemUpdate, contentDescription = null)
            }
        },
        title = {
            Text(when (val s = state) {
                is State.Available -> "AirBridge ${s.update.version} is available"
                is State.NeedsPermission -> "Allow AirBridge to install updates"
                is State.UpToDate -> "You're up to date"
                is State.Downloading -> "Downloading the update"
                is State.Installing -> "Installing"
                is State.Failed -> "Update didn't work"
                else -> "Checking for updates"
            })
        },
        text = {
            Column(Modifier.fillMaxWidth()) {
                when (val s = state) {
                    is State.Available -> {
                        Text("You have ${updater.currentVersion}.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (s.update.notes.isNotBlank()) {
                            Spacer(Modifier.height(12.dp))
                            Text(plainNotes(s.update.notes),
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.heightIn(max = 280.dp).verticalScroll(rememberScrollState()))
                        }
                    }
                    is State.NeedsPermission -> Text("Android only installs apps from sources you allow. Turn on Allow from this source for AirBridge, then come back and tap Update.")
                    is State.UpToDate -> Text("AirBridge ${updater.currentVersion} is the latest version.")
                    is State.Downloading -> {
                        LinearWavyProgressIndicator(progress = { s.fraction }, modifier = Modifier.fillMaxWidth())
                        Spacer(Modifier.height(8.dp))
                        Text("${(s.fraction * 100).toInt()}%", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    is State.Installing -> Text("Confirm the update when Android asks. AirBridge restarts with the new version.")
                    is State.Failed -> Text(s.message)
                    else -> LoadingIndicator(Modifier.size(56.dp))
                }
            }
        },
        confirmButton = {
            when (val s = state) {
                is State.Available -> Button(onClick = { updater.install(s.update) }, shapes = ButtonDefaults.shapes()) { Text("Update") }
                is State.NeedsPermission -> Button(onClick = { updater.openInstallPermission() }, shapes = ButtonDefaults.shapes()) { Text("Open settings") }
                is State.Failed -> TextButton(onClick = { updater.check() }) { Text("Try again") }
                is State.UpToDate -> TextButton(onClick = onDismiss) { Text("OK") }
                else -> {}
            }
        },
        dismissButton = {
            when (state) {
                is State.Available, is State.Failed -> TextButton(onClick = onDismiss) { Text("Later") }
                is State.NeedsPermission -> TextButton(onClick = { (state as State.NeedsPermission).let { updater.install(it.update) } }) { Text("Update") }
                else -> {}
            }
        },
    )
}

/** Release notes are Markdown; show them as plain text (headings, bold and code marks removed). */
private fun plainNotes(markdown: String) = markdown.lines().joinToString("\n") { line ->
    line.replace(Regex("^#+\\s*"), "").replace("**", "").replace("`", "").replace(Regex("^- "), "• ")
}.trim()
