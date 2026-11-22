package sh.ian.lively.model

import sh.ian.lively.support.localizedBrokerMessage
import sh.ian.lively.R
import sh.ian.lively.support.modelString
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import sh.ian.lively.net.ResilientSocket
import sh.ian.lively.net.bool
import sh.ian.lively.net.fetch
import sh.ian.lively.net.obj
import sh.ian.lively.net.string
import sh.ian.lively.support.Preferences
import sh.ian.lively.support.SecretStore
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Optional sign-in with Google or an emailed code, through Lively's key broker
 * (`Server/key-broker/src/auth.ts` and `identity.ts`). A signed-in app sends its session token
 * with key requests and gets a per-account listening budget instead of the
 * per-install one.
 *
 * The token and email are kept in the secret store. Some accounts get Lively
 * Pro for free ([hasFreePro]); the broker sets that, and the app reads it
 * back at sign-in and at launch.
 */
class Account(
    brokerURL: String,
    private val secrets: SecretStore,
    private val prefs: Preferences,
    private val scope: CoroutineScope,
    /** Demo mode never reaches the broker: any email gets a code, the code is 123456, and Sign in with Google skips Google. */
    val isDemo: () -> Boolean,
    /** The OAuth web client ID for Sign in with Google; null when the build has none. */
    val googleClientID: String? = null,
    baseClient: OkHttpClient = ResilientSocket.sharedClient,
) {
    class AccountException(message: String) : Exception(message)

    private val base = brokerURL.trimEnd('/')
    private val client = baseClient.newBuilder().callTimeout(15, TimeUnit.SECONDS).build()

    /** The broker's plan for this account changed, so a spare key minted on the old one is stale. */
    var onPlanChange: () -> Unit = {}

    var token: String? = secrets.read(TOKEN_ACCOUNT)
        private set
    var email by mutableStateOf(if (token == null) null else secrets.read(EMAIL_ACCOUNT))
        private set
    var hasFreePro by mutableStateOf(token != null && prefs.bool(FREE_PRO_KEY))
        private set

    val isSignedIn: Boolean get() = email != null

    /** Whether to show Sign in with Google: the build has a client ID, or it's demo mode. */
    val offersGoogle: Boolean get() = googleClientID != null || isDemo()

    /** Emails a 6-digit code to [email]. */
    suspend fun sendCode(email: String) {
        if (isDemo()) {
            delay(600)
            return
        }
        post("v1/auth/email/start", mapOf("email" to email))
    }

    suspend fun signIn(email: String, code: String) {
        if (isDemo()) {
            delay(600)
            if (code != "123456") throw AccountException(modelString(R.string.that_code_didnt_work_try_again) { "That code didn't work. Try again." })
            this.email = email
            return
        }
        adopt(post("v1/auth/email/verify", mapOf("email" to email, "code" to code)), email)
    }

    /**
     * Signs in with the ID token Sign in with Google returned. [nonce] is the
     * value the request carried.
     */
    suspend fun signInWithGoogle(idToken: String, nonce: String) {
        if (isDemo()) {
            delay(600)
            email = "demo@example.com"
            return
        }
        adopt(post("v1/auth/google", mapOf("id_token" to idToken, "nonce" to nonce)), null)
    }

    private fun adopt(body: JsonObject, email: String?) {
        val newToken = body.string("token") ?: throw AccountException(modelString(R.string.something_went_wrong_try_again) { "Something went wrong. Try again." })
        val user = body.obj("user")
        val confirmed = user?.string("email") ?: email ?: throw AccountException(modelString(R.string.something_went_wrong_try_again) { "Something went wrong. Try again." })
        secrets.write(newToken, TOKEN_ACCOUNT)
        secrets.write(confirmed, EMAIL_ACCOUNT)
        token = newToken
        this.email = confirmed
        setFreePro(user?.bool("free_pro") ?: false)
    }

    /**
     * Rereads the account from the broker, which may have granted or taken
     * away free Pro. Signs out if the session has ended.
     */
    suspend fun refresh() {
        val token = token ?: return
        if (isDemo()) return
        val request = Request.Builder().url("$base/v1/auth/me").header("Authorization", "Bearer $token").build()
        val response = runCatching { client.fetch(request) }.getOrNull() ?: return
        if (response.code == 401) {
            tokenWasRejected(token)
        } else if (response.code == 200) {
            val body = runCatching { Json.parseToJsonElement(response.body) as? JsonObject }.getOrNull()
            body?.obj("user")?.let { setFreePro(it.bool("free_pro") ?: false) }
        }
    }

    /** Deletes the account on the broker, then signs out here. */
    suspend fun deleteAccount() {
        val token = token
        if (token != null && !isDemo()) {
            val request = Request.Builder().url("$base/v1/auth/delete")
                .header("Authorization", "Bearer $token")
                .post(ByteArray(0).toRequestBody())
                .build()
            val response = try {
                client.fetch(request)
            } catch (e: IOException) {
                throw AccountException(modelString(R.string.lively_unreachable) { "Couldn't reach Lively. Check your connection and try again." })
            }
            // 401: the session, and so maybe the account, is already gone.
            if (response.code != 200 && response.code != 401) {
                throw AccountException(brokerMessage(response.body) ?: modelString(R.string.couldnt_delete_your_account_try_again) { "Couldn't delete your account. Try again." })
            }
        }
        forget()
    }

    fun signOut() {
        token?.let { token ->
            val request = Request.Builder().url("$base/v1/auth/logout")
                .header("Authorization", "Bearer $token")
                .post(ByteArray(0).toRequestBody())
                .build()
            scope.launch { runCatching { client.fetch(request) } }
        }
        forget()
    }

    /** The broker no longer accepts the token, so sign out locally. */
    fun tokenWasRejected(rejected: String) {
        if (token == rejected) forget()
    }

    private fun setFreePro(value: Boolean) {
        if (value == hasFreePro) return
        hasFreePro = value
        prefs.putBool(FREE_PRO_KEY, value)
        onPlanChange()
    }

    private fun forget() {
        secrets.write(null, TOKEN_ACCOUNT)
        secrets.write(null, EMAIL_ACCOUNT)
        token = null
        email = null
        setFreePro(false)
    }

    private suspend fun post(path: String, fields: Map<String, String>): JsonObject {
        val body = buildJsonObject { fields.forEach { (k, v) -> put(k, v) } }.toString()
        val request = Request.Builder().url("$base/$path")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()
        val response = try {
            client.fetch(request)
        } catch (e: IOException) {
            throw AccountException(modelString(R.string.lively_unreachable) { "Couldn't reach Lively. Check your connection and try again." })
        }
        if (response.code != 200) throw AccountException(brokerMessage(response.body) ?: modelString(R.string.something_went_wrong_try_again) { "Something went wrong. Try again." })
        return runCatching { Json.parseToJsonElement(response.body) as JsonObject }.getOrElse { JsonObject(emptyMap()) }
    }

    private fun brokerMessage(body: String): String? =
        runCatching { (Json.parseToJsonElement(body) as JsonObject).string("message")?.localizedBrokerMessage() }.getOrNull()

    companion object {
        /**
         * Sign in with Apple's Hide My Email gives the account a relay address,
         * which means nothing to the person, so the app doesn't show it.
         */
        fun hidesEmail(email: String): Boolean = email.lowercase().endsWith("@privaterelay.appleid.com")

        /** What to call the account: its email, unless Apple hides it. */
        fun displayName(email: String): String = if (hidesEmail(email)) modelString(R.string.apple_account) { "Apple Account" } else email

        private const val TOKEN_ACCOUNT = "lively-session-token"
        private const val EMAIL_ACCOUNT = "lively-account-email"
        private const val FREE_PRO_KEY = "LivelyAccountFreePro"
    }
}
