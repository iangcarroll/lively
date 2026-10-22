package sh.ian.lively.support

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.edit
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Plain settings, like `UserDefaults`. */
interface Preferences {
    fun string(key: String): String?
    fun putString(key: String, value: String?)
    fun bool(key: String, default: Boolean = false): Boolean
    fun putBool(key: String, value: Boolean)
    fun int(key: String, default: Int = 0): Int
    fun putInt(key: String, value: Int)
}

/** Secrets: API keys, the session token, the install ID. Like the Keychain. */
interface SecretStore {
    fun read(account: String): String?
    fun write(value: String?, account: String)
}

class SharedPreferencesStore(private val prefs: SharedPreferences) : Preferences {
    override fun string(key: String): String? = prefs.getString(key, null)
    override fun putString(key: String, value: String?) = prefs.edit { if (value == null) remove(key) else putString(key, value) }
    override fun bool(key: String, default: Boolean) = prefs.getBoolean(key, default)
    override fun putBool(key: String, value: Boolean) = prefs.edit { putBoolean(key, value) }
    override fun int(key: String, default: Int) = prefs.getInt(key, default)
    override fun putInt(key: String, value: Int) = prefs.edit { putInt(key, value) }
}

/**
 * Values encrypted with an AES-GCM key that never leaves the Android
 * Keystore, kept in a private preferences file that isn't backed up.
 */
class KeystoreSecretStore(context: Context) : SecretStore {
    private val prefs = context.getSharedPreferences("lively.secrets", Context.MODE_PRIVATE)

    override fun read(account: String): String? {
        val stored = prefs.getString(account, null) ?: return null
        return runCatching {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_LENGTH))
            String(cipher.doFinal(bytes, IV_LENGTH, bytes.size - IV_LENGTH), Charsets.UTF_8)
        }.getOrNull()
    }

    override fun write(value: String?, account: String) {
        if (value == null) {
            prefs.edit { remove(account) }
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit { putString(account, Base64.encodeToString(sealed, Base64.NO_WRAP)) }
    }

    @Synchronized
    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "lively-secrets"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
    }
}

/** For tests and previews. */
class MemoryStore : Preferences, SecretStore {
    private val values = mutableMapOf<String, Any>()
    override fun string(key: String) = values[key] as? String
    override fun putString(key: String, value: String?) { if (value == null) values.remove(key) else values[key] = value }
    override fun bool(key: String, default: Boolean) = values[key] as? Boolean ?: default
    override fun putBool(key: String, value: Boolean) { values[key] = value }
    override fun int(key: String, default: Int) = values[key] as? Int ?: default
    override fun putInt(key: String, value: Int) { values[key] = value }
    override fun read(account: String) = string("secret:$account")
    override fun write(value: String?, account: String) = putString("secret:$account", value)
}
