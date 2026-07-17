package com.ssrvpn.android

internal object NativeApiSecretResolver {
    fun resolve(explicitSecret: String?, storedSecret: String?): String =
        explicitSecret?.takeIf { it.isNotBlank() }
            ?: storedSecret?.takeIf { it.isNotBlank() }
            ?: ""
}
