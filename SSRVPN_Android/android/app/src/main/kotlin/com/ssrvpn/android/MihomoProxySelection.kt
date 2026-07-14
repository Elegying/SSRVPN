package com.ssrvpn.android

import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import org.json.JSONObject

internal object MihomoProxySelection {
    private const val TAG = "MihomoSelection"

    fun apply(apiPort: Int, apiSecret: String, nodeName: String?) {
        val selectedNode = nodeName?.takeIf { it.isNotBlank() && it != "SSRVPN" } ?: return
        if (apiSecret.isBlank()) {
            Log.d(TAG, "Skip proxy selection: API secret is only available from Flutter startup")
            return
        }
        val proxyOk = setProxyGroup(apiPort, apiSecret, "PROXY", selectedNode)
        val globalOk = setProxyGroup(apiPort, apiSecret, "GLOBAL", "PROXY") ||
            setProxyGroup(apiPort, apiSecret, "GLOBAL", selectedNode)
        if (proxyOk || globalOk) apiRequest(apiPort, apiSecret, "DELETE", "/connections", null)
        Log.d(TAG, "Applied proxy selection: PROXY=$proxyOk GLOBAL=$globalOk node=$selectedNode")
    }

    private fun setProxyGroup(
        apiPort: Int,
        apiSecret: String,
        groupName: String,
        targetName: String
    ): Boolean {
        val encodedGroup = URLEncoder.encode(groupName, "UTF-8").replace("+", "%20")
        val body = JSONObject().put("name", targetName).toString()
        val code = apiRequest(apiPort, apiSecret, "PUT", "/proxies/$encodedGroup", body)
        return code == 200 || code == 204
    }

    private fun apiRequest(
        apiPort: Int,
        apiSecret: String,
        method: String,
        path: String,
        body: String?
    ): Int {
        var connection: HttpURLConnection? = null
        return try {
            val conn = (URL("http://127.0.0.1:$apiPort$path").openConnection() as HttpURLConnection)
                .apply {
                    requestMethod = method
                    connectTimeout = 1500
                    readTimeout = 1500
                    if (apiSecret.isNotBlank()) {
                        setRequestProperty("Authorization", "Bearer $apiSecret")
                    }
                    if (body != null) {
                        doOutput = true
                        setRequestProperty("Content-Type", "application/json")
                    }
                }
            connection = conn
            if (body != null) {
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val code = conn.responseCode
            runCatching {
                (if (code >= 400) conn.errorStream else conn.inputStream)?.close()
            }
            code
        } catch (e: Exception) {
            Log.d(TAG, "API $method $path failed: ${e.message}")
            -1
        } finally {
            connection?.disconnect()
        }
    }
}
