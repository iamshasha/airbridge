package app.airbridge.android.ui

import android.view.HapticFeedbackConstants
import android.view.View
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import app.airbridge.android.Feedback

// The brand's two colours, shared with the Mac, iPhone and Windows apps: the device ring runs from one to the other.
val BrandBlue = Color(0xFF1A7AFF)
val BrandCyan = Color(0xFF2ED1F2)
val BrandGradient = Brush.linearGradient(listOf(BrandBlue, BrandCyan))

private val Light = lightColorScheme(
    primary = Color(0xFF0060D6), onPrimary = Color.White,
    primaryContainer = Color(0xFFD8E2FF), onPrimaryContainer = Color(0xFF001A43),
    secondary = Color(0xFF00677C), onSecondary = Color.White,
    secondaryContainer = Color(0xFFB2EBFF), onSecondaryContainer = Color(0xFF001F27),
    tertiary = Color(0xFF6B4FA8), tertiaryContainer = Color(0xFFEBDDFF), onTertiaryContainer = Color(0xFF250059),
    background = Color(0xFFF7F9FF), onBackground = Color(0xFF181C22),
    surface = Color(0xFFF7F9FF), onSurface = Color(0xFF181C22),
    surfaceVariant = Color(0xFFDFE2EC), onSurfaceVariant = Color(0xFF43474F),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF1F3FB),
    surfaceContainer = Color(0xFFEBEEF6), surfaceContainerHigh = Color(0xFFE5E8F0), surfaceContainerHighest = Color(0xFFDFE2EA),
    outline = Color(0xFF737780), outlineVariant = Color(0xFFC3C6D0),
    error = Color(0xFFBA1A1A), errorContainer = Color(0xFFFFDAD6),
)

private val Dark = darkColorScheme(
    primary = Color(0xFFADC6FF), onPrimary = Color(0xFF002E6B),
    primaryContainer = Color(0xFF004496), onPrimaryContainer = Color(0xFFD8E2FF),
    secondary = Color(0xFF5DD5F5), onSecondary = Color(0xFF003641),
    secondaryContainer = Color(0xFF004E5E), onSecondaryContainer = Color(0xFFB2EBFF),
    tertiary = Color(0xFFD3BBFF), tertiaryContainer = Color(0xFF523689), onTertiaryContainer = Color(0xFFEBDDFF),
    background = Color(0xFF0F1420), onBackground = Color(0xFFE0E2EB),
    surface = Color(0xFF0F1420), onSurface = Color(0xFFE0E2EB),
    surfaceVariant = Color(0xFF43474F), onSurfaceVariant = Color(0xFFC3C6D0),
    surfaceContainerLowest = Color(0xFF0A0E19), surfaceContainerLow = Color(0xFF171C28),
    surfaceContainer = Color(0xFF1B202C), surfaceContainerHigh = Color(0xFF252A37), surfaceContainerHighest = Color(0xFF303542),
    outline = Color(0xFF8D9199), outlineVariant = Color(0xFF43474F),
)

@Composable
fun AirBridgeTheme(content: @Composable () -> Unit) {
    MaterialExpressiveTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        motionScheme = MotionScheme.expressive(),
        content = content,
    )
}

/** System haptics with distinct feels per event, falling back on older Android versions. */
object Haptics {
    fun perform(view: View, kind: Feedback.Kind) {
        val constant = when (kind) {
            Feedback.Kind.Success -> HapticFeedbackConstants.CONFIRM
            Feedback.Kind.Error -> HapticFeedbackConstants.REJECT
            Feedback.Kind.Warning -> if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.GESTURE_THRESHOLD_DEACTIVATE else HapticFeedbackConstants.REJECT
            Feedback.Kind.Arrival -> if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE else HapticFeedbackConstants.CONTEXT_CLICK
            Feedback.Kind.Crisp -> HapticFeedbackConstants.CONTEXT_CLICK
        }
        view.performHapticFeedback(constant)
    }

    /** Light tick for toggles and selections. */
    fun tick(view: View) = view.performHapticFeedback(
        if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK,
    )
}
