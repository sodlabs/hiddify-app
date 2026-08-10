package com.hiddify.hiddify

import android.annotation.SuppressLint
import android.content.Intent
import android.Manifest
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import com.hiddify.hiddify.bg.ServiceConnection
import com.hiddify.hiddify.bg.ServiceNotification
import com.hiddify.hiddify.constant.Alert
import com.hiddify.hiddify.constant.ServiceMode
import com.hiddify.hiddify.constant.Status
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.CompletableDeferred
import java.util.LinkedList


class MainActivity : FlutterFragmentActivity(), ServiceConnection.Callback {
    companion object {
        private const val TAG = "ANDROID/MyActivity"
        lateinit var instance: MainActivity

        const val VPN_PERMISSION_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1010
    }

    private val connection = ServiceConnection(this, this)

    val logList = LinkedList<String>()
    var logCallback: ((Boolean) -> Unit)? = null
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)
    private var vpnPermissionRequest: CompletableDeferred<Boolean>? = null
    private var notificationPermissionRequest: CompletableDeferred<Boolean>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        instance = this
        reconnect()
        flutterEngine.plugins.add(MethodHandler(lifecycleScope))
        flutterEngine.plugins.add(PlatformSettingsHandler())
        flutterEngine.plugins.add(EventHandler())
        flutterEngine.plugins.add(LogHandler())
//        flutterEngine.plugins.add(GroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(ActiveGroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(StatsChannel(lifecycleScope))
    }

    fun reconnect() {
        connection.reconnect()
    }

    /**
     * The Flutter method call only completes after Android's permission dialog
     * has been accepted or rejected. This prevents the core from opening TUN
     * while the VPN authorisation is still pending.
     */
    @SuppressLint("NewApi")
    suspend fun startService(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !ServiceNotification.checkPermission()) {
            if (!requestNotificationPermission() && Settings.dynamicNotification) {
                onServiceAlert(Alert.RequestNotificationPermission, null)
                return false
            }
        }
        if (Settings.rebuildServiceMode()) {
            connection.reconnect()
        }
        if (Settings.serviceMode == ServiceMode.VPN && !requestVpnPermission()) {
            onServiceAlert(Alert.RequestVPNPermission, null)
            return false
        }

        return try {
            ContextCompat.startForegroundService(this, Intent(Application.application, Settings.serviceClass()))
            Settings.startedByUser = true
            true
        } catch (e: Exception) {
            onServiceAlert(Alert.StartService, e.message)
            false
        }
    }

    private suspend fun requestVpnPermission(): Boolean {
        try {
            val intent = VpnService.prepare(this) ?: return true
            vpnPermissionRequest?.let { return it.await() }
            val request = CompletableDeferred<Boolean>()
            vpnPermissionRequest = request
            prepareLauncher.launch(intent)
            return request.await()
        } catch (e: Exception) {
            onServiceAlert(Alert.RequestVPNPermission, e.message)
            return false
        }
    }

    private suspend fun requestNotificationPermission(): Boolean {
        notificationPermissionRequest?.let { return it.await() }
        val request = CompletableDeferred<Boolean>()
        notificationPermissionRequest = request
        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        return request.await()
    }
    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            notificationPermissionRequest?.complete(isGranted)
            notificationPermissionRequest = null
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            vpnPermissionRequest?.complete(result.resultCode == RESULT_OK)
            vpnPermissionRequest = null
        }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
    }




    override fun onDestroy() {
        connection.disconnect()
        super.onDestroy()
    }

}
