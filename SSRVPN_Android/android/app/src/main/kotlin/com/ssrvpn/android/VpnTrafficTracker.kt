package com.ssrvpn.android

internal data class VpnTrafficSnapshot(
    val uploadRate: Long,
    val downloadRate: Long,
    val sessionUpload: Long,
    val sessionDownload: Long
)

internal class VpnTrafficTracker(
    private val readTransmittedBytes: () -> Long,
    private val readReceivedBytes: () -> Long,
    private val elapsedRealtime: () -> Long
) {
    private var baselineTx = 0L
    private var baselineRx = 0L
    private var lastTx = 0L
    private var lastRx = 0L
    private var lastSampleAt = 0L
    private var uploadRate = 0L
    private var downloadRate = 0L

    fun reset() {
        val tx = readTransmittedBytes().coerceAtLeast(0L)
        val rx = readReceivedBytes().coerceAtLeast(0L)
        baselineTx = tx
        baselineRx = rx
        resetSample(tx, rx)
    }

    fun resetSample() = resetSample(
        readTransmittedBytes().coerceAtLeast(0L),
        readReceivedBytes().coerceAtLeast(0L)
    )

    fun update(bytesPerSecond: (Long, Long) -> Long) {
        val now = elapsedRealtime()
        val tx = readTransmittedBytes().coerceAtLeast(0L)
        val rx = readReceivedBytes().coerceAtLeast(0L)
        val elapsedMillis = (now - lastSampleAt).coerceAtLeast(0L)
        uploadRate = bytesPerSecond((tx - lastTx).coerceAtLeast(0L), elapsedMillis)
        downloadRate = bytesPerSecond((rx - lastRx).coerceAtLeast(0L), elapsedMillis)
        lastTx = tx
        lastRx = rx
        lastSampleAt = now
    }

    fun snapshot() = VpnTrafficSnapshot(
        uploadRate = uploadRate,
        downloadRate = downloadRate,
        sessionUpload = (lastTx - baselineTx).coerceAtLeast(0L),
        sessionDownload = (lastRx - baselineRx).coerceAtLeast(0L)
    )

    private fun resetSample(tx: Long, rx: Long) {
        lastTx = tx
        lastRx = rx
        lastSampleAt = elapsedRealtime()
        uploadRate = 0L
        downloadRate = 0L
    }
}
