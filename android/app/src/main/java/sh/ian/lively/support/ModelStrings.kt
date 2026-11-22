package sh.ian.lively.support

import android.content.res.Resources
import androidx.annotation.StringRes
import sh.ian.lively.R

/** Application resources for messages produced outside Compose, including background audio errors. */
internal var modelResources: Resources? = null

internal inline fun modelString(@StringRes id: Int, vararg args: Any, english: () -> String): String =
    modelResources?.let { if (args.isEmpty()) it.getString(id) else it.getString(id, *args) } ?: english()

/** The broker sends English messages. Preserve details from newer servers until a translation ships. */
internal fun String.localizedBrokerMessage(): String {
    val id = when (this) {
        "Enter the 6-digit code from the email." -> R.string.bad_code
        "Enter a valid email address." -> R.string.bad_email
        "Couldn't sign you in. Try again." -> R.string.bad_identity_token
        "Lively has reached today's capacity. Try again later." -> R.string.capacity_limit
        "Today's translation time is used up." -> R.string.daily_pro_limit
        "Couldn't send the code. Try again." -> R.string.email_failed
        "That code has expired. Ask for a new one." -> R.string.expired_code
        "Today's free text translations are used up." -> R.string.free_text_limit
        "Google sign-in isn't available right now." -> R.string.google_unavailable
        "Too many requests this minute." -> R.string.minute_limit
        "That account didn't share a verified email. Sign in with an emailed code instead." -> R.string.no_verified_email
        "Today's text translations are used up." -> R.string.pro_text_limit
        "Review sign-in is temporarily unavailable." -> R.string.review_unavailable
        "You've been signed out. Sign in again in Settings." -> R.string.signed_out
        "Today's free translation time is used up." -> R.string.todays_free_translation_time_is_used_up
        "Too many codes. Try again later." -> R.string.too_many_codes
        "The translation service didn't answer." -> R.string.translation_service_no_response
        "Couldn't reach the translation service." -> R.string.translation_service_unreachable
        "Lively can't send email to that address." -> R.string.undeliverable_email
        "That code isn't right." -> R.string.wrong_code
        else -> return this
    }
    return modelResources?.getString(id) ?: this
}
