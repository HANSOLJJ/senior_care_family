package com.seniorcare.family

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager

// 부팅 완료 시 화면을 켜고 앱을 자동으로 실행하는 BroadcastReceiver
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            // 화면 강제 켜기
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            val wakeLock = powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "senior_care_family:boot"
            )
            wakeLock.acquire(10_000L) // 10초 유지 후 자동 해제

            // 앱 실행
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(launchIntent)
        }
    }
}
