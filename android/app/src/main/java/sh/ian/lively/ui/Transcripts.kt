package sh.ian.lively.ui

import sh.ian.lively.R
import androidx.compose.ui.res.stringResource
import android.content.ClipData
import android.content.Intent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope
import sh.ian.lively.model.ConnectionStatus
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.TranslationState
import sh.ian.lively.model.Utterance
import sh.ian.lively.model.phrases
import sh.ian.lively.model.ChineseScript

/**
 * Lays out [content] the way [language] is written, and tags its text for the
 * right glyphs. A language that isn't known yet keeps the layout it's in.
 */
@Composable
fun InLanguage(language: Language?, content: @Composable () -> Unit) {
    if (language == null) return content()
    CompositionLocalProvider(
        LocalLayoutDirection provides if (language.isRightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr,
        content = content,
    )
}

/** For text styles, so Han characters get Chinese rather than Japanese glyphs, and so on. */
fun Language.localeList() = LocaleList(locale.toLanguageTag())

/** This style for text in [language], or as it is while the language isn't known. */
fun TextStyle.inLanguage(language: Language?) = if (language == null) this else copy(localeList = language.localeList())

/** Keeps a reversed list pinned to the newest item as items arrive. */
@Composable
private fun rememberPinnedListState(count: Int) = rememberLazyListState().also { state ->
    LaunchedEffect(count) { if (state.firstVisibleItemIndex <= 1) state.animateScrollToItem(0) }
}

/** Narrow layout: a single chat-style feed. */
@Composable
fun ChatTranscript(
    store: ConversationStore,
    pair: LanguagePair,
    onEdit: (Utterance) -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
) {
    val utterances = store.visibleUtterances
    val state = rememberPinnedListState(utterances.size)
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        state = state,
        reverseLayout = true,
        contentPadding = PaddingValues(
            start = 16.dp, end = 16.dp,
            top = contentPadding.calculateTopPadding() + 12.dp,
            bottom = contentPadding.calculateBottomPadding() + 12.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.Bottom),
    ) {
        items(utterances.asReversed(), key = { it.id }) { utterance ->
            SwipeToDelete(onDelete = { store.delete(utterance) }, modifier = Modifier.animateItem()) {
                UtteranceBubble(utterance, pair, onRetry = { store.retryTranslation(utterance) }, onEdit = { onEdit(utterance) }, onDelete = { store.delete(utterance) })
            }
        }
    }
}

/**
 * One turn, shown chat-style: speakers of the pair's first language on the
 * leading side, the second language on the trailing side, each bubble tinted
 * with the speaker's language color. The spoken text sits on top; the
 * translation, which the other person reads, is larger and in its own
 * language's color.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun UtteranceBubble(
    utterance: Utterance,
    pair: LanguagePair,
    onRetry: () -> Unit,
    onEdit: (() -> Unit)? = null,
    onDelete: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val spoken = utterance.sourceLanguage
    val unclassified = utterance.isAutomatic && spoken == null && utterance.target == null
    val leading = if (utterance.isAutomatic) spoken == utterance.listenerLanguage else spoken == utterance.languages.first
    val ink = spoken?.ink(pair) ?: MaterialTheme.colorScheme.onSurfaceVariant
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val shape = RoundedCornerShape(24.dp)
    // A turn in a language nobody has claimed yet takes neither side.
    val inset = if (unclassified) 0.dp else 40.dp
    Row(modifier.fillMaxWidth(), horizontalArrangement = if (leading || unclassified) Arrangement.Start else Arrangement.End) {
        Box {
            Column(
                Modifier
                    .widthIn(max = 520.dp)
                    .padding(start = if (leading) 0.dp else inset, end = if (leading) inset else 0.dp)
                    .shadow(2.dp, shape, ambientColor = Color.Black.copy(alpha = 0.2f), spotColor = Color.Black.copy(alpha = 0.2f))
                    .clip(shape)
                    .background(Lively.colors.card)
                    .background(ink.copy(alpha = 0.08f))
                    .border(1.dp, ink.copy(alpha = 0.25f), shape)
                    .combinedClickable(
                        onClick = {},
                        onLongClick = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            menu = true
                        },
                        onLongClickLabel = if (onDelete != null) stringResource(R.string.copy_share_edit_or_delete) else stringResource(R.string.copy_or_share),
                    )
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Block(utterance, spoken, pair, utterance.trimmedSource, spoken = true)
                if (!utterance.isSourceOnly) {
                    HorizontalDivider(color = ink.copy(alpha = 0.2f))
                    Translation(utterance, pair, onRetry)
                }
            }
            CopyMenu(menu, onDismiss = { menu = false }, utterance, onEdit, onDelete)
        }
    }
}

@Composable
private fun ColumnScope.Translation(utterance: Utterance, pair: LanguagePair, onRetry: () -> Unit) {
    val target = utterance.target
    if (utterance.translation.isNotEmpty()) {
        val settled = utterance.translationState == TranslationState.Current || utterance.isFinal
        Column(Modifier.alpha(if (settled) 1f else 0.75f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Block(utterance, target, pair, utterance.translation, spoken = false)
        }
        StatusLine(utterance, onRetry)
    } else if (utterance.showsLanguagePrompt || target == null) {
        PendingLanguageLabel(utterance, onTranslate = onRetry)
    } else {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            LanguageTag(target, pair)
            StatusLine(utterance, onRetry)
            val state = utterance.translationState
            if (state == TranslationState.Working || state == TranslationState.Idle) TypingDots(target.ink(pair))
        }
    }
}

@Composable
private fun Block(utterance: Utterance, language: Language?, pair: LanguagePair, text: String, spoken: Boolean) {
    val missingSource = spoken && text.isEmpty() && utterance.isFinal
    val ink = language?.ink(pair) ?: MaterialTheme.colorScheme.onSurfaceVariant
    InLanguage(language) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            OptionalLanguageTag(language, pair, spoken = spoken, unknownTitle = if (spoken) utterance.unidentifiedLanguageTitle else stringResource(R.string.automatic))
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    if (missingSource) "—" else text,
                    style = (if (spoken) MaterialTheme.typography.bodyLarge else MaterialTheme.typography.titleLarge).inLanguage(language),
                    fontWeight = if (spoken) FontWeight.Normal else FontWeight.Medium,
                    color = if (spoken) MaterialTheme.colorScheme.onSurface else ink,
                    modifier = Modifier.weight(1f, fill = false).then(missingSourceLabel().takeIf { missingSource } ?: Modifier),
                )
                if (spoken && !utterance.isFinal) TypingDots(ink, Modifier.padding(bottom = 6.dp))
            }
        }
    }
}

/** Read out for the dash that stands in for a turn whose own words never arrived. */
@Composable
private fun missingSourceLabel(): Modifier {
    val label = stringResource(R.string.original_transcript_unavailable)
    return Modifier.semantics { contentDescription = label }
}

@Composable
private fun StatusLine(utterance: Utterance, onRetry: () -> Unit) {
    when (val state = utterance.translationState) {
        TranslationState.AwaitingPartner -> PendingLanguageLabel(utterance, onTranslate = onRetry)
        TranslationState.WaitingForNetwork -> Caption(Icons.Rounded.WifiOff, stringResource(R.string.waiting_for_connection))
        is TranslationState.Failed -> RetryButton(stringResource(R.string.value_retry, state.message), onRetry)
        else -> if (utterance.isLate) Caption(Icons.Rounded.History, stringResource(R.string.delayed_transcription))
    }
}

@Composable
fun Caption(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        Text(text, style = MaterialTheme.typography.labelMedium, color = color)
    }
}

/** A [Caption] that's a borderless button. */
@Composable
fun CaptionButton(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, color: Color, onClick: () -> Unit) {
    TextButton(onClick = onClick, contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp)) {
        Caption(icon, text, color = color)
    }
}

@Composable
fun RetryButton(text: String, onClick: () -> Unit) = CaptionButton(Icons.Rounded.Refresh, text, Lively.colors.warning, onClick)

@Composable
private fun CopyMenu(expanded: Boolean, onDismiss: () -> Unit, utterance: Utterance, onEdit: (() -> Unit)?, onDelete: (() -> Unit)?) {
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun copy(text: String) {
        scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Lively", text))) }
        onDismiss()
    }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, shape = RoundedCornerShape(16.dp)) {
        if (utterance.trimmedSource.isNotEmpty()) {
            DropdownMenuItem(
                text = { Text(utterance.sourceLanguage?.let { stringResource(R.string.copy_value, it.nativeName) } ?: stringResource(R.string.copy_original)) },
                leadingIcon = { Icon(Icons.Rounded.ContentCopy, null) },
                onClick = { copy(utterance.trimmedSource) },
            )
        }
        if (utterance.translation.isNotEmpty()) {
            DropdownMenuItem(
                text = { Text(utterance.target?.let { stringResource(R.string.copy_value, it.nativeName) } ?: stringResource(R.string.copy_translation)) },
                leadingIcon = { Icon(Icons.Rounded.ContentCopy, null) },
                onClick = { copy(utterance.translation) },
            )
        }
        DropdownMenuItem(
            text = { Text(stringResource(R.string.share)) },
            leadingIcon = { Icon(Icons.Rounded.Share, null) },
            onClick = {
                onDismiss()
                val text = listOf(utterance.trimmedSource, utterance.translation).filter { it.isNotEmpty() }.joinToString("\n")
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
                context.startActivity(Intent.createChooser(send, null))
            },
        )
        if (onEdit != null && utterance.isFinal) EditMenuItem { onDismiss(); onEdit() }
        if (onDelete != null) {
            HorizontalDivider()
            DeleteMenuItem { onDismiss(); onDelete() }
        }
    }
}

@Composable
private fun EditMenuItem(onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(stringResource(R.string.edit)) },
        leadingIcon = { Icon(Icons.Rounded.Edit, null) },
        onClick = onClick,
    )
}

@Composable
private fun DeleteMenuItem(onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(stringResource(R.string.delete), color = MaterialTheme.colorScheme.error) },
        leadingIcon = { Icon(Icons.Rounded.DeleteOutline, null, tint = MaterialTheme.colorScheme.error) },
        onClick = onClick,
    )
}

/** Swipe a transcript turn toward the start edge to delete it. */
@Composable
private fun SwipeToDelete(onDelete: () -> Unit, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val state = rememberSwipeToDismissBoxState()
    SwipeToDismissBox(
        state = state,
        modifier = modifier,
        enableDismissFromStartToEnd = false,
        onDismiss = { onDelete() },
        backgroundContent = {
            // Bubbles don't fill the row, so draw nothing until a swipe starts.
            if (state.dismissDirection != SwipeToDismissBoxValue.EndToStart) return@SwipeToDismissBox
            val armed = state.targetValue == SwipeToDismissBoxValue.EndToStart
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(24.dp))
                    .background(if (armed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.errorContainer)
                    .padding(horizontal = 24.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Icon(
                    Icons.Rounded.DeleteOutline,
                    contentDescription = null,
                    tint = if (armed) MaterialTheme.colorScheme.onError else MaterialTheme.colorScheme.onErrorContainer,
                )
            }
        },
        content = { content() },
    )
}

/**
 * Wide layout (unfolded foldables, landscape, tablets, Chromebooks): the two
 * languages in side-by-side columns, one row per turn. Each person reads
 * straight down their own column.
 */
@Composable
fun ParallelTranscript(
    store: ConversationStore,
    pair: LanguagePair,
    onEdit: (Utterance) -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
) {
    val utterances = store.visibleUtterances
    Column(modifier.fillMaxSize().padding(top = contentPadding.calculateTopPadding())) {
        Row(Modifier.padding(horizontal = 20.dp).padding(bottom = 8.dp)) {
            if (store.isAutomaticLanguageMode) {
                Header(store.listenerLanguage, pair, Modifier.weight(1f), role = stringResource(R.string.your_language))
                Header(store.detectedPartnerLanguage, pair, Modifier.weight(1f), role = stringResource(R.string.other_language))
            } else {
                Header(pair.first, pair, Modifier.weight(1f))
                Header(pair.second, pair, Modifier.weight(1f))
            }
        }
        val state = rememberPinnedListState(utterances.size)
        LazyColumn(
            state = state,
            reverseLayout = true,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = contentPadding.calculateBottomPadding()),
        ) {
            items(utterances.asReversed(), key = { it.id }) { utterance ->
                Column(Modifier.animateItem()) {
                    SwipeToDelete(onDelete = { store.delete(utterance) }) {
                        ParallelRow(utterance, pair, onRetry = { store.retryTranslation(utterance) }, onEdit = { onEdit(utterance) }, onDelete = { store.delete(utterance) })
                    }
                    HorizontalDivider(Modifier.alpha(0.4f))
                }
            }
        }
    }
}

@Composable
private fun Header(language: Language?, pair: LanguagePair, modifier: Modifier, role: String? = null) {
    val ink = language?.ink(pair) ?: MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(width = 18.dp, height = 4.dp).background(ink, CircleShape))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (role != null) Text(role, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(language?.nativeName ?: stringResource(R.string.automatic), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = ink)
        }
    }
}

@Composable
private fun ParallelRow(utterance: Utterance, pair: LanguagePair, onRetry: () -> Unit, onEdit: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    Box {
        Row(
            Modifier
                .background(MaterialTheme.colorScheme.background)
                .combinedClickable(
                    onClick = {},
                    onLongClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        menu = true
                    },
                    onLongClickLabel = stringResource(R.string.edit_or_delete),
                )
                .padding(vertical = 14.dp),
        ) {
            if (!utterance.isAutomatic) {
                for (language in utterance.languages.all) ParallelCell(utterance, language, pair, onRetry)
            } else if (utterance.isSourceOnly) {
                Spacer(Modifier.weight(1f))
                ParallelCell(utterance, utterance.sourceLanguage, pair, onRetry, TranscriptRole.PARTNER)
            } else if (utterance.sourceLanguage == null && utterance.target == null) {
                NeutralCaption(utterance, pair, onRetry)
            } else {
                for (role in TranscriptRole.entries) ParallelCell(utterance, role.language(utterance), pair, onRetry, role)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = RoundedCornerShape(16.dp)) {
            if (utterance.isFinal) EditMenuItem { menu = false; onEdit() }
            DeleteMenuItem { menu = false; onDelete() }
        }
    }
}

@Composable
private fun RowScope.ParallelCell(utterance: Utterance, language: Language?, pair: LanguagePair, onRetry: () -> Unit, role: TranscriptRole? = null) {
    val spoken = role?.isSource(utterance) ?: (utterance.sourceLanguage == language)
    val text = role?.text(utterance) ?: language?.let(utterance::text).orEmpty()
    val ink = language?.ink(pair) ?: MaterialTheme.colorScheme.onSurfaceVariant
    InLanguage(language) {
        Column(
            Modifier
                .weight(1f)
                .padding(horizontal = 4.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(if (spoken) ink.copy(alpha = 0.06f) else Color.Transparent)
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            OptionalLanguageTag(language, pair, spoken = spoken)
            if (text.isEmpty()) {
                if (utterance.isFinal && !utterance.showsLanguagePrompt && ((spoken && utterance.source.isEmpty()) || language == null)) {
                    Text("—", color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f), modifier = missingSourceLabel())
                } else if (utterance.showsLanguagePrompt) {
                    PendingLanguageLabel(utterance, onTranslate = onRetry)
                } else if (utterance.hasTranslationProblem) {
                    StatusLine(utterance, onRetry)
                } else {
                    TypingDots(ink, Modifier.padding(top = 6.dp))
                }
            } else {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text,
                        style = MaterialTheme.typography.titleLarge.inLanguage(language),
                        fontWeight = if (spoken) FontWeight.Normal else FontWeight.Medium,
                        color = if (spoken) MaterialTheme.colorScheme.onSurface else ink,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (spoken && !utterance.isFinal) TypingDots(ink, Modifier.padding(bottom = 8.dp))
                }
                if (!spoken) StatusLine(utterance, onRetry)
            }
        }
    }
}

/** A turn whose language isn't known yet belongs to neither column. */
@Composable
private fun RowScope.NeutralCaption(utterance: Utterance, pair: LanguagePair, onRetry: () -> Unit) {
    Column(Modifier.weight(1f).padding(horizontal = 14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        OptionalLanguageTag(null, pair, unknownTitle = utterance.unidentifiedLanguageTitle)
        Text(utterance.trimmedSource, style = MaterialTheme.typography.titleLarge)
        PendingLanguageLabel(utterance, onTranslate = onRetry)
    }
}

@Composable
fun EmptyConversation(
    store: ConversationStore,
    pair: LanguagePair,
    script: ChineseScript,
    modifier: Modifier = Modifier,
    showsListeningPrompt: Boolean = true,
) {
    val isListening = store.isListening
    val automatic = store.isAutomaticLanguageMode
    val shown by animateFloatAsState(if (showsListeningPrompt) 1f else 0f, tween(250), label = "prompt")
    Column(
        modifier
            .fillMaxSize()
            .padding(32.dp)
            .alpha(shown)
            .then(if (showsListeningPrompt) Modifier else Modifier.clearAndSetSemantics {}),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Outlined.Forum,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            modifier = Modifier.size(52.dp),
        )
        Spacer(Modifier.height(18.dp))
        @Composable
        fun Prompt(text: String, color: Color, language: Language? = null) {
            Text(
                text,
                style = MaterialTheme.typography.titleLarge.inLanguage(language),
                fontWeight = FontWeight.SemiBold,
                color = color,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(6.dp))
        }
        fun prompt(language: Language): String {
            val phrases = language.phrases(script)
            return when {
                isListening && store.status == ConnectionStatus.Offline -> phrases.waitingForConnection
                store.isConnecting -> phrases.connecting
                isListening -> phrases.listening
                else -> phrases.tapToStart
            }
        }
        val own = if (automatic) store.listenerLanguage else pair.first
        Prompt(prompt(own), MaterialTheme.colorScheme.onSurface, own)
        val partner = if (automatic) store.detectedPartnerLanguage else pair.second
        if (partner != null) {
            Prompt(prompt(partner), partner.ink(pair), partner)
        } else {
            Prompt(if (isListening) stringResource(R.string.listening_for_another_language) else stringResource(R.string.other_language_automatic), MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.height(12.dp))
        Text(
            when {
                !automatic -> stringResource(R.string.transcript_pair_prompt, pair.first.displayName, pair.second.displayName)
                store.isOnline -> stringResource(R.string.transcript_automatic_prompt, store.listenerLanguage.displayName)
                // iOS goes on to point at its On-device engine, which Android doesn't have.
                else -> stringResource(R.string.automatic_detection_needs_internet)
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 320.dp),
        )
    }
}
