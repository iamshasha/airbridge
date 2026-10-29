package app.airbridge.core

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UpdatesTest {
    @Test
    fun versionsCompareNumerically() {
        assertTrue(UpdateChecker.isNewer("v0.10.0", "0.9.2"))
        assertTrue(UpdateChecker.isNewer("v1.0", "0.9.9"))
        assertFalse(UpdateChecker.isNewer("v0.3.0", "0.3.0"))
        assertFalse(UpdateChecker.isNewer("v0.2.0", "0.3.0"))
    }

    @Test
    fun releaseJsonPicksThisPlatformsAsset() {
        val json = """
            {"tag_name":"v0.4.0","body":"Faster","html_url":"https://github.com/iamshasha/airbridge/releases/tag/v0.4.0",
             "draft":false,"prerelease":false,"assets":[
               {"name":"AirBridge-macOS.zip","size":1200,"browser_download_url":"https://example.com/mac.zip"},
               {"name":"AirBridge-android.apk","size":3400,"browser_download_url":"https://example.com/app.apk"}]}
        """.trimIndent()
        val update = UpdateChecker.parse(json, "0.3.0", "AirBridge-android.apk")!!
        assertEquals("0.4.0", update.version)
        assertEquals("https://example.com/app.apk", update.downloadUrl)
        assertEquals(3400, update.downloadSize)
        assertNull(UpdateChecker.parse(json, "0.4.0", "AirBridge-android.apk"))
        assertTrue(UpdateChecker.isDue(null))
        assertFalse(UpdateChecker.isDue(System.currentTimeMillis() - 3_600_000))
    }
}
