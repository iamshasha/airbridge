package app.airbridge.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.IntentCompat
import app.airbridge.android.ui.AirBridgeTheme
import app.airbridge.android.ui.AppRoot
import app.airbridge.android.ui.Tab
import java.io.File

class MainActivity : ComponentActivity() {
    private var requestedTab by mutableStateOf<Tab?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handle(intent)
        setContent {
            AirBridgeTheme {
                AppRoot(airBridge, requestedTab, onTabConsumed = { requestedTab = null })
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** Share sheet, airbridge:// links and notification taps all arrive here. */
    private fun handle(intent: Intent) {
        val model = airBridge
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (uri != null || text != null) model.pendingShare.value = PendingShare(listOfNotNull(uri), if (uri == null) text else null)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                if (uris.isNotEmpty()) model.pendingShare.value = PendingShare(uris)
            }
            Intent.ACTION_VIEW -> intent.data?.let { link ->
                requestedTab = Tab.Transfers
                model.openLink(link.toString())
            }
        }
        intent.getStringExtra("open")?.let { path ->
            requestedTab = Tab.Received
            runCatching { startActivity(model.viewIntent(File(path))) }
        }
        if (intent.getStringExtra("tab") == "received") requestedTab = Tab.Received
    }
}
