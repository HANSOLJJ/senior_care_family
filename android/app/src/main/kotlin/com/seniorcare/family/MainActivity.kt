package com.seniorcare.family

import android.content.Intent
import android.os.Bundle
import com.navercorp.nid.NaverIdLoginSDK
import com.navercorp.nid.oauth.NidOAuthLogin
import com.navercorp.nid.oauth.OAuthLoginCallback
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.seniorcare.family/naver_login"
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 네이버 SDK 초기화
        val clientId = getString(R.string.client_id)
        val clientSecret = getString(R.string.client_secret)
        val clientName = getString(R.string.client_name)
        NaverIdLoginSDK.initialize(this, clientId, clientSecret, clientName)
        NaverIdLoginSDK.showDevelopersLog(true)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "logIn" -> naverLogIn(result)
                "logOut" -> {
                    NaverIdLoginSDK.logout()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun naverLogIn(result: MethodChannel.Result) {
        val callback = object : OAuthLoginCallback {
            override fun onSuccess() {
                val accessToken = NaverIdLoginSDK.getAccessToken()
                if (accessToken != null) {
                    result.success(mapOf("accessToken" to accessToken))
                } else {
                    result.error("NO_TOKEN", "Access token is null after success", null)
                }
            }

            override fun onFailure(httpStatus: Int, message: String) {
                val errorCode = NaverIdLoginSDK.getLastErrorCode().code
                val errorDesc = NaverIdLoginSDK.getLastErrorDescription()
                result.error("NAVER_FAIL", "errorCode:$errorCode, errorDesc:$errorDesc", null)
            }

            override fun onError(errorCode: Int, message: String) {
                onFailure(errorCode, message)
            }
        }

        NaverIdLoginSDK.authenticate(this, callback)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
