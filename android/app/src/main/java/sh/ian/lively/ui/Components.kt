package sh.ian.lively.ui

import android.os.Build
import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.ian.lively.model.ConnectionStatus
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin

/**
 * A small capsule naming the language, e.g. "EN" or "中文". What was
 * actually said gets a solid capsule with a waveform; a translation gets a
 * light one with a translate icon, so the two never look alike.
 */
@Composable
fun LanguageTag(
    language: Language,
    pair: LanguagePair,
    modifier: Modifier = Modifier,
    spoken: Boolean = false,
    /** Off for labels that name a language without saying how the text got there. */
    showsIcon: Boolean = true,
) {
    val ink = language.ink(pair)
    val description = when {
        !showsIcon -> language.nativeName
        spoken -> "Spoken in ${language.nativeName}"
        else -> "Translated to ${language.nativeName}"
    }
    Row(
        modifier
            .clip(CircleShape)
            .background(if (spoken) ink else ink.copy(alpha = 0.12f))
            .padding(horizontal = 7.dp, vertical = 3.dp)
            .clearAndSetSemantics { contentDescription = description },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        val color = if (spoken) Color.White else ink
        if (showsIcon) {
            Icon(
                if (spoken) Icons.Rounded.GraphicEq else Icons.Rounded.Translate,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(12.dp),
            )
        }
        Text(language.tag, color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold, lineHeight = 13.sp)
    }
}

/** Three pulsing dots shown while text is on its way. */
@Composable
fun TypingDots(color: Color, modifier: Modifier = Modifier, dotSize: Dp = 6.dp) {
    val transition = rememberInfiniteTransition(label = "dots")
    val t by transition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * PI).toFloat(),
        animationSpec = infiniteRepeatable(tween(1260, easing = LinearEasing)),
        label = "phase",
    )
    Row(
        modifier.semantics { contentDescription = "Working" },
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        repeat(3) { i ->
            val opacity = 0.3f + 0.7f * max(0f, sin(t - i * 0.7f))
            Box(
                Modifier
                    .size(dotSize)
                    .graphicsLayer { alpha = opacity }
                    .background(color, CircleShape),
            )
        }
    }
}

/** How long a press lasts before it counts as a hold rather than a tap. */
private const val MIC_HOLD_DELAY_MS = 300L

/**
 * The one big button: start and stop listening. A ring breathes with the mic
 * level, and fades while the noise gate is holding back distant sound.
 *
 * Tapping toggles listening. Holding it while stopped listens only until
 * it's let go, like a walkie-talkie. [onHoldStart] is called once a press has
 * lasted [MIC_HOLD_DELAY_MS], and [onHoldEnd] when it ends.
 */
@Composable
fun MicButton(
    isListening: Boolean,
    level: Float,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 76.dp,
    isHearing: Boolean = true,
    onHoldStart: () -> Unit = {},
    onHoldEnd: () -> Unit = {},
) {
    val view = LocalView.current
    val primary = MaterialTheme.colorScheme.primary
    val container by animateColorAsState(
        if (isListening) primary else MaterialTheme.colorScheme.surfaceContainerHighest,
        label = "mic container",
    )
    val ringScale by animateFloatAsState(1f + level * 0.35f, tween(120), label = "ring")
    val ringAlpha by animateFloatAsState(if (isHearing) 0.35f else 0.12f, tween(200), label = "ring alpha")
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val pressScale by animateFloatAsState(if (pressed) 0.94f else 1f, spring(stiffness = 800f), label = "press")
    // iOS gets these from .sensoryFeedback on isListening; Android plays them by hand.
    fun haptic(starting: Boolean) = view.performHapticFeedback(
        when {
            starting -> HapticFeedbackConstants.CONTEXT_CLICK
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> HapticFeedbackConstants.CONFIRM
            else -> HapticFeedbackConstants.VIRTUAL_KEY
        },
    )
    var isHolding by remember { mutableStateOf(false) }
    // The release that ended a hold also reports a click; this drops it.
    var swallowsTap by remember { mutableStateOf(false) }
    val listening by rememberUpdatedState(isListening)
    val holdStart by rememberUpdatedState(onHoldStart)
    val holdEnd by rememberUpdatedState(onHoldEnd)
    fun endHold() {
        isHolding = false
        haptic(starting = false)
        holdEnd()
    }
    LaunchedEffect(pressed) {
        if (pressed) {
            swallowsTap = false
            // A hold only means something while stopped; otherwise it's a slow tap.
            if (listening) return@LaunchedEffect
            delay(MIC_HOLD_DELAY_MS)
            isHolding = true
            haptic(starting = true)
            holdStart()
        } else if (isHolding) {
            // Released, possibly after sliding off the button.
            endHold()
            swallowsTap = true
        }
    }
    Box(modifier.size(size + 8.dp), contentAlignment = Alignment.Center) {
        if (isListening) {
            Box(
                Modifier
                    .size(size)
                    .scale(ringScale)
                    .border(3.dp, primary.copy(alpha = ringAlpha), CircleShape),
            )
        }
        Surface(
            onClick = {
                // The click can arrive before or after the press ends.
                when {
                    isHolding -> endHold()
                    swallowsTap -> swallowsTap = false
                    else -> {
                        haptic(starting = !isListening)
                        onClick()
                    }
                }
            },
            shape = CircleShape,
            color = container,
            contentColor = if (isListening) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
            shadowElevation = if (isListening) 6.dp else 2.dp,
            interactionSource = interaction,
            modifier = Modifier
                .size(size)
                .scale(pressScale)
                .semantics { contentDescription = if (isListening) "Stop listening" else "Start listening" },
        ) {
            Box(contentAlignment = Alignment.Center) {
                AnimatedContent(
                    targetState = isListening,
                    transitionSpec = { (scaleIn() + fadeIn()) togetherWith (scaleOut() + fadeOut()) },
                    label = "mic icon",
                ) { listening ->
                    Icon(
                        if (listening) Icons.Rounded.Stop else Icons.Rounded.Mic,
                        contentDescription = null,
                        modifier = Modifier.size(size * 0.42f),
                    )
                }
            }
        }
    }
}

@Composable
fun StatusPill(
    status: ConnectionStatus,
    isListening: Boolean,
    modifier: Modifier = Modifier,
    /** Dot only, for tight spaces; the label is still read by TalkBack. */
    compact: Boolean = false,
) {
    val colors = Lively.colors
    val label = when (status) {
        ConnectionStatus.Idle -> "Ready"
        ConnectionStatus.Connecting -> "Connecting…"
        ConnectionStatus.Live -> "Listening"
        ConnectionStatus.Reconnecting -> "Reconnecting…"
        ConnectionStatus.Offline -> if (isListening) "Offline · holding audio" else "Offline"
        is ConnectionStatus.Failed -> "Needs attention"
    }
    val shortLabel = when (status) {
        ConnectionStatus.Offline -> "Offline"
        ConnectionStatus.Reconnecting -> "Reconnecting"
        ConnectionStatus.Connecting -> "Connecting"
        else -> label
    }
    val dot = when (status) {
        ConnectionStatus.Idle -> MaterialTheme.colorScheme.onSurfaceVariant
        ConnectionStatus.Connecting, ConnectionStatus.Reconnecting -> colors.warning
        ConnectionStatus.Live -> colors.live
        ConnectionStatus.Offline, is ConnectionStatus.Failed -> colors.danger
    }
    val pulsing = status == ConnectionStatus.Connecting || status == ConnectionStatus.Reconnecting
    val pulse = rememberInfiniteTransition(label = "pulse")
    val pulseAlpha by pulse.animateFloat(
        1f, 0.35f, infiniteRepeatable(tween(700, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "alpha",
    )
    val dotOnly = compact && status == ConnectionStatus.Live
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = modifier.semantics(mergeDescendants = true) {
            contentDescription = label
            liveRegion = LiveRegionMode.Polite
        },
    ) {
        Row(
            Modifier.padding(horizontal = if (dotOnly) 9.dp else 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Box(
                Modifier
                    .size(8.dp)
                    .alpha(if (pulsing) pulseAlpha else 1f)
                    .background(dot, CircleShape),
            )
            if (!dotOnly) {
                AnimatedContent(targetState = if (compact) shortLabel else label, label = "status") {
                    Text(
                        it,
                        style = MaterialTheme.typography.labelLarge,
                        maxLines = 1,
                        modifier = Modifier.clearAndSetSemantics {},
                    )
                }
            }
        }
    }
}

/** A round tonal icon button, the Android counterpart of the iOS glass buttons. */
@Composable
fun TonalIconButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    size: Dp = 48.dp,
    /** Set for a toggle, which is tinted while on. */
    isOn: Boolean? = null,
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = CircleShape,
        color = if (isOn == true) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = if (isOn == true) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
        modifier = modifier
            .size(size)
            .alpha(if (enabled) 1f else 0.4f)
            .semantics {
                contentDescription = label
                if (isOn != null) selected = isOn
            },
    ) {
        Box(contentAlignment = Alignment.Center) { Icon(icon, contentDescription = null, modifier = Modifier.size(22.dp)) }
    }
}

/**
 * Switches speech-to-speech mode: translations into the second language
 * are read aloud. Hidden when there's no Soniox key to speak with.
 */
@Composable
fun SpeakAloudButton(store: ConversationStore, size: Dp = 48.dp) {
    if (!store.canSpeakTranslations) return
    val on = store.speaksTranslations
    val view = LocalView.current
    TonalIconButton(
        if (on) Icons.AutoMirrored.Rounded.VolumeUp else Icons.AutoMirrored.Rounded.VolumeOff,
        if (on) "Stop speaking translations aloud" else "Speak translations aloud",
        onClick = {
            view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            store.setSpeaksTranslations(!on)
        },
        size = size,
        isOn = on,
    )
}

/** A settings-style round badge with a white symbol. */
@Composable
fun SettingsIcon(icon: ImageVector, color: Color, modifier: Modifier = Modifier, size: Dp = 36.dp) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(Brush.verticalGradient(listOf(color.copy(alpha = 0.92f), color))),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.52f))
    }
}

/** A full-width pill button that shrinks a little under the finger. */
@Composable
fun PillButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    working: Boolean = false,
    container: Color = MaterialTheme.colorScheme.primary,
    content: Color = MaterialTheme.colorScheme.onPrimary,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, spring(stiffness = 800f), label = "press")
    Surface(
        onClick = onClick,
        enabled = enabled && !working,
        shape = CircleShape,
        color = container,
        contentColor = content,
        interactionSource = interaction,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .scale(scale)
            .alpha(if (enabled) 1f else 0.4f)
            .semantics { role = Role.Button },
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.padding(PaddingValues(horizontal = 20.dp, vertical = 14.dp))) {
            if (working) {
                CircularProgressIndicator(color = content, strokeWidth = 2.5.dp, modifier = Modifier.size(22.dp))
            } else {
                Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** The back arrow for top app bars. */
@Composable
fun BackButton(onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back", tint = LocalContentColor.current)
    }
}

/** Rounded card shape used across screens. */
val CardShape = RoundedCornerShape(24.dp)
