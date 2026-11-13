package com.anarchylabs.lecteur_de_carte

import android.content.Context
import android.hardware.usb.UsbManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lecteur_de_carte/usb")
            .setMethodCallHandler { call, result ->
                if (call.method != "listUsbReaders") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val manager = getSystemService(Context.USB_SERVICE) as UsbManager
                    val devices = manager.deviceList.values.map { device ->
                        mapOf(
                            "deviceName" to device.deviceName,
                            "vendorId" to "0x%04X".format(device.vendorId),
                            "productId" to "0x%04X".format(device.productId),
                            "productName" to (device.productName ?: "Inconnu"),
                            "manufacturerName" to (device.manufacturerName ?: "Inconnu"),
                            "interfaces" to (0 until device.interfaceCount).map { index ->
                                val iface = device.getInterface(index)
                                mapOf("class" to iface.interfaceClass, "subclass" to iface.interfaceSubclass,
                                    "protocol" to iface.interfaceProtocol, "ccid" to (iface.interfaceClass == 11))
                            }
                        )
                    }
                    result.success(devices)
                } catch (e: Exception) {
                    result.error("USB_SCAN_FAILED", e.message, null)
                }
            }
    }
}
