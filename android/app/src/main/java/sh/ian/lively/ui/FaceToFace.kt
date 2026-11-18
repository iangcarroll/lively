package sh.ian.lively.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ViewList
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Place
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.foundation.layout.height
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.foundation.combinedClickable
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.lerp
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import android.view.HapticFeedbackConstants
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.ConnectionStatus
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.TranslationState
import sh.ian.lively.model.Utterance
import sh.ian.lively.model.phrases

/**
 * The phone layout: lay the phone flat between two people. The top half is
 * upside down so the person across the table reads it the right way up; the
 * bottom half faces the person holding the phone. Each half shows only its
 * reader's language. Controls sit in the middle so either person can reach them.
 */
@Composable
fun FaceToFaceScreen(
    store: ConversationStore,
    pair: LanguagePair,
    script: ChineseScript,
    /** Language of the person on the near (bottom) side. */
    nearLanguage: Language,
    /** In an automatic conversation, whether the listener has the near side. */
    listenerNear: Boolean,
    onSwap: () -> Unit,
    showsTextInput: Boolean,
    onShowsTextInputChange: (Boolean) -> Unit,
    editing: Utterance?,
    /** Corrects one of the near person's own turns. */
    onEdit: (Utterance) -> Unit,
    onEndEditing: () -> Unit,
    onShowTranscript: () -> Unit,
    onShowSettings: () -> Unit,
    onShowAddress: () -> Unit,
    /** Opens the languages sheet, from either half's language tag. */
    onChangeLanguages: () -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
    showsListeningPrompt: Boolean = true,
) {
    val automatic = store.isAutomaticLanguageMode
    val nearRole = if (automatic) (if (listenerNear) TranscriptRole.LISTENER else TranscriptRole.PARTNER) else null
    val farRole = if (automatic) (if (listenerNear) TranscriptRole.PARTNER else TranscriptRole.LISTENER) else null
    val nearDisplayLanguage = when {
        !automatic -> nearLanguage
        listenerNear -> store.listenerLanguage
        else -> store.detectedPartnerLanguage
    }
    val farDisplayLanguage = when {
        !automatic -> pair.other(nearLanguage)
        listenerNear -> store.detectedPartnerLanguage
        else -> store.listenerLanguage
    }
    // Side insets (a display cutout in landscape) pad the content, but not
    // the hairlines, which run edge to edge.
    val direction = LocalLayoutDirection.current
    val sides = Modifier.padding(
        start = contentPadding.calculateStartPadding(direction),
        end = contentPadding.calculateEndPadding(direction),
    )
    Column(modifier.fillMaxSize()) {
        FaceToFaceHalf(
            store, farDisplayLanguage, farRole, pair, script,
            Modifier
                .weight(1f)
                .then(sides)
                .rotate(180f),
            // Rotated, its bottom edge is the top of the screen.
            edgePadding = contentPadding.calculateTopPadding(),
            onChangeLanguages = onChangeLanguages,
            showsListeningPrompt = showsListeningPrompt,
        )
        ControlStrip(store, onSwap, showsTextInput, onShowsTextInputChange, onShowTranscript, onShowSettings, onShowAddress, sides)
        val bottom = contentPadding.calculateBottomPadding()
        FaceToFaceHalf(
            store, nearDisplayLanguage, nearRole, pair, script,
            Modifier.weight(1f).then(sides),
            edgePadding = if (showsTextInput) 0.dp else bottom,
            onChangeLanguages = onChangeLanguages,
            onEdit = onEdit,
            showsListeningPrompt = showsListeningPrompt,
        )
        // The near person types; the far side reads the translation. The
        // bottom padding includes the keyboard, so the halves make room for it.
        AnimatedVisibility(showsTextInput, enter = fadeIn(), exit = fadeOut()) {
            TypeToTranslateBar(
                store, if (automatic) null else pair, nearDisplayLanguage ?: store.listenerLanguage,
                onClose = { onShowsTextInputChange(false) },
                modifier = sides.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = bottom + 8.dp),
                editing = editing,
                onEndEditing = onEndEditing,
            )
        }
    }
}

@Composable
private fun ControlStrip(
    store: ConversationStore,
    onSwap: () -> Unit,
    showsTextInput: Boolean,
    onShowsTextInputChange: (Boolean) -> Unit,
    onShowTranscript: () -> Unit,
    onShowSettings: () -> Unit,
    onShowAddress: () -> Unit,
    /** Side insets for the controls; the hairlines ignore them. */
    sides: Modifier,
) {
    val view = LocalView.current
    Column {
        // Hairlines separate the two readers' halves.
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        BoxWithConstraints(sides) {
            // Small phones get smaller controls, so the mic stays centered.
            val narrow = maxWidth < 380.dp
            val buttonSize = if (narrow) 44.dp else 48.dp
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = if (narrow) 12.dp else 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(if (narrow) 6.dp else 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    StatusPill(store.status, store.isListening, compact = true)
                    TextInputToggle(showsTextInput, onShowsTextInputChange, size = buttonSize)
                }
                MicButton(
                    store.isListening, store.level, onClick = store::toggleListening, size = if (narrow) 66.dp else 76.dp,
                    isHearing = store.isHearing, onHoldStart = store::startListening, onHoldEnd = store::stopListening,
                )
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(if (narrow) 6.dp else 10.dp, Alignment.End)) {
                    TonalIconButton(
                        Icons.Rounded.DeleteOutline, "Clear conversation", store::clear,
                        enabled = store.utterances.isNotEmpty(), size = buttonSize,
                    )
                    Box {
                        var menu by remember { mutableStateOf(false) }
                        TonalIconButton(Icons.Rounded.MoreVert, "More", size = buttonSize, onClick = { menu = true })
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = RoundedCornerShape(16.dp)) {
                            DropdownMenuItem(
                                text = { Text("Address") },
                                leadingIcon = { Icon(Icons.Rounded.Place, null) },
                                onClick = { menu = false; onShowAddress() },
                            )
                            HorizontalDivider()
                            DropdownMenuItem(
                                text = { Text("Transcript view") },
                                leadingIcon = { Icon(Icons.AutoMirrored.Rounded.ViewList, null) },
                                onClick = { menu = false; onShowTranscript() },
                            )
                            DropdownMenuItem(
                                text = { Text("Swap sides") },
                                leadingIcon = { Icon(Icons.Rounded.SwapVert, null) },
                                onClick = {
                                    menu = false
                                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                                    onSwap()
                                },
                            )
                            SpeakAloudMenuItem(store, onDone = { menu = false })
                            HorizontalDivider()
                            DropdownMenuItem(
                                text = { Text("Settings") },
                                leadingIcon = { Icon(Icons.Rounded.Settings, null) },
                                onClick = { menu = false; onShowSettings() },
                            )
                        }
                    }
                }
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    }
}

/**
 * One reader's half: the conversation in their language, newest line largest
 * and nearest their edge of the phone.
 */
@Composable
private fun FaceToFaceHalf(
    store: ConversationStore,
    /** Null while an automatic conversation hasn't heard the other language. */
    language: Language?,
    /** Whose half this is in an automatic conversation, and null with a pair. */
    role: TranscriptRole?,
    pair: LanguagePair,
    script: ChineseScript,
    modifier: Modifier,
    edgePadding: androidx.compose.ui.unit.Dp,
    onChangeLanguages: () -> Unit,
    /** Set on the near half, whose reader can correct their own turns. */
    onEdit: ((Utterance) -> Unit)? = null,
    showsListeningPrompt: Boolean = true,
) {
    val phrases = language?.phrases(script)
    val recent = store.visibleUtterances.takeLast(12)
    // Each turn with its age, newest first. Source-only turns have no listener line.
    val lines = recent.asReversed().withIndex().filterNot { (_, utterance) -> utterance.isSourceOnly && role == TranscriptRole.LISTENER }
    val ink = language?.ink(pair) ?: MaterialTheme.colorScheme.onSurfaceVariant
    val state = rememberLazyListState()
    LaunchedEffect(lines.firstOrNull()?.value?.id, lines.size) { if (lines.isNotEmpty()) state.animateScrollToItem(0) }
    InLanguage(language) {
        BoxWithConstraints(modifier.fillMaxWidth()) {
            // A half of a small phone holds a few lines; keep the newest one whole.
            val compact = maxHeight < 300.dp
            LazyColumn(
                state = state,
                reverseLayout = true,
                modifier = Modifier.fillMaxSize(),
                // An automatic half's header also says whose side it is, so it's taller.
                contentPadding = PaddingValues(start = 24.dp, end = 24.dp, top = if (role == null) 44.dp else 76.dp, bottom = 20.dp + edgePadding),
                verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.Bottom),
            ) {
                items(lines, key = { it.value.id }) { (age, utterance) ->
                    Line(utterance, language, role, pair, script, age = age, compact = compact, onRetry = { store.retryTranslation(utterance) }, onEdit = onEdit, modifier = Modifier.animateItem())
                }
            }
            if (recent.isEmpty()) {
                val automaticOffline = store.isAutomaticLanguageMode && !store.isOnline
                val shown by animateFloatAsState(if (showsListeningPrompt) 1f else 0f, label = "prompt")
                Column(
                    Modifier
                        .fillMaxSize()
                        .padding(32.dp)
                        .alpha(shown)
                        .then(if (showsListeningPrompt) Modifier else Modifier.clearAndSetSemantics {}),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    AnimatedContent(
                        targetState = when {
                            automaticOffline -> "Automatic detection needs internet"
                            phrases == null -> if (store.isListening) "Listening for another language" else "Automatic"
                            store.isListening && store.status == ConnectionStatus.Offline -> phrases.waitingForConnection
                            store.isConnecting -> phrases.connecting
                            store.isListening -> phrases.listening
                            else -> phrases.tapToStart
                        },
                        transitionSpec = { fadeIn() togetherWith fadeOut() },
                        label = "prompt",
                    ) { prompt ->
                        Text(
                            prompt,
                            style = MaterialTheme.typography.headlineSmall.inLanguage(language),
                            fontWeight = FontWeight.SemiBold,
                            color = ink,
                            textAlign = TextAlign.Center,
                        )
                    }
                    Text(
                        // Offline, iOS points at its on-device translation here; Android has none to offer.
                        phrases?.speakHint ?: "The other language will appear when they speak.",
                        style = MaterialTheme.typography.bodyMedium.inLanguage(language),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }
            // Older lines scroll away under a fade, clear of the tag.
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(if (role == null) 48.dp else 84.dp)
                    .background(Brush.verticalGradient((if (role == null) 0.55f else 0.8f) to MaterialTheme.colorScheme.background, 1f to Color.Transparent)),
            )
            if (role == null && language != null) {
                // The tag pads itself, so the whole corner is the button.
                LanguageTag(language, pair, showsIcon = false, onChangeLanguages = onChangeLanguages, modifier = Modifier.align(Alignment.TopStart))
            } else {
                RoleHeader(language, role, pair, onChangeLanguages, Modifier.align(Alignment.TopStart))
            }
        }
    }
}

/**
 * An automatic half's way to the languages: whose side it is, over the
 * language's tag. The padding inside makes it easy to hit.
 */
@Composable
private fun RoleHeader(language: Language?, role: TranscriptRole?, pair: LanguagePair, onChangeLanguages: () -> Unit, modifier: Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(20.dp))
            .clickable(onClick = onChangeLanguages, role = Role.Button)
            .clearAndSetSemantics {
                contentDescription = "Change languages"
                stateDescription = language?.nativeName ?: "Automatic"
            }
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (role != null) {
            Text(
                if (role == TranscriptRole.LISTENER) "Your language" else "Other language",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        OptionalLanguageTag(language, pair, showsIcon = false, showsChevron = true)
    }
}

@Composable
private fun Line(
    utterance: Utterance,
    /** The half's language; a turn in an automatic conversation keeps its own. */
    language: Language?,
    role: TranscriptRole?,
    pair: LanguagePair,
    script: ChineseScript,
    age: Int,
    compact: Boolean,
    onRetry: () -> Unit,
    onEdit: ((Utterance) -> Unit)?,
    modifier: Modifier,
) {
    val rowLanguage = if (role != null) role.language(utterance) else language
    val neutral = utterance.isAutomatic && utterance.sourceLanguage == null && utterance.target == null
    val text = role?.text(utterance) ?: language?.let(utterance::text).orEmpty()
    // Your own words are quiet; what the other person said is prominent.
    val ownWords = role?.isSource(utterance) ?: (utterance.sourceLanguage == language)
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    val ink = if (neutral) secondary else rowLanguage?.ink(pair) ?: secondary
    // Lines shrink and fade over a few turns rather than all at once, so a
    // line still being read stays legible when a stray turn lands below it.
    val prominence by animateFloatAsState((1f - age / 3f).coerceAtLeast(0f), label = "age")
    val alpha = 0.55f + 0.45f * prominence
    val type = MaterialTheme.typography
    // The newest line's size and the size older lines settle to.
    val style = if (compact) {
        lerp(type.titleMedium, type.titleLarge, prominence)
    } else {
        lerp(type.titleLarge, type.headlineMedium, prominence)
    }.inLanguage(rowLanguage)
    val weight = if (age < 2 && !ownWords) FontWeight.SemiBold else FontWeight.Normal
    // Long-press to correct a finished turn's transcript, where editing is offered.
    val editable = onEdit != null && ownWords && utterance.isFinal
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    Box(modifier) {
        Column(
            Modifier
                .fillMaxWidth()
                .alpha(alpha)
                .then(
                    if (editable) {
                        Modifier.combinedClickable(
                            onClick = {},
                            onLongClick = {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                menu = true
                            },
                            onLongClickLabel = "Edit",
                        )
                    } else {
                        Modifier
                    },
                ),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (role != null && (neutral || rowLanguage != language)) {
                OptionalLanguageTag(
                    if (neutral) null else rowLanguage, pair,
                    spoken = ownWords,
                    unknownTitle = if (neutral) utterance.unidentifiedLanguageTitle else "Automatic",
                )
            }
            if (text.isEmpty()) {
                if (!ownWords && !neutral && utterance.hasTranslationProblem) {
                    StatusLine(utterance, rowLanguage, script, onRetry)
                } else if (utterance.showsLanguagePrompt) {
                    PendingLanguageLabel(utterance, onTranslate = onRetry)
                } else if (utterance.isFinal && ((ownWords && utterance.source.isEmpty()) || rowLanguage == null)) {
                    Text(
                        "—",
                        style = style,
                        fontWeight = weight,
                        color = secondary.copy(alpha = 0.5f),
                        modifier = Modifier.semantics { contentDescription = "Original transcript unavailable" },
                    )
                } else {
                    TypingDots(ink, Modifier.padding(vertical = 8.dp), dotSize = 8.dp)
                }
            } else {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text,
                        style = style,
                        fontWeight = weight,
                        color = if (ownWords) secondary else ink,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (ownWords && !utterance.isFinal) TypingDots(ink, Modifier.padding(bottom = 10.dp))
                }
            }
            if (!utterance.isSourceOnly && !neutral && text.isNotEmpty() && (!ownWords || utterance.hasTranslationProblem)) {
                StatusLine(utterance, rowLanguage, script, onRetry)
            }
        }
        if (editable) {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = RoundedCornerShape(16.dp)) {
                DropdownMenuItem(
                    text = { Text("Edit") },
                    leadingIcon = { Icon(Icons.Rounded.Edit, null) },
                    onClick = { menu = false; onEdit(utterance) },
                )
            }
        }
    }
}

/** What's holding a line's translation up, in the reader's language where it's known. */
@Composable
private fun StatusLine(utterance: Utterance, language: Language?, script: ChineseScript, onRetry: () -> Unit) {
    val phrases = language?.phrases(script)
    when (utterance.translationState) {
        TranslationState.AwaitingPartner -> PendingLanguageLabel(utterance, onTranslate = onRetry)
        TranslationState.WaitingForNetwork -> Caption(Icons.Rounded.WifiOff, phrases?.waitingForConnection ?: "Waiting for connection")
        is TranslationState.Failed -> RetryButton(phrases?.translationFailed ?: "Translation failed", onRetry)
        else -> {}
    }
}
