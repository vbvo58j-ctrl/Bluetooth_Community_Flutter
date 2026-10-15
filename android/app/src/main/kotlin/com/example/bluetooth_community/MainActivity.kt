package com.example.bluetooth_community

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val methodName = "app.bluetooth.community/methods"
    private val eventName = "app.bluetooth.community/events"
    private val serviceUuid: UUID = UUID.fromString("0f6b2b90-9a12-4d47-a6e3-5e15c2d4a901")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private var eventSink: EventChannel.EventSink? = null
    private var adapter: BluetoothAdapter? = null
    private var serverSocket: BluetoothServerSocket? = null
    private var roomCode = ""
    private var userName = "مستخدم"
    private var hosting = false
    private var connected = false
    private val alive = AtomicBoolean(false)
    private val sockets = CopyOnWriteArrayList<BluetoothSocket>()
    private val outputs = CopyOnWriteArrayList<OutputStream>()
    private val deviceReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BluetoothDevice.ACTION_FOUND) {
                val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
                val name = try { device.name ?: "جهاز بلوتوث" } catch (_: SecurityException) { "جهاز بلوتوث" }
                emit(mapOf("type" to "device", "name" to name, "address" to device.address))
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        adapter = BluetoothAdapter.getDefaultAdapter()
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventName).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
            override fun onCancel(arguments: Any?) { eventSink = null }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startHost" -> {
                    if (!hasPermissions()) { requestBluetoothPermissions(); result.error("PERMISSION", "امنح أذونات البلوتوث ثم أعد المحاولة", null); return@setMethodCallHandler }
                    roomCode = call.argument<String>("code") ?: ""
                    userName = call.argument<String>("name") ?: "منشئ المجموعة"
                    startHost(result)
                }
                "discover" -> {
                    if (!hasPermissions()) { requestBluetoothPermissions(); result.error("PERMISSION", "امنح أذونات البلوتوث ثم أعد المحاولة", null); return@setMethodCallHandler }
                    discover(result)
                }
                "connect" -> {
                    if (!hasPermissions()) { requestBluetoothPermissions(); result.error("PERMISSION", "امنح أذونات البلوتوث ثم أعد المحاولة", null); return@setMethodCallHandler }
                    val address = call.argument<String>("address") ?: ""
                    val code = call.argument<String>("code") ?: ""
                    userName = call.argument<String>("name") ?: "مشارك"
                    connect(address, code, result)
                }
                "sendMessage" -> {
                    val text = call.argument<String>("text") ?: ""
                    val sender = call.argument<String>("sender") ?: userName
                    sendPacket(JSONObject().put("type", "message").put("sender", sender).put("text", text))
                    result.success(null)
                }
                "sendFile" -> {
                    val data = call.argument<String>("data") ?: ""
                    val name = call.argument<String>("name") ?: "file"
                    val sender = call.argument<String>("sender") ?: userName
                    sendPacket(JSONObject().put("type", "file").put("sender", sender).put("name", name).put("data", data))
                    result.success(null)
                }
                "disconnect" -> { stopConnections(); result.success(null) }
                "saveFile" -> {
                    val name = call.argument<String>("name") ?: "received_file"
                    val data = call.argument<String>("data") ?: ""
                    try {
                        val folder = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
                        val safeName = File(name).name
                        val out = File(folder, safeName)
                        out.writeBytes(android.util.Base64.decode(data, android.util.Base64.DEFAULT))
                        result.success(out.absolutePath)
                    } catch (e: Exception) { result.error("SAVE", e.message, null) }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url") ?: "https://wsend.co/967737414884"
                    try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))); result.success(null) }
                    catch (e: Exception) { result.error("URL", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermissions(): Boolean {
        val permissions = if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        } else if (Build.VERSION.SDK_INT >= 23) {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        } else emptyArray()
        return permissions.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }
    }
    private fun requestBluetoothPermissions() {
        val permissions = if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        } else if (Build.VERSION.SDK_INT >= 23) {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        } else emptyArray()
        if (permissions.isNotEmpty()) ActivityCompat.requestPermissions(this, permissions, 400)
    }
    private fun ensureBluetooth(): Boolean {
        val a = adapter ?: return false
        if (!a.isEnabled) { startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)); return false }
        return true
    }
    private fun emit(event: Map<String, Any?>) { mainHandler.post { eventSink?.success(event) } }
    private fun state(message: String, isConnected: Boolean) {
        connected = isConnected
        emit(mapOf("type" to "state", "message" to message, "connected" to isConnected))
    }

    private fun startHost(result: MethodChannel.Result) {
        if (!ensureBluetooth()) { result.error("BLUETOOTH_OFF", "شغّل البلوتوث ثم أعد المحاولة", null); return }
        stopConnections()
        hosting = true; alive.set(true)
        try {
            val discoverable = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
            discoverable.putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300)
            startActivity(discoverable)
        } catch (_: Exception) {}
        io.execute {
            try {
                serverSocket = adapter!!.listenUsingRfcommWithServiceRecord("Wasl-$roomCode", serviceUuid)
                state("الغرفة جاهزة • الرمز $roomCode • بانتظار الأعضاء", true)
                result.success(null)
                while (alive.get()) {
                    val socket = serverSocket?.accept() ?: break
                    io.execute { handleHostClient(socket) }
                }
            } catch (e: Exception) {
                if (alive.get()) emit(mapOf("type" to "error", "message" to "تعذر تشغيل الغرفة: ${e.message}"))
                mainHandler.post { if (alive.get()) result.error("HOST", e.message, null) }
            }
        }
    }

    private fun handleHostClient(socket: BluetoothSocket) {
        try {
            val input = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
            val out = socket.outputStream
            val hello = input.readLine() ?: run { socket.close(); return }
            val packet = JSONObject(hello)
            if (packet.optString("type") != "join" || packet.optString("code") != roomCode) {
                out.write((JSONObject().put("type", "reject").put("reason", "رمز الاقتران غير صحيح").toString() + "\n").toByteArray(Charsets.UTF_8))
                out.flush(); socket.close(); return
            }
            sockets.add(socket); outputs.add(out)
            out.write((JSONObject().put("type", "accepted").put("room", roomCode).toString() + "\n").toByteArray(Charsets.UTF_8)); out.flush()
            emit(mapOf("type" to "message", "sender" to "النظام", "text" to "${packet.optString("name", "عضو")} انضم إلى الغرفة"))
            while (alive.get() && !socket.isClosed) {
                val line = input.readLine() ?: break
                val incoming = JSONObject(line)
                if (incoming.optString("type") == "message" || incoming.optString("type") == "file") {
                    broadcast(incoming, out)
                    emitPacket(incoming)
                }
            }
        } catch (_: Exception) {
        } finally {
            sockets.remove(socket)
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun discover(result: MethodChannel.Result) {
        if (!ensureBluetooth()) { result.error("BLUETOOTH_OFF", "شغّل البلوتوث ثم أعد المحاولة", null); return }
        try {
            try { unregisterReceiver(deviceReceiver) } catch (_: Exception) {}
            registerReceiver(deviceReceiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
            adapter?.cancelDiscovery()
            val ok = adapter?.startDiscovery() ?: false
            if (ok) result.success(null) else result.error("DISCOVERY", "لم يبدأ البحث. تحقق من أذونات البلوتوث.", null)
        } catch (e: Exception) { result.error("DISCOVERY", e.message, null) }
    }

    private fun connect(address: String, code: String, result: MethodChannel.Result) {
        if (!ensureBluetooth()) { result.error("BLUETOOTH_OFF", "شغّل البلوتوث ثم أعد المحاولة", null); return }
        stopConnections()
        hosting = false; alive.set(true)
        io.execute {
            var socket: BluetoothSocket? = null
            try {
                adapter?.cancelDiscovery()
                socket = adapter!!.getRemoteDevice(address).createRfcommSocketToServiceRecord(serviceUuid)
                socket.connect()
                val input = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
                val out = socket.outputStream
                out.write((JSONObject().put("type", "join").put("code", code).put("name", userName).toString() + "\n").toByteArray(Charsets.UTF_8)); out.flush()
                val response = JSONObject(input.readLine() ?: throw Exception("لم يصل رد من المنشئ"))
                if (response.optString("type") != "accepted") throw Exception(response.optString("reason", "رمز الاقتران غير صحيح"))
                sockets.add(socket); outputs.add(out)
                state("متصل بالغرفة $code", true)
                mainHandler.post { result.success(null) }
                while (alive.get() && !socket.isClosed) {
                    val line = input.readLine() ?: break
                    emitPacket(JSONObject(line))
                }
            } catch (e: Exception) {
                try { socket?.close() } catch (_: Exception) {}
                state("فشل الاتصال", false)
                mainHandler.post { result.error("CONNECT", e.message ?: "تعذر الاتصال", null) }
            } finally {
                socket?.let { sockets.remove(it) }
                if (alive.get() && !hosting) state("انقطع الاتصال", false)
            }
        }
    }

    private fun sendPacket(packet: JSONObject) {
        if (!connected) { emit(mapOf("type" to "error", "message" to "لا يوجد اتصال نشط")); return }
        try {
            val bytes = (packet.toString() + "\n").toByteArray(Charsets.UTF_8)
            if (hosting) {
                broadcast(packet, null)
                emitPacket(packet)
            } else {
                val out = outputs.firstOrNull() ?: throw Exception("قناة الاتصال غير جاهزة")
                synchronized(out) { out.write(bytes); out.flush() }
            }
        } catch (e: Exception) { emit(mapOf("type" to "error", "message" to "فشل الإرسال: ${e.message}")) }
    }

    private fun broadcast(packet: JSONObject, exclude: OutputStream?) {
        val bytes = (packet.toString() + "\n").toByteArray(Charsets.UTF_8)
        outputs.forEach { out ->
            if (out !== exclude) try { synchronized(out) { out.write(bytes); out.flush() } } catch (_: Exception) {}
        }
    }
    private fun emitPacket(p: JSONObject) {
        when (p.optString("type")) {
            "message" -> emit(mapOf("type" to "message", "sender" to p.optString("sender", "عضو"), "text" to p.optString("text", "")))
            "file" -> emit(mapOf("type" to "file", "sender" to p.optString("sender", "عضو"), "name" to p.optString("name", "file"), "data" to p.optString("data", "")))
        }
    }

    private fun stopConnections() {
        alive.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        sockets.forEach { try { it.close() } catch (_: Exception) {} }
        sockets.clear(); outputs.clear()
        connected = false
    }

    override fun onDestroy() {
        stopConnections()
        try { unregisterReceiver(deviceReceiver) } catch (_: Exception) {}
        io.shutdownNow()
        super.onDestroy()
    }
}
