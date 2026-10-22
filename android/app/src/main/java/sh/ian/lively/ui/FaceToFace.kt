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
import androidx.compose.material.icons.rounded.MoreVert
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
import androidx.compose.foundation.layout.height
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import android.view.HapticFeedbackConstants
import sh.ian.lively.model.ChineseScript
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
    onSwap: () -> Unit,
    showsTextInput: Boolean,
    onShowsTextInputChange: (Boolean) -> Unit,
    onShowTranscript: () -> Unit,
    onShowSettings: () -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
) {
    val far = pair.other(nearLanguage)
    Column(modifier.fillMaxSize()) {
        FaceToFaceHalf(
            store, far, pair, script,
            Modifier
                .weight(1f)
                .rotate(180f),
            // Rotated, its bottom edge is the top of the screen.
            edgePadding = contentPadding.calculateTopPadding(),
        )
        ControlStrip(store, onSwap, showsTextInput, onShowsTextInputChange, onShowTranscript, onShowSettings)
        val bottom = contentPadding.calculateBottomPadding()
        FaceToFaceHalf(store, nearLanguage, pair, script, Modifier.weight(1f), edgePadding = if (showsTextInput) 0.dp else bottom)
        // The near person types; the far side reads the translation. The
        // bottom padding includes the keyboard, so the halves make room for it.
        AnimatedVisibility(showsTextInput) {
            TypeToTranslateBar(
                store, nearLanguage,
                onClose = { onShowsTextInputChange(false) },
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = bottom + 8.dp),
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
) {
    val view = LocalView.current
    BoxWithConstraints {
        // Small phones get smaller controls, so the mic stays centered.
        val narrow = maxWidth < 380.dp
        val buttonSize = if (narrow) 44.dp else 48.dp
        Column {
            // Hairlines separate the two readers' halves.
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
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
                MicButton(store.isListening, store.level, onClick = store::toggleListening, size = if (narrow) 66.dp else 76.dp)
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(if (narrow) 6.dp else 10.dp, Alignment.End)) {
                    TonalIconButton(Icons.Rounded.SwapVert, "Swap sides", size = buttonSize, onClick = {
                        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                        onSwap()
                    })
                    Box {
                        var menu by remember { mutableStateOf(false) }
                        TonalIconButton(Icons.Rounded.MoreVert, "More", size = buttonSize, onClick = { menu = true })
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = RoundedCornerShape(16.dp)) {
                            DropdownMenuItem(
                                text = { Text("Transcript view") },
                                leadingIcon = { Icon(Icons.AutoMirrored.Rounded.ViewList, null) },
                                onClick = { menu = false; onShowTranscript() },
                            )
                            DropdownMenuItem(
                                text = { Text("Clear conversation") },
                                leadingIcon = { Icon(Icons.Rounded.DeleteOutline, null) },
                                enabled = store.utterances.isNotEmpty(),
                                onClick = { menu = false; store.clear() },
                            )
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
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

/**
 * One reader's half: the conversation in their language, newest line largest
 * and nearest their edge of the phone.
 */
@Composable
private fun FaceToFaceHalf(
    store: ConversationStore,
    language: Language,
    pair: LanguagePair,
    script: ChineseScript,
    modifier: Modifier,
    edgePadding: androidx.compose.ui.unit.Dp,
) {
    val phrases = language.phrases(script)
    val recent = store.visibleUtterances.takeLast(12)
    val state = rememberLazyListState()
    LaunchedEffect(recent.lastOrNull()?.id, recent.size) { if (recent.isNotEmpty()) state.animateScrollToItem(0) }
    InLanguage(language) {
        BoxWithConstraints(modifier.fillMaxWidth()) {
            // A half of a small phone holds a few lines; keep the newest one whole.
            val compact = maxHeight < 300.dp
            LazyColumn(
                state = state,
                reverseLayout = true,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 24.dp, end = 24.dp, top = 44.dp, bottom = 20.dp + edgePadding),
                verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.Bottom),
            ) {
                items(recent.asReversed(), key = { it.id }) { utterance ->
                    Line(utterance, language, pair, phrases.waitingForConnection, phrases.translationFailed, isLatest = utterance === recent.last(), compact = compact, onRetry = { store.retryTranslation(utterance) }, Modifier.animateItem())
                }
            }
            if (recent.isEmpty()) {
                Column(
                    Modifier
                        .fillMaxSize()
                        .padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    AnimatedContent(
                        targetState = if (store.isListening) phrases.listening else phrases.tapToStart,
                        transitionSpec = { fadeIn() togetherWith fadeOut() },
                        label = "prompt",
                    ) { prompt ->
                        Text(
                            prompt,
                            style = MaterialTheme.typography.headlineSmall.copy(localeList = language.localeList()),
                            fontWeight = FontWeight.SemiBold,
                            color = language.ink(pair),
                            textAlign = TextAlign.Center,
                        )
                    }
                    Text(
                        phrases.speakHint,
                        style = MaterialTheme.typography.bodyMedium.copy(localeList = language.localeList()),
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
                    .height(48.dp)
                    .background(Brush.verticalGradient(0.55f to MaterialTheme.colorScheme.background, 1f to Color.Transparent)),
            )
            LanguageTag(language, pair, showsIcon = false, modifier = Modifier.padding(14.dp).align(Alignment.TopStart))
        }
    }
}

@Composable
private fun Line(
    utterance: Utterance,
    language: Language,
    pair: LanguagePair,
    waitingText: String,
    failedText: String,
    isLatest: Boolean,
    compact: Boolean,
    onRetry: () -> Unit,
    modifier: Modifier,
) {
    val text = utterance.text(language)
    // Your own words are quiet; what the other person said is prominent.
    val ownWords = utterance.language == language
    val alpha by animateFloatAsState(if (isLatest) 1f else 0.55f, label = "age")
    Column(modifier.fillMaxWidth().alpha(alpha), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (text.isEmpty()) {
            TypingDots(language.ink(pair), Modifier.padding(vertical = 8.dp), dotSize = 8.dp)
        } else {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val type = MaterialTheme.typography
                val style = when {
                    compact -> if (isLatest) type.titleLarge else type.titleMedium
                    else -> if (isLatest) type.headlineMedium else type.titleLarge
                }
                Text(
                    text,
                    style = style.copy(localeList = language.localeList()),
                    fontWeight = if (isLatest && !ownWords) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (ownWords) MaterialTheme.colorScheme.onSurfaceVariant else language.ink(pair),
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (ownWords && !utterance.isFinal) TypingDots(language.ink(pair), Modifier.padding(bottom = 10.dp))
            }
        }
        if (!ownWords) {
            when (utterance.translationState) {
                TranslationState.WaitingForNetwork -> Caption(Icons.Rounded.WifiOff, waitingText)
                is TranslationState.Failed -> RetryButton(failedText, onRetry)
                else -> {}
            }
        }
    }
}

