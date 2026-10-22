package sh.ian.lively.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair

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

object Lively {
    val colors: LivelyColors
        @Composable @ReadOnlyComposable get() = LocalLivelyColors.current
}

@Composable
fun LivelyTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val scheme: ColorScheme = if (dark) DarkScheme else LightScheme
    CompositionLocalProvider(LocalLivelyColors provides if (dark) Dark else Light) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/** Every piece of text in this language uses this color, whoever said it. */
@Composable
@ReadOnlyComposable
fun Language.ink(pair: LanguagePair): Color =
    if (this == pair.second) Lively.colors.secondInk else Lively.colors.firstInk
