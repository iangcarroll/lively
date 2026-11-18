package sh.ian.lively.ui

import android.os.Build
import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedContent
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
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.rounded.MicOff
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material.icons.rounded.SettingsInputAntenna
import androidx.compose.ui.text.style.TextAlign
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.phrases
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
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
    /** On for a tag inside a button that opens the language choice. */
    showsChevron: Boolean = false,
    /** Set where the tag opens the languages sheet; it then gets a chevron. */
    onChangeLanguages: (() -> Unit)? = null,
) {
    val ink = language.ink(pair)
    val description = when {
        !showsIcon -> language.nativeName
        spoken -> "Spoken in ${language.nativeName}"
        else -> "Translated to ${language.nativeName}"
    }
    if (onChangeLanguages != null) {
        // The capsule is small; the space around it is part of the button.
        Box(
            modifier
                .clip(RoundedCornerShape(20.dp))
                .clickable(onClick = onChangeLanguages, role = Role.Button)
                .clearAndSetSemantics { contentDescription = "Change languages" }
                .padding(14.dp),
        ) {
            LanguageCapsule(language.tag, ink, spoken, showsIcon, chevron = true, Modifier)
        }
    } else {
        LanguageCapsule(language.tag, ink, spoken, showsIcon, chevron = showsChevron, modifier.clearAndSetSemantics { contentDescription = description })
    }
}

@Composable
private fun LanguageCapsule(tag: String, ink: Color, spoken: Boolean, showsIcon: Boolean, chevron: Boolean, modifier: Modifier) {
    Row(
        modifier
            .clip(CircleShape)
            .background(if (spoken) ink else ink.copy(alpha = 0.12f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
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
        Text(tag, color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold, lineHeight = 13.sp)
        if (chevron) Icon(Icons.Rounded.KeyboardArrowDown, contentDescription = null, tint = color, modifier = Modifier.size(13.dp))
    }
}

/**
 * Both languages' tags on one button, e.g. "EN ⇄ 中文", in the transcript's
 * top bar, which opens the languages sheet. Where the bar is too full for
 * that, a round button instead.
 */
@Composable
fun LanguagePairButton(
    first: Language,
    /** Null in an automatic conversation until the other person has spoken. */
    second: Language?,
    pair: LanguagePair,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Layout(
        content = {
            Surface(
                onClick = onClick,
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                modifier = Modifier.semantics {
                    contentDescription = "Change languages"
                    stateDescription = "${first.englishName} and ${second?.englishName ?: "automatic"}"
                },
            ) {
                Row(
                    Modifier.heightIn(min = 36.dp).padding(horizontal = 12.dp).clearAndSetSemantics {},
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Text(first.tag, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = first.ink(pair), maxLines = 1)
                    Icon(Icons.Rounded.SwapHoriz, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                    Text(
                        second?.tag ?: "Auto",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = second?.ink(pair) ?: MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
            }
            TonalIconButton(Icons.Rounded.Translate, "Change languages", onClick)
        },
        modifier = modifier,
    ) { measurables, constraints ->
        val (capsule, round) = measurables
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        // Only the one that fits is measured and placed, so only it is on
        // screen and in the accessibility tree.
        val chosen = when {
            capsule.maxIntrinsicWidth(constraints.maxHeight) <= constraints.maxWidth -> capsule
            round.maxIntrinsicWidth(constraints.maxHeight) <= constraints.maxWidth -> round
            else -> null
        }?.measure(loose)
        val height = maxOf(chosen?.height ?: 0, constraints.minHeight)
        layout(constraints.maxWidth, height) { chosen?.place(0, (height - chosen.height) / 2) }
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
    // The primary action, so it's the accent color at rest too; listening
    // adds the stop icon and the ring.
    val primary = MaterialTheme.colorScheme.primary
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
            color = primary,
            contentColor = MaterialTheme.colorScheme.onPrimary,
            shadowElevation = if (isListening) 6.dp else 3.dp,
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

/**
 * A bilingual reminder beside the transcript controls. Both readers can see
 * that they can speak without touching the microphone.
 */
@Composable
fun TranscriptListeningStatus(
    store: ConversationStore,
    pair: LanguagePair,
    script: ChineseScript,
    modifier: Modifier = Modifier,
) {
    val status = store.status
    val isListening = store.isListening
    val offline = isListening && status == ConnectionStatus.Offline
    val tint = when {
        !isListening -> MaterialTheme.colorScheme.onSurfaceVariant
        offline -> Lively.colors.warning
        else -> MaterialTheme.colorScheme.primary
    }
    val symbol = when {
        !isListening -> Icons.Rounded.MicOff
        status == ConnectionStatus.Live -> Icons.Rounded.GraphicEq
        offline -> Icons.Rounded.WifiOff
        else -> Icons.Rounded.SettingsInputAntenna
    }
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            // Opaque underneath, so the transcript doesn't show through.
            .background(MaterialTheme.colorScheme.background)
            .background(tint.copy(alpha = if (isListening) 0.1f else 0.04f))
            .padding(horizontal = 16.dp, vertical = 10.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(symbol, contentDescription = null, tint = tint, modifier = Modifier.size(26.dp))
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            @Composable
            fun Line(text: String, color: Color, language: Language? = null) = Text(
                text,
                style = MaterialTheme.typography.titleMedium.inLanguage(language),
                fontWeight = FontWeight.SemiBold,
                color = color,
            )
            @Composable
            fun Prompt(language: Language, color: Color) {
                val phrases = language.phrases(script)
                Line(
                    when {
                        !isListening -> phrases.tapToStart
                        status == ConnectionStatus.Live -> phrases.listening
                        offline -> phrases.waitingForConnection
                        else -> phrases.connecting
                    },
                    color,
                    language,
                )
            }
            val secondary = MaterialTheme.colorScheme.onSurfaceVariant
            Prompt(if (store.isAutomaticLanguageMode) store.listenerLanguage else pair.first, MaterialTheme.colorScheme.onSurface)
            if (store.isAutomaticLanguageMode) {
                val partner = store.detectedPartnerLanguage
                when {
                    !store.isOnline -> Line("Automatic detection needs internet", secondary)
                    partner != null -> Prompt(partner, partner.ink(pair))
                    else -> Line(if (isListening) "Listening for another language" else "Other language · Automatic", secondary)
                }
            } else {
                Prompt(pair.second, pair.second.ink(pair))
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
 * The menu item that switches speech-to-speech mode. Hidden when there's
 * no Soniox key to speak with.
 */
@Composable
fun SpeakAloudMenuItem(store: ConversationStore, onDone: () -> Unit) {
    if (!store.canSpeakTranslations) return
    val on = store.speaksTranslations
    DropdownMenuItem(
        text = { Text("Speak translations") },
        leadingIcon = { Icon(Icons.AutoMirrored.Rounded.VolumeUp, null) },
        trailingIcon = { Checkbox(checked = on, onCheckedChange = null) },
        onClick = {
            onDone()
            store.setSpeaksTranslations(!on)
        },
    )
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
