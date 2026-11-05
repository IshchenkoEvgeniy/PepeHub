package app.pepehub.pepehub

import android.app.AlarmManager
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ReminderReceiverTest {
    private val context: Application get() = RuntimeEnvironment.getApplication()
    @Test fun reschedulingKeepsOneAlarmAndDisableCancelsIt() {
        val prefs = ReminderReceiver.preferences(context)
        prefs.edit().putBoolean("enabled", true).putInt("minute", 1200).apply()
        ReminderReceiver.schedule(context)
        val alarms = shadowOf(context.getSystemService(AlarmManager::class.java))
        assertEquals(1, alarms.scheduledAlarms.size)
        ReminderReceiver().onReceive(context, Intent(Intent.ACTION_TIMEZONE_CHANGED))
        assertEquals(1, alarms.scheduledAlarms.size)
        prefs.edit().putBoolean("enabled", false).apply()
        ReminderReceiver.schedule(context)
        assertEquals(0, alarms.scheduledAlarms.size)
    }
    @Test fun backgroundReminderPostsOncePerDayAndSchedulesTomorrow() {
        shadowOf(context).grantPermissions(android.Manifest.permission.POST_NOTIFICATIONS)
        ReminderReceiver.preferences(context).edit().clear().putBoolean("enabled", true)
            .putInt("minute", 1200).putString("body", "Цель и план").apply()
        val receiver = ReminderReceiver()
        receiver.onReceive(context, Intent(ReminderReceiver.ACTION))
        val notifications = shadowOf(context.getSystemService(NotificationManager::class.java))
        assertEquals(1, notifications.size())
        receiver.onReceive(context, Intent(ReminderReceiver.ACTION))
        assertEquals(1, notifications.size())
        assertEquals(1, shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.size)
        assertNotNull(ReminderReceiver.preferences(context).getString("lastDay", null))
    }
}
