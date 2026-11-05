package com.example.folder

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * LocalSend (nearby file sharing) platform pieces:
 *
 * - a Wi-Fi multicast lock while discovery runs: without it Android drops the
 *   UDP multicast announcements (224.0.0.167:53317) of other devices;
 * - network change callbacks, so Dart re-joins the multicast group and
 *   re-announces after a Wi-Fi switch / hotspot start;
 * - basic network info (Wi-Fi or not, IPv4 addresses, SSID when readable).
 */
class LocalSendNative(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "explorer/localsend")
    private val main = Handler(Looper.getMainLooper())
    private var multicastLock: WifiManager.MulticastLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val wifiManager: WifiManager?
        get() = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private val connectivityManager: ConnectivityManager?
        get() = activity.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "acquireMulticastLock" -> result.success(acquireMulticastLock())
                    "releaseMulticastLock" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    "startNetworkMonitor" -> result.success(startNetworkMonitor())
                    "stopNetworkMonitor" -> {
                        stopNetworkMonitor()
                        result.success(null)
                    }
                    "getNetworkInfo" -> result.success(networkInfo())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("localsend", e.message, null)
            }
        }
    }

    private fun acquireMulticastLock(): Boolean {
        val lock = multicastLock ?: wifiManager?.createMulticastLock("explorer-localsend")?.also {
            it.setReferenceCounted(false)
            multicastLock = it
        } ?: return false
        if (!lock.isHeld) lock.acquire()
        return lock.isHeld
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    private fun startNetworkMonitor(): Boolean {
        if (networkCallback != null) return true
        val cm = connectivityManager ?: return false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = notifyChanged()
            override fun onLost(network: Network) = notifyChanged()
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) =
                notifyChanged()
        }
        return try {
            cm.registerNetworkCallback(NetworkRequest.Builder().build(), callback)
            networkCallback = callback
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopNetworkMonitor() {
        val callback = networkCallback ?: return
        networkCallback = null
        try {
            connectivityManager?.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
    }

    private var pendingNotify = false

    /** Debounced: a network switch fires several callbacks in a row. */
    private fun notifyChanged() {
        main.post {
            if (pendingNotify) return@post
            pendingNotify = true
            main.postDelayed({
                pendingNotify = false
                channel.invokeMethod("networkChanged", null)
            }, 1500)
        }
    }

    @Suppress("DEPRECATION")
    private fun networkInfo(): Map<String, Any?> {
        val cm = connectivityManager
        val addresses = mutableListOf<String>()
        var wifi = false
        if (cm != null) {
            for (network in cm.allNetworks) {
                val caps = cm.getNetworkCapabilities(network) ?: continue
                val isWifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                if (isWifi) wifi = true
                cm.getLinkProperties(network)?.linkAddresses?.forEach { link ->
                    val address = link.address
                    if (address is Inet4Address && !address.isLoopbackAddress) {
                        addresses.add(address.hostAddress ?: return@forEach)
                    }
                }
            }
        }
        var ssid: String? = null
        try {
            val raw = wifiManager?.connectionInfo?.ssid
            if (raw != null && raw != "<unknown ssid>") {
                ssid = raw.trim('"')
            }
        } catch (_: Exception) {
        }
        return mapOf("wifi" to wifi, "ssid" to ssid, "addresses" to addresses)
    }

    fun dispose() {
        stopNetworkMonitor()
        releaseMulticastLock()
        channel.setMethodCallHandler(null)
    }
}
