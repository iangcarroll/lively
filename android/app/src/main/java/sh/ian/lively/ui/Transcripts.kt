package sh.ian.lively.ui

import android.content.ClipData
import android.content.Intent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.TranslationState
import sh.ian.lively.model.Utterance
import sh.ian.lively.model.phrases
import sh.ian.lively.model.ChineseScript

/** Lays out [content] the way [language] is written, and tags its text for the right glyphs. */
@Composable
fun InLanguage(language: Language, content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalLayoutDirection provides if (language.isRightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr,
        content = content,
    )
}

/** For text styles, so Han characters get Chinese rather than Japanese glyphs, and so on. */
fun Language.localeList() = LocaleList(locale.toLanguageTag())

/** Keeps a reversed list pinned to the newest item as items arrive. */
@Composable
private fun rememberPinnedListState(count: Int) = rememberLazyListState().also { state ->
    LaunchedEffect(count) { if (state.firstVisibleItemIndex <= 1) state.animateScrollToItem(0) }
}

/** Narrow layout: a single chat-style feed. */
@Composable
fun ChatTranscript(
    utterances: List<Utterance>,
    pair: LanguagePair,
    onRetry: (Utterance) -> Unit,
    onDelete: (Utterance) -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
) {
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
            SwipeToDelete(onDelete = { onDelete(utterance) }, modifier = Modifier.animateItem()) {
                UtteranceBubble(utterance, pair, onRetry = { onRetry(utterance) }, onDelete = { onDelete(utterance) })
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
    onDelete: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val spoken = utterance.language
    val leading = spoken == utterance.languages.first
    val ink = spoken.ink(pair)
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val shape = RoundedCornerShape(24.dp)
    Row(modifier.fillMaxWidth(), horizontalArrangement = if (leading) Arrangement.Start else Arrangement.End) {
        Box {
            Column(
                Modifier
                    .widthIn(max = 520.dp)
                    .padding(start = if (leading) 0.dp else 40.dp, end = if (leading) 40.dp else 0.dp)
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
                        onLongClickLabel = if (onDelete != null) "Copy, share or delete" else "Copy or share",
                    )
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Block(spoken, pair, utterance.trimmedSource, spoken = true, typing = !utterance.isFinal)
                HorizontalDivider(color = ink.copy(alpha = 0.2f))
                val target = utterance.target
                if (utterance.translation.isNotEmpty()) {
                    val settled = utterance.translationState == TranslationState.Current || utterance.isFinal
                    Column(Modifier.alpha(if (settled) 1f else 0.75f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Block(target, pair, utterance.translation, spoken = false, typing = false)
                    }
                    StatusLine(utterance, onRetry)
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        LanguageTag(target, pair)
                        StatusLine(utterance, onRetry)
                        val state = utterance.translationState
                        if (state == TranslationState.Working || state == TranslationState.Idle) TypingDots(target.ink(pair))
                    }
                }
            }
            CopyMenu(menu, onDismiss = { menu = false }, utterance, onDelete)
        }
    }
}

@Composable
private fun Block(language: Language, pair: LanguagePair, text: String, spoken: Boolean, typing: Boolean) {
    InLanguage(language) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            LanguageTag(language, pair, spoken = spoken)
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text,
                    style = (if (spoken) MaterialTheme.typography.bodyLarge else MaterialTheme.typography.titleLarge)
                        .copy(localeList = language.localeList()),
                    fontWeight = if (spoken) FontWeight.Normal else FontWeight.Medium,
                    color = if (spoken) MaterialTheme.colorScheme.onSurface else language.ink(pair),
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (spoken && typing) TypingDots(language.ink(pair), Modifier.padding(bottom = 6.dp))
            }
        }
    }
}

@Composable
private fun StatusLine(utterance: Utterance, onRetry: () -> Unit) {
    when (val state = utterance.translationState) {
        TranslationState.WaitingForNetwork -> Caption(Icons.Rounded.WifiOff, "Waiting for connection")
        is TranslationState.Failed -> RetryButton("${state.message} · Retry", onRetry)
        else -> if (utterance.isLate) Caption(Icons.Rounded.History, "Caught up after a dropout")
    }
}

@Composable
fun Caption(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        Text(text, style = MaterialTheme.typography.labelMedium, color = color)
    }
}

@Composable
fun RetryButton(text: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp)) {
        Caption(Icons.Rounded.Refresh, text, color = Lively.colors.warning)
    }
}

@Composable
private fun CopyMenu(expanded: Boolean, onDismiss: () -> Unit, utterance: Utterance, onDelete: (() -> Unit)?) {
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun copy(text: String) {
        scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Lively", text))) }
        onDismiss()
    }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, shape = RoundedCornerShape(16.dp)) {
        DropdownMenuItem(
            text = { Text("Copy ${utterance.language.nativeName}") },
            leadingIcon = { Icon(Icons.Rounded.ContentCopy, null) },
            onClick = { copy(utterance.trimmedSource) },
        )
        if (utterance.translation.isNotEmpty()) {
            DropdownMenuItem(
                text = { Text("Copy ${utterance.target.nativeName}") },
                leadingIcon = { Icon(Icons.Rounded.ContentCopy, null) },
                onClick = { copy(utterance.translation) },
            )
        }
        DropdownMenuItem(
            text = { Text("Share") },
            leadingIcon = { Icon(Icons.Rounded.Share, null) },
            onClick = {
                onDismiss()
                val text = listOf(utterance.trimmedSource, utterance.translation).filter { it.isNotEmpty() }.joinToString("\n")
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
                context.startActivity(Intent.createChooser(send, null))
            },
        )
        if (onDelete != null) {
            HorizontalDivider()
            DeleteMenuItem { onDismiss(); onDelete() }
        }
    }
}

@Composable
private fun DeleteMenuItem(onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
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
    utterances: List<Utterance>,
    pair: LanguagePair,
    onRetry: (Utterance) -> Unit,
    onDelete: (Utterance) -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
) {
    Column(modifier.fillMaxSize().padding(top = contentPadding.calculateTopPadding())) {
        Row(Modifier.padding(horizontal = 20.dp).padding(bottom = 8.dp)) {
            Header(pair.first, pair, Modifier.weight(1f))
            Header(pair.second, pair, Modifier.weight(1f))
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
                    SwipeToDelete(onDelete = { onDelete(utterance) }) {
                        ParallelRow(utterance, pair, onRetry = { onRetry(utterance) }, onDelete = { onDelete(utterance) })
                    }
                    HorizontalDivider(Modifier.alpha(0.4f))
                }
            }
        }
    }
}

@Composable
private fun Header(language: Language, pair: LanguagePair, modifier: Modifier) {
    Row(modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(width = 18.dp, height = 4.dp).background(language.ink(pair), CircleShape))
        Text(language.nativeName, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = language.ink(pair))
    }
}

@Composable
private fun ParallelRow(utterance: Utterance, pair: LanguagePair, onRetry: () -> Unit, onDelete: () -> Unit) {
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
                    onLongClickLabel = "Delete",
                )
                .padding(vertical = 14.dp),
        ) {
            for (language in utterance.languages.all) {
                val spoken = utterance.language == language
                val text = utterance.text(language)
                InLanguage(language) {
                    Column(
                        Modifier
                            .weight(1f)
                            .padding(horizontal = 4.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(if (spoken) language.ink(pair).copy(alpha = 0.06f) else Color.Transparent)
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        LanguageTag(language, pair, spoken = spoken)
                        if (text.isEmpty()) {
                            when (utterance.translationState) {
                                TranslationState.WaitingForNetwork, is TranslationState.Failed -> StatusLine(utterance, onRetry)
                                else -> TypingDots(language.ink(pair), Modifier.padding(top = 6.dp))
                            }
                        } else {
                            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(
                                    text,
                                    style = MaterialTheme.typography.titleLarge.copy(localeList = language.localeList()),
                                    fontWeight = if (spoken) FontWeight.Normal else FontWeight.Medium,
                                    color = if (spoken) MaterialTheme.colorScheme.onSurface else language.ink(pair),
                                    modifier = Modifier.weight(1f, fill = false),
                                )
                                if (spoken && !utterance.isFinal) TypingDots(language.ink(pair), Modifier.padding(bottom = 8.dp))
                            }
                            if (!spoken) StatusLine(utterance, onRetry)
                        }
                    }
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = RoundedCornerShape(16.dp)) {
            DeleteMenuItem { menu = false; onDelete() }
        }
    }
}

@Composable
fun EmptyConversation(isListening: Boolean, pair: LanguagePair, script: ChineseScript, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
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
        for (language in pair.all) {
            val phrases = language.phrases(script)
            Text(
                if (isListening) phrases.listening else phrases.tapToStart,
                style = MaterialTheme.typography.titleLarge.copy(localeList = language.localeList()),
                fontWeight = FontWeight.SemiBold,
                color = if (language == pair.second) language.ink(pair) else MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(6.dp))
        }
        Spacer(Modifier.height(12.dp))
        Text(
            "Lively hears ${pair.first.englishName} and ${pair.second.englishName} and translates both ways. No need to say who's speaking.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 320.dp),
        )
    }
}
