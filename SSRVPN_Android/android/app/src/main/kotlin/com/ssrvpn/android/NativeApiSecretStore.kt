package com.ssrvpn.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Native-only fallback for VPN starts that happen without a Flutter engine.
 * The value is encrypted with a non-exportable Android Keystore key; only the
 * ciphertext and IV are stored in app-private preferences.
 */
internal object NativeApiSecretStore {
    private const val TAG = "NativeApiSecretStore"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "ssrvpn_native_api_secret_v1"
    private const val STORAGE_NAME = "ssrvpn_native_secrets"
    private const val CIPHERTEXT_KEY = "api_secret_ciphertext"
    private const val IV_KEY = "api_secret_iv"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_LENGTH_BITS = 128

    fun write(context: Context, secret: String) {
        if (secret.isBlank()) {
            clear(context)
            return
        }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val ciphertext = cipher.doFinal(secret.toByteArray(StandardCharsets.UTF_8))
        val committed = preferences(context).edit()
            .putString(CIPHERTEXT_KEY, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            .putString(IV_KEY, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .commit()
        check(committed) { "Unable to persist the native API credential" }
    }

    fun read(context: Context): String? {
        val prefs = preferences(context)
        val ciphertextValue = prefs.getString(CIPHERTEXT_KEY, null) ?: return null
        val ivValue = prefs.getString(IV_KEY, null) ?: return null
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, Base64.decode(ivValue, Base64.NO_WRAP))
            )
            String(
                cipher.doFinal(Base64.decode(ciphertextValue, Base64.NO_WRAP)),
                StandardCharsets.UTF_8
            ).takeIf { it.isNotBlank() }
        } catch (error: Exception) {
            Log.e(TAG, "Unable to decrypt the native API credential", error)
            clear(context)
            null
        }
    }

    private fun clear(context: Context) {
        preferences(context).edit()
            .remove(CIPHERTEXT_KEY)
            .remove(IV_KEY)
            .apply()
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(STORAGE_NAME, Context.MODE_PRIVATE)

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
            generateKey()
        }
    }
}
