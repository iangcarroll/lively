package sh.ian.lively.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Language as LanguageGlobe
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.TranslationState
import sh.ian.lively.model.Utterance

/**
 * Lively's colors, the same as the iOS asset catalog's. English (the pair's
 * first language) is always indigo and the second always vermilion, in both
 * light and dark, so each reader can find their language at a glance.
 */
@Immutable
data class LivelyColors(
    val canvas: Color,
    val card: Color,
    val firstInk: Color,
    val secondInk: Color,
    val live: Color,
    val warning: Color,
    val danger: Color,
)

private val Light = LivelyColors(
    canvas = Color(0xFFF7F7FA),
    card = Color.White,
    firstInk = Color(0xFF3D4FD6),
    secondInk = Color(0xFFD6452F),
    live = Color(0xFF2FA84F),
    warning = Color(0xFFE08A00),
    danger = Color(0xFFD93025),
)

private val Dark = LivelyColors(
    canvas = Color(0xFF0A0A0C),
    card = Color(0xFF1C1C20),
    firstInk = Color(0xFF96A3FF),
    secondInk = Color(0xFFFF8B73),
    live = Color(0xFF4CD964),
    warning = Color(0xFFFFB340),
    danger = Color(0xFFFF6B5E),
)

/** The light-mode first-language ink; the welcome page is always dark. */
val WelcomeInk = Color(0xFF3D4FD6)

private val LightScheme = lightColorScheme(
    primary = Color(0xFF5856D6),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE3E1FF),
    onPrimaryContainer = Color(0xFF1A1873),
    secondaryContainer = Color(0xFFE8E7F7),
    onSecondaryContainer = Color(0xFF26254A),
    background = Light.canvas,
    onBackground = Color(0xFF1B1B1F),
    surface = Light.canvas,
    onSurface = Color(0xFF1B1B1F),
    surfaceVariant = Color(0xFFE6E5EE),
    onSurfaceVariant = Color(0xFF5E5E68),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color.White,
    surfaceContainer = Color(0xFFF0F0F5),
    surfaceContainerHigh = Color(0xFFEBEBF1),
    surfaceContainerHighest = Color(0xFFE4E4EB),
    outline = Color(0xFFC7C6D2),
    outlineVariant = Color(0xFFE2E1EA),
    error = Light.danger,
)

private val DarkScheme = darkColorScheme(
    primary = Color(0xFFA9A8FF),
    onPrimary = Color(0xFF1F1D7A),
    primaryContainer = Color(0xFF3D3BB0),
    onPrimaryContainer = Color(0xFFE3E1FF),
    secondaryContainer = Color(0xFF2E2D45),
    onSecondaryContainer = Color(0xFFE3E1FF),
    background = Dark.canvas,
    onBackground = Color(0xFFE6E5EC),
    surface = Dark.canvas,
    onSurface = Color(0xFFE6E5EC),
    surfaceVariant = Color(0xFF2A2A31),
    onSurfaceVariant = Color(0xFFA4A3AF),
    surfaceContainerLowest = Color(0xFF050506),
    surfaceContainerLow = Dark.card,
    surfaceContainer = Color(0xFF202026),
    surfaceContainerHigh = Color(0xFF26262D),
    surfaceContainerHighest = Color(0xFF2E2E36),
    outline = Color(0xFF55555F),
    outlineVariant = Color(0xFF34343C),
    error = Dark.danger,
)

private val LocalLivelyColors = staticCompositionLocalOf { Light }

/**
 * The listener's language in an Automatic conversation, and null with a pair.
 * The Swift app reads this from its shared settings; here the theme carries it.
 */
private val LocalAutomaticListener = compositionLocalOf<Language?> { null }

object Lively {
    val colors: LivelyColors
        @Composable @ReadOnlyComposable get() = LocalLivelyColors.current
}

@Composable
fun LivelyTheme(
    dark: Boolean = isSystemInDarkTheme(),
    /** Set while the conversation detects the other language; see [ink]. */
    automaticListener: Language? = null,
    content: @Composable () -> Unit,
) {
    val scheme: ColorScheme = if (dark) DarkScheme else LightScheme
    CompositionLocalProvider(
        LocalLivelyColors provides if (dark) Dark else Light,
        LocalAutomaticListener provides automaticListener,
    ) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/**
 * Every piece of text in this language uses this color, whoever said it,
 * so each reader can find their side at a glance. Automatic conversations
 * keep the listener's ink fixed while partner languages can change.
 */
@Composable
@ReadOnlyComposable
fun Language.ink(pair: LanguagePair): Color {
    val listener = LocalAutomaticListener.current
    val second = if (listener != null) this != listener else this == pair.second
    return if (second) Lively.colors.secondInk else Lively.colors.firstInk
}

/**
 * Screen orientation follows readers, while every historical turn keeps its
 * own language. A newly detected partner must not relabel older text.
 */
enum class TranscriptRole {
    LISTENER, PARTNER;

    fun language(utterance: Utterance): Language? {
        if (utterance.sourceLanguage == null && utterance.target == null) return null
        return if (this == LISTENER) utterance.listenerLanguage else utterance.otherLanguage
    }

    fun text(utterance: Utterance): String {
        if (utterance.sourceLanguage == null && utterance.target == null) return utterance.trimmedSource
        return if (this == LISTENER) utterance.listenerText else utterance.partnerText
    }

    fun isSource(utterance: Utterance): Boolean {
        val source = utterance.sourceLanguage ?: return false
        return if (this == LISTENER) source == utterance.listenerLanguage else source != utterance.listenerLanguage
    }
}

val Utterance.unidentifiedLanguageTitle: String
    get() = if (isFinal) "Language not identified" else "Identifying language"

val Utterance.showsLanguagePrompt: Boolean
    get() {
        if (isSourceOnly) return false
        return isAwaitingLanguage || translationState == TranslationState.AwaitingPartner ||
            (isFinal && target != null && translation.isEmpty() && translationState == TranslationState.Idle)
    }

val Utterance.hasTranslationProblem: Boolean
    get() = translationState is TranslationState.Failed || translationState == TranslationState.WaitingForNetwork

/** A [LanguageTag], or a neutral capsule while the language isn't known. */
@Composable
fun OptionalLanguageTag(
    language: Language?,
    pair: LanguagePair,
    modifier: Modifier = Modifier,
    spoken: Boolean = false,
    showsIcon: Boolean = true,
    /** On for a tag that's a button opening the language choice. */
    showsChevron: Boolean = false,
    unknownTitle: String = "Automatic",
) {
    if (language != null) {
        LanguageTag(language, pair, modifier, spoken = spoken, showsIcon = showsIcon, showsChevron = showsChevron)
        return
    }
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.08f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(Icons.Rounded.LanguageGlobe, contentDescription = null, tint = color, modifier = Modifier.size(12.dp))
        Text(unknownTitle, color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold, lineHeight = 13.sp)
        if (showsChevron) Icon(Icons.Rounded.KeyboardArrowDown, contentDescription = null, tint = color, modifier = Modifier.size(13.dp))
    }
}

/** Waiting for a destination is separate from translating or a network error. */
@Composable
fun PendingLanguageLabel(utterance: Utterance, onTranslate: (() -> Unit)? = null) {
    val state = utterance.translationState
    when {
        utterance.isSourceOnly -> {}
        state is TranslationState.Failed ->
            if (onTranslate != null) RetryButton("Retry translation", onTranslate)
            else Caption(Icons.Rounded.ErrorOutline, "Translation failed", color = Lively.colors.warning)
        state == TranslationState.WaitingForNetwork -> Caption(Icons.Rounded.WifiOff, "Waiting for connection")
        utterance.sourceLanguage == null -> Caption(Icons.Rounded.LanguageGlobe, utterance.unidentifiedLanguageTitle)
        utterance.waitsForAutomaticPartner -> Caption(Icons.Rounded.LanguageGlobe, "Waiting for other language")
        utterance.target == null -> Caption(Icons.Rounded.GraphicEq, if (utterance.isFinal) "Finishing transcript" else "Listening")
        onTranslate != null -> CaptionButton(Icons.Rounded.Translate, "Translate", MaterialTheme.colorScheme.primary, onTranslate)
        else -> Text("Ready to translate", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
