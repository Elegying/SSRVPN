package com.ssrvpn.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Atomic cold-start snapshot for the quick-settings tile and sticky service.
 * The complete config identity and API credential are encrypted together with
 * a non-exportable Android Keystore key, so native starts never mix versions.
 */
internal object NativeConnectionSnapshotStore {
    private const val TAG = "NativeConnectionSnapshot"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "ssrvpn_native_connection_snapshot_v1"
    private const val STORAGE_NAME = "ssrvpn_native_connection_snapshot"
    private const val CIPHERTEXT_KEY = "snapshot_ciphertext"
    private const val IV_KEY = "snapshot_iv"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_LENGTH_BITS = 128

    fun write(context: Context, snapshot: NativeConnectionSnapshot) {
        require(snapshot.configDir.isNotBlank()) { "Missing config directory" }
        require(snapshot.configPath.isNotBlank()) { "Missing config path" }
        require(snapshot.apiPort in 1..65535) { "Invalid API port" }
        require(snapshot.apiSecret.isNotBlank()) { "Missing API credential" }

        val plaintext = NativeConnectionSnapshotCodec.encode(snapshot)
        val encrypted = try {
            encrypt(plaintext, getOrCreateKey())
        } catch (_: KeyPermanentlyInvalidatedException) {
            deleteKey()
            encrypt(plaintext, getOrCreateKey())
        }
        val committed = preferences(context).edit()
            .putString(
                CIPHERTEXT_KEY,
                Base64.encodeToString(encrypted.ciphertext, Base64.NO_WRAP)
            )
            .putString(IV_KEY, Base64.encodeToString(encrypted.iv, Base64.NO_WRAP))
            .commit()
        check(committed) { "Unable to persist the native connection snapshot" }
    }

    fun read(context: Context): NativeConnectionSnapshot? {
        val prefs = preferences(context)
        val ciphertextValue = prefs.getString(CIPHERTEXT_KEY, null) ?: return null
        val ivValue = prefs.getString(IV_KEY, null) ?: return null
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(
                    GCM_TAG_LENGTH_BITS,
                    Base64.decode(ivValue, Base64.NO_WRAP)
                )
            )
            NativeConnectionSnapshotCodec.decode(
                cipher.doFinal(Base64.decode(ciphertextValue, Base64.NO_WRAP))
            )
        } catch (error: Exception) {
            // Preserve the ciphertext: transient Keystore failures must not
            // destroy the last known-good cold-start snapshot.
            Log.e(TAG, "Unable to decrypt the native connection snapshot", error)
            null
        }
    }

    fun updateSelectedNode(context: Context, nodeName: String) {
        val current = checkNotNull(read(context)) {
            "Native connection snapshot is unavailable"
        }
        write(context, current.copy(selectedNodeName = nodeName))
    }

    fun clear(context: Context) {
        check(preferences(context).edit().clear().commit()) {
            "Unable to clear the native connection snapshot"
        }
        deleteKey()
    }

    private fun encrypt(plaintext: ByteArray, key: SecretKey): EncryptedValue {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        return EncryptedValue(cipher.doFinal(plaintext), cipher.iv)
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

    private fun deleteKey() {
        KeyStore.getInstance(KEYSTORE).apply {
            load(null)
            deleteEntry(KEY_ALIAS)
        }
    }

    private data class EncryptedValue(
        val ciphertext: ByteArray,
        val iv: ByteArray
    )
}
