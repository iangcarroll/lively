package sh.ian.lively.support

import sh.ian.lively.R
import sh.ian.lively.support.modelString
import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import java.util.UUID

/**
 * Sign in with Google through Credential Manager: Android's counterpart to
 * Sign in with Apple on iOS (`SignInWithAppleButton` in `AccountView.swift`).
 * The system shows its account sheet and returns an ID token, which the key
 * broker checks (`Server/key-broker/src/identity.ts`).
 */
object GoogleSignIn {
    class Result(val idToken: String, val nonce: String)

    class Failed(message: String) : Exception(message)

    /**
     * Shows Google's sheet over [activity]. Null if the person closed it.
     * [clientID] is the OAuth web client ID the broker also knows.
     */
    suspend fun request(activity: Context, clientID: String): Result? {
        val nonce = UUID.randomUUID().toString() + UUID.randomUUID().toString()
        val option = GetSignInWithGoogleOption.Builder(clientID).setNonce(nonce).build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val credential = try {
            CredentialManager.create(activity).getCredential(activity, request).credential
        } catch (e: GetCredentialCancellationException) {
            return null
        } catch (e: GetCredentialException) {
            throw Failed(modelString(R.string.google_sign_in_failed_email_fallback) { "Couldn't sign in with Google. Try again, or use your email." })
        }
        if (credential !is CustomCredential || credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
            throw Failed(modelString(R.string.google_sign_in_failed_email_fallback) { "Couldn't sign in with Google. Try again, or use your email." })
        }
        val token = runCatching { GoogleIdTokenCredential.createFrom(credential.data).idToken }
            .getOrElse { throw Failed(modelString(R.string.google_sign_in_failed_email_fallback) { "Couldn't sign in with Google. Try again, or use your email." }) }
        return Result(token, nonce)
    }
}
