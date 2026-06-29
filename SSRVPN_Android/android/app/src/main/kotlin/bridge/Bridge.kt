package bridge

object Bridge {
    init {
        System.loadLibrary("gojni")
    }

    @JvmStatic external fun init(homeDir: String, configFile: String)
    @JvmStatic external fun initProtect(): Long
    @JvmStatic external fun setProtectResult(ok: Boolean)
    @JvmStatic external fun start(configPath: String, tunFd: Long): String
    @JvmStatic external fun stop()
    @JvmStatic external fun isRunning(): Boolean
}
