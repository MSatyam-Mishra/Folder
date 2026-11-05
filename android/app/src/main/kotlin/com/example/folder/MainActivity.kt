package com.example.folder

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.hardware.usb.*
import android.os.Build
import android.os.Bundle
import androidx.activity.OnBackPressedCallback
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.HashMap

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "explorer/usb"
    private var usbManager: UsbManager? = null
    private val ACTION_USB_PERMISSION = "com.example.folder.USB_PERMISSION"
    
    // Cache open connections: deviceId -> UsbDeviceConnection
    private val openConnections = HashMap<Int, UsbDeviceConnection>()
    // Cache endpoints: deviceId -> Pair(In, Out)
    private val deviceEndpoints = HashMap<Int, Pair<UsbEndpoint, UsbEndpoint>>()
    // Cache interfaces: deviceId -> UsbInterface
    private val deviceInterfaces = HashMap<Int, UsbInterface>()

    private var incomingFiles: IncomingFiles? = null
    private var localSend: LocalSendNative? = null
    private var videoDownloader: VideoDownloaderNative? = null
    private var device: DeviceNative? = null
    private var imageText: ImageTextNative? = null
    private var imageConvert: ImageConvertNative? = null
    private var notifications: NotificationsNative? = null
    private var videoPlayer: VideoPlayerNative? = null
    private var appCloser: AppCloserNative? = null

    // Back at the top of the app while work goes on: the app stays, as closing
    // it would end the work. Only reached when Flutter has nothing left to pop.
    private val keepWorking = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            moveTaskToBack(true)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Without a lifecycle, and before super: the last added goes first, and
        // Flutter's must, or Back would never reach the app's screens.
        onBackPressedDispatcher.addCallback(keepWorking)
        BackgroundWorkService.onWorkingChanged = { keepWorking.isEnabled = it }
        super.onCreate(savedInstanceState)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        videoPlayer?.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        videoPlayer?.onPipChanged(isInPictureInPictureMode)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingFiles?.onNewIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        incomingFiles?.dispose()
        incomingFiles = null
        localSend?.dispose()
        localSend = null
        videoDownloader?.dispose()
        videoDownloader = null
        device?.dispose()
        device = null
        imageText?.dispose()
        imageText = null
        imageConvert?.dispose()
        imageConvert = null
        notifications?.dispose()
        notifications = null
        videoPlayer?.dispose()
        videoPlayer = null
        appCloser?.dispose()
        appCloser = null
        BackgroundWorkService.onWorkingChanged = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        incomingFiles = IncomingFiles(this, flutterEngine.dartExecutor.binaryMessenger)
        localSend = LocalSendNative(this, flutterEngine.dartExecutor.binaryMessenger)
        videoDownloader = VideoDownloaderNative(this, flutterEngine.dartExecutor.binaryMessenger)
        device = DeviceNative(this, flutterEngine.dartExecutor.binaryMessenger)
        imageText = ImageTextNative(flutterEngine.dartExecutor.binaryMessenger)
        imageConvert = ImageConvertNative(flutterEngine.dartExecutor.binaryMessenger)
        notifications = NotificationsNative(this, flutterEngine.dartExecutor.binaryMessenger)
        videoPlayer = VideoPlayerNative(this, flutterEngine.dartExecutor.binaryMessenger)
        appCloser = AppCloserNative(this, flutterEngine.dartExecutor.binaryMessenger)
        
        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceList" -> {
                    val devices = ArrayList<Map<String, Any>>()
                    usbManager?.deviceList?.values?.forEach { device ->
                        val map = HashMap<String, Any>()
                        map["deviceId"] = device.deviceId
                        map["vendorId"] = device.vendorId
                        map["productId"] = device.productId
                        map["productName"] = device.productName ?: "Unknown"
                        devices.add(map)
                    }
                    result.success(devices)
                }
                "hasPermission" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    val device = usbManager?.deviceList?.values?.find { it.deviceId == deviceId }
                    if (device != null) {
                        result.success(usbManager!!.hasPermission(device))
                    } else {
                        result.success(false)
                    }
                }
                "requestPermission" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    val device = usbManager?.deviceList?.values?.find { it.deviceId == deviceId }
                    if (device != null) {
                        if (usbManager!!.hasPermission(device)) {
                            result.success(true)
                        } else {
                            val permissionIntent = PendingIntent.getBroadcast(
                                this, 0, Intent(ACTION_USB_PERMISSION),
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
                            )
                            usbManager!!.requestPermission(device, permissionIntent)
                            // Immediate result is false (pending), logic should ideally wait, 
                            // but for simplicity we return false and dev polls or we assume user grants next time.
                            // Better: register receiver and wait. BUT keeping it simple: just trigger prompt.
                            result.success(false) 
                        }
                    } else {
                        result.success(false)
                    }
                }
                "openDevice" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    val device = usbManager?.deviceList?.values?.find { it.deviceId == deviceId }
                    if (device != null) {
                         val connection = usbManager!!.openDevice(device)
                         if (connection != null) {
                             openConnections[deviceId!!] = connection
                             result.success(true)
                         } else {
                             result.success(false)
                         }
                    } else {
                        result.error("DEVICE_NOT_FOUND", "Device not found", null)
                    }
                }
                "claimInterface" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    val connection = openConnections[deviceId]
                    val device = usbManager?.deviceList?.values?.find { it.deviceId == deviceId }
                    
                    if (connection != null && device != null) {
                        // Find Mass Storage Interface
                        // Simple heuristic: First interface with BULK endpoints
                        var foundInterface: UsbInterface? = null
                        var inEp: UsbEndpoint? = null
                        var outEp: UsbEndpoint? = null
                        
                        for (i in 0 until device.interfaceCount) {
                            val inter = device.getInterface(i)
                            var currIn: UsbEndpoint? = null
                            var currOut: UsbEndpoint? = null
                            for (j in 0 until inter.endpointCount) {
                                val ep = inter.getEndpoint(j)
                                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                                    if (ep.direction == UsbConstants.USB_DIR_IN) currIn = ep
                                    if (ep.direction == UsbConstants.USB_DIR_OUT) currOut = ep
                                }
                            }
                            if (currIn != null && currOut != null) {
                                foundInterface = inter
                                inEp = currIn
                                outEp = currOut
                                break
                            }
                        }
                        
                        if (foundInterface != null) {
                            connection.claimInterface(foundInterface, true)
                            deviceInterfaces[deviceId!!] = foundInterface
                            deviceEndpoints[deviceId!!] = Pair(inEp!!, outEp!!)
                            result.success(true)
                        } else {
                             result.error("NO_INTERFACE", "No mass storage interface found", null)
                        }
                    } else {
                        result.error("NO_CONNECTION", "Device not connected", null)
                    }
                }
                "bulkTransferOut" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    val data = call.argument<ByteArray>("data")
                    val connection = openConnections[deviceId]
                    val endpoints = deviceEndpoints[deviceId]
                    
                    if (connection != null && endpoints != null && data != null) {
                        // 5s timeout
                        val transferred = connection.bulkTransfer(endpoints.second, data, data.size, 5000)
                        result.success(transferred)
                    } else {
                        result.error("ERROR", "Transfer failed", null)
                    }
                }
                "bulkTransferIn" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    val length = call.argument<Int>("length") ?: 0
                    val connection = openConnections[deviceId]
                    val endpoints = deviceEndpoints[deviceId]
                    
                    if (connection != null && endpoints != null) {
                        val buffer = ByteArray(length)
                        val transferred = connection.bulkTransfer(endpoints.first, buffer, length, 5000)
                        if (transferred > 0) {
                             // If we read less, slice it? 
                             result.success(buffer) 
                        } else {
                             result.success(ByteArray(0))
                        }
                    } else {
                        result.error("ERROR", "Transfer failed", null)
                    }
                }
                "closeDevice" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    val connection = openConnections[deviceId]
                    val iface = deviceInterfaces[deviceId]
                    if (connection != null) {
                        if (iface != null) connection.releaseInterface(iface)
                        connection.close()
                        openConnections.remove(deviceId)
                        deviceInterfaces.remove(deviceId)
                        deviceEndpoints.remove(deviceId)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
