package com.anarchylabs.lecteur_de_carte

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val permissionAction = "com.anarchylabs.lecteur_de_carte.USB_PERMISSION"
    private var receiverRegistered = false
    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // The user can press Analyse again once Android has granted permission.
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(permissionAction)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(permissionReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun onDestroy() {
        if (receiverRegistered) unregisterReceiver(permissionReceiver)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lecteur_de_carte/usb")
            .setMethodCallHandler { call, result ->
                if (call.method != "scanCards" && call.method != "listUsbReaders" && call.method != "sendSafeApdu") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val manager = getSystemService(Context.USB_SERVICE) as UsbManager
                    if (call.method == "sendSafeApdu") {
                        val action = call.argument<String>("action") ?: ""
                        result.success(sendSafeApdu(manager, action))
                    } else {
                        result.success(manager.deviceList.values.map { device -> probe(manager, device) })
                    }
                } catch (e: Exception) {
                    result.error("USB_SCAN_FAILED", e.message, null)
                }
            }
    }

    private fun probe(manager: UsbManager, device: UsbDevice): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>(
            "appareil" to device.deviceName,
            "VID" to "0x%04X".format(device.vendorId),
            "PID" to "0x%04X".format(device.productId),
            "interfaces" to device.interfaceCount
        )
        val ccid = (0 until device.interfaceCount).map { device.getInterface(it) }
            .firstOrNull { it.interfaceClass == 11 }
        if (ccid == null) {
            result["diagnostic"] = "Périphérique USB non CCID (classe 11 absente)."
            return result
        }
        result["type"] = "Lecteur CCID"
        if (!manager.hasPermission(device)) {
            val intent = Intent(permissionAction).setPackage(packageName)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val pending = PendingIntent.getBroadcast(this, device.deviceId, intent, flags)
            manager.requestPermission(device, pending)
            result["diagnostic"] = "Autorisation USB demandée : accepte, puis relance l'analyse."
            return result
        }
        val bulkOut = (0 until ccid.endpointCount).map { ccid.getEndpoint(it) }
            .firstOrNull { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_OUT }
        val bulkIn = (0 until ccid.endpointCount).map { ccid.getEndpoint(it) }
            .firstOrNull { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_IN }
        if (bulkIn == null || bulkOut == null) {
            result["diagnostic"] = "Lecteur CCID sans paire de points de terminaison bulk."
            return result
        }
        val connection = manager.openDevice(device)
        if (connection == null) {
            result["diagnostic"] = "Impossible d'ouvrir le périphérique USB."
            return result
        }
        try {
            if (!connection.claimInterface(ccid, true)) {
                result["diagnostic"] = "Interface CCID indisponible."
                return result
            }
            try {
                // Standard CCID: GetSlotStatus (0x65), then IccPowerOn (0x62) if card present.
                val status = exchange(connection, bulkOut, bulkIn, 0x65, 1)
                if (status == null || status.size < 10 || (status[0].toInt() and 0xff) != 0x81) {
                    result["diagnostic"] = "Pas de réponse valide CCID à GetSlotStatus."
                    return result
                }
                val cardStatus = status[7].toInt() and 0x03
                result["carte"] = when (cardStatus) {
                    0 -> "Présente et active"
                    1 -> "Présente, non active"
                    2 -> "Absente"
                    else -> "État inconnu"
                }
                if ((status[7].toInt() and 0xC0) != 0) {
                    result["diagnostic"] = "Le lecteur signale une erreur de commande."
                } else if (cardStatus != 2) {
                    val power = exchange(connection, bulkOut, bulkIn, 0x62, 2)
                    if (power != null && power.size >= 10 && (power[0].toInt() and 0xff) == 0x80 &&
                        (power[7].toInt() and 0xC0) == 0) {
                        val length = readLength(power)
                        if (length in 1..64 && power.size >= 10 + length) {
                            result["ATR"] = power.copyOfRange(10, 10 + length).joinToString(" ") { "%02X".format(it.toInt() and 0xff) }
                        } else result["diagnostic"] = "Réponse CCID reçue sans ATR exploitable."
                    } else result["diagnostic"] = "Activation carte refusée ou non prise en charge."
                }
            } finally { connection.releaseInterface(ccid) }
        } finally { connection.close() }
        return result
    }


    private fun sendSafeApdu(manager: UsbManager, action: String): Map<String, Any?> {
        val command = when (action) {
            "select-mf" -> byteArrayOf(0, 0xA4.toByte(), 0, 0, 2, 0x3F, 0)
            "read-16" -> byteArrayOf(0, 0xB0.toByte(), 0, 0, 0x10)
            else -> return mapOf("erreur" to "Commande non autorisée")
        }
        for (device in manager.deviceList.values) {
            val ccid = (0 until device.interfaceCount).map { device.getInterface(it) }
                .firstOrNull { it.interfaceClass == 11 } ?: continue
            if (!manager.hasPermission(device)) {
                val intent = Intent(permissionAction).setPackage(packageName)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                manager.requestPermission(device, PendingIntent.getBroadcast(this, device.deviceId, intent, flags))
                return mapOf("erreur" to "Autorisation USB demandée : accepte puis recommence")
            }
            val output = (0 until ccid.endpointCount).map { ccid.getEndpoint(it) }
                .firstOrNull { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_OUT }
            val input = (0 until ccid.endpointCount).map { ccid.getEndpoint(it) }
                .firstOrNull { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_IN }
            if (output == null || input == null) continue
            val connection = manager.openDevice(device) ?: continue
            try {
                if (!connection.claimInterface(ccid, true)) continue
                try {
                    val slot = exchange(connection, output, input, 0x65, 11)
                    if (slot == null || slot.size < 10 || (slot[7].toInt() and 3) == 2) {
                        return mapOf("erreur" to "Carte absente ou lecteur indisponible")
                    }
                    // A CCID transport can require activation before XfrBlock.
                    val power = exchange(connection, output, input, 0x62, 12)
                    if (power == null || (power[7].toInt() and 0xC0) != 0) {
                        return mapOf("erreur" to "Activation carte impossible")
                    }
                    val packet = ByteArray(10 + command.size)
                    packet[0] = 0x6F
                    packet[1] = command.size.toByte()
                    packet[6] = 13
                    command.copyInto(packet, 10)
                    if (connection.bulkTransfer(output, packet, packet.size, 2500) != packet.size) {
                        return mapOf("erreur" to "Échec envoi CCID")
                    }
                    val buffer = ByteArray(4096)
                    val n = connection.bulkTransfer(input, buffer, buffer.size, 5000)
                    if (n < 12 || (buffer[0].toInt() and 255) != 0x80 ||
                        (buffer[6].toInt() and 255) != 13 || (buffer[7].toInt() and 0xC0) != 0) {
                        return mapOf("erreur" to "Réponse CCID invalide ou commande refusée")
                    }
                    val length = readLength(buffer)
                    if (length < 2 || length > n - 10) return mapOf("erreur" to "Longueur réponse invalide")
                    val data = buffer.copyOfRange(10, 10 + length)
                    fun hex(bytes: ByteArray) = bytes.joinToString(" ") { "%02X".format(it.toInt() and 255) }
                    return mapOf("lecteur" to device.deviceName, "action" to action,
                        "commande" to hex(command), "reponse" to hex(data),
                        "sw" to "%02X%02X".format(data[data.size - 2].toInt() and 255, data.last().toInt() and 255))
                } finally { connection.releaseInterface(ccid) }
            } finally { connection.close() }
        }
        return mapOf("erreur" to "Aucun lecteur CCID utilisable")
    }

    private fun readLength(bytes: ByteArray): Int =
        (bytes[1].toInt() and 255) or ((bytes[2].toInt() and 255) shl 8) or
        ((bytes[3].toInt() and 255) shl 16) or ((bytes[4].toInt() and 255) shl 24)

    private fun exchange(
        connection: android.hardware.usb.UsbDeviceConnection,
        out: UsbEndpoint, input: UsbEndpoint, command: Int, sequence: Int
    ): ByteArray? {
        val packet = byteArrayOf(command.toByte(), 0, 0, 0, 0, 0, sequence.toByte(), 0, 0, 0)
        if (connection.bulkTransfer(out, packet, packet.size, 2000) != packet.size) return null
        val buffer = ByteArray(512)
        val received = connection.bulkTransfer(input, buffer, buffer.size, 2500)
        if (received < 10) return null
        val data = buffer.copyOf(received)
        if ((data[6].toInt() and 255) != sequence) return null
        return data
    }
}
