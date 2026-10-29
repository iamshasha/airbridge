package app.airbridge.android.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Android
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.PhoneIphone
import androidx.compose.material.icons.rounded.TabletMac
import androidx.compose.material3.CircularWavyProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asComposePath
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.graphics.shapes.Morph
import androidx.graphics.shapes.RoundedPolygon
import androidx.graphics.shapes.toPath

/**
 * Each kind of device has its own Expressive shape, so a Mac and an iPhone are told apart at a glance.
 * Pressing, dragging over or sending to a device morphs it into a circle.
 */
fun platformShape(platform: String): RoundedPolygon = when (platform) {
    "mac" -> MaterialShapes.Cookie9Sided
    "ios" -> MaterialShapes.Pill
    "ipad" -> MaterialShapes.Square
    "win" -> MaterialShapes.Clover4Leaf
    "android" -> MaterialShapes.SoftBurst
    else -> MaterialShapes.Cookie6Sided
}

fun platformIcon(platform: String): ImageVector = when (platform) {
    "mac" -> Icons.Rounded.Laptop
    "ios" -> Icons.Rounded.PhoneIphone
    "ipad" -> Icons.Rounded.TabletMac
    "win" -> Icons.Rounded.DesktopWindows
    "android" -> Icons.Rounded.Android
    "linux" -> Icons.Rounded.Computer
    else -> Icons.Rounded.Devices
}

fun platformLabel(platform: String) = when (platform) {
    "mac" -> "Mac"; "ios" -> "iPhone"; "ipad" -> "iPad"; "win" -> "Windows PC"; "android" -> "Android"; else -> "Device"
}

/** A [Morph] between two polygons as a Compose [Shape], scaled to the layout size. */
class MorphShape(private val morph: Morph, private val progress: Float, private val rotation: Float = 0f) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val path = morph.toPath(progress).asComposePath()
        val matrix = Matrix().apply {
            translate(size.width / 2, size.height / 2)
            rotateZ(rotation)
            translate(-size.width / 2, -size.height / 2)
            scale(size.width, size.height)
        }
        path.transform(matrix)
        return Outline.Generic(path)
    }
}

/**
 * The device's mark: its platform shape, filled with the brand gradient when online. While a transfer runs,
 * a wavy ring around it shows the progress, the same ring the Mac and Windows apps draw.
 */
@Composable
fun DeviceAvatar(
    platform: String,
    online: Boolean,
    modifier: Modifier = Modifier,
    size: Dp = 48.dp,
    morphed: Boolean = false,
    progress: Float? = null,
) {
    val polygon = remember(platform) { platformShape(platform).normalized() }
    val morph = remember(polygon) { Morph(polygon, MaterialShapes.Circle.normalized()) }
    val amount by animateFloatAsState(if (morphed) 1f else 0f, MaterialTheme.motionScheme.defaultSpatialSpec(), label = "morph")
    val spin by animateFloatAsState(if (morphed) 90f else 0f, MaterialTheme.motionScheme.slowSpatialSpec(), label = "spin")
    val ringPadding = size * 0.12f
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        if (progress != null) {
            CircularWavyProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxSize())
        }
        Box(
            Modifier
                .fillMaxSize()
                .padding(if (progress != null) ringPadding else 0.dp)
                .clip(MorphShape(morph, amount, spin))
                .then(
                    if (online) Modifier.background(BrandGradient)
                    else Modifier.background(MaterialTheme.colorScheme.surfaceContainerHighest)
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                platformIcon(platform), contentDescription = null,
                tint = if (online) MaterialTheme.colorScheme.surfaceContainerLowest else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(size * 0.45f).graphicsLayer { rotationZ = 0f },
            )
        }
    }
}
