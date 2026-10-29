package app.airbridge.android.ui

import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularWavyProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.airbridge.android.AirBridge
import app.airbridge.android.Feedback
import app.airbridge.core.Peer
import app.airbridge.core.SpeedTestProgress
import app.airbridge.core.SpeedTestResult
import app.airbridge.core.SpeedUnit
import app.airbridge.core.speedTest

/**
 * Upload then download speed with one device. The wavy ring fills through both phases;
 * the number inside is the live speed in whichever unit is selected below it.
 */
@Composable
fun SpeedTestSheet(model: AirBridge, peer: Peer, onDismiss: () -> Unit) {
    val settings by model.node.settings.collectAsState()
    val unit = settings.speedUnit
    val view = LocalView.current
    var progress by remember { mutableStateOf<SpeedTestProgress?>(null) }
    var result by remember { mutableStateOf<SpeedTestResult?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var running by remember { mutableStateOf(false) }
    var run by remember { mutableIntStateOf(0) }

    LaunchedEffect(run) {
        running = true; error = null; result = null; progress = null
        try {
            result = model.node.speedTest(peer) { p ->
                if (p.phase != progress?.phase) Haptics.tick(view)
                progress = p
            }
            Haptics.perform(view, Feedback.Kind.Success)
        } catch (e: Exception) {
            error = e.message
            Haptics.perform(view, Feedback.Kind.Error)
        }
        progress = null
        running = false
    }

    val target = progress?.let { (if (it.phase == SpeedTestProgress.Phase.Upload) 0f else 0.5f) + it.fraction / 2 } ?: if (result != null) 1f else 0f
    val ring by animateFloatAsState(target, MaterialTheme.motionScheme.defaultEffectsSpec(), label = "ring")
    val center = when {
        running && (progress?.bytesPerSecond ?: 0.0) > 0 -> unit.format(progress!!.bytesPerSecond)
        result != null -> unit.format((result!!.upload + result!!.download) / 2)
        else -> "–"
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Speed with ${peer.name}", style = MaterialTheme.typography.headlineSmallEmphasized, textAlign = TextAlign.Center)
            Spacer(Modifier.height(24.dp))
            Box(Modifier.size(220.dp).semantics { contentDescription = "Speed $center" }, contentAlignment = Alignment.Center) {
                CircularWavyProgressIndicator(progress = { ring }, modifier = Modifier.size(220.dp))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(center, style = MaterialTheme.typography.headlineLargeEmphasized, maxLines = 1, softWrap = false)
                    Text(
                        when {
                            running && progress?.phase == SpeedTestProgress.Phase.Upload -> "Uploading"
                            running && progress != null -> "Downloading"
                            running -> "Connecting"
                            result != null -> "Average of both"
                            else -> "Ready"
                        },
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.height(24.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(32.dp)) {
                ResultColumn("Upload", Icons.Rounded.ArrowUpward, result?.upload, unit)
                ResultColumn("Download", Icons.Rounded.ArrowDownward, result?.download, unit)
            }
            Spacer(Modifier.height(20.dp))
            UnitSwitch(unit) { new -> Haptics.tick(view); model.node.updateSettings { it.copy(speedUnit = new) } }
            error?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.height(20.dp))
            Button(
                onClick = { run++ }, enabled = !running, shapes = ButtonDefaults.shapes(),
                modifier = Modifier.widthIn(max = 360.dp).fillMaxWidth().height(ButtonDefaults.MediumContainerHeight),
            ) { Text("Test again", style = ButtonDefaults.textStyleFor(ButtonDefaults.MediumContainerHeight)) }
        }
    }
}

@Composable
private fun ResultColumn(title: String, icon: ImageVector, value: Double?, unit: SpeedUnit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.size(4.dp))
            Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(value?.let(unit::format) ?: "–", style = MaterialTheme.typography.titleLargeEmphasized)
    }
}

/** MB/s or Mbps, saved for every speed the app shows. */
@Composable
fun UnitSwitch(unit: SpeedUnit, modifier: Modifier = Modifier, onChange: (SpeedUnit) -> Unit) {
    SingleChoiceSegmentedButtonRow(modifier) {
        SpeedUnit.entries.forEachIndexed { i, u ->
            SegmentedButton(
                selected = unit == u, onClick = { onChange(u) },
                shape = SegmentedButtonDefaults.itemShape(i, SpeedUnit.entries.size),
            ) { Text(u.label) }
        }
    }
}
