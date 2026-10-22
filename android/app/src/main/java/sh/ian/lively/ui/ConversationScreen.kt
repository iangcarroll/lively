package sh.ian.lively.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Splitscreen
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.Pro

/** Unfolded foldables, landscape phones, tablets and Chromebooks get side-by-side columns. */
val WideBreakpoint = 600.dp

@Composable
fun ConversationScreen(
    store: ConversationStore,
    settings: AppSettings,
    pro: Pro,
    /** On phones, face-to-face is the main layout; the transcript is an alternative. */
    showsTranscript: Boolean,
    onShowsTranscriptChange: (Boolean) -> Unit,
    nearLanguage: Language,
    onNearLanguageChange: (Language) -> Unit,
    onShowSettings: () -> Unit,
    onShowPro: () -> Unit,
) {
    val pair = settings.languages
    // The near side's language, kept within the current pair.
    val near = if (nearLanguage in pair) nearLanguage else pair.first
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        val wide = maxWidth >= WideBreakpoint
        AnimatedContent(
            targetState = !wide && !showsTranscript,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            label = "layout",
        ) { faceToFace ->
            if (faceToFace) {
                FaceToFaceScreen(
                    store = store,
                    pair = pair,
                    script = settings.chineseScript,
                    nearLanguage = near,
                    onSwap = { onNearLanguageChange(pair.other(near)) },
                    onShowTranscript = { onShowsTranscriptChange(true) },
                    onShowSettings = onShowSettings,
                    modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
                    contentPadding = WindowInsets.safeDrawing.asPaddingValues(),
                )
            } else {
                TranscriptLayout(store, settings, wide, onFaceToFace = { onShowsTranscriptChange(false) }, onShowSettings)
            }
        }
    }

    store.alert?.let { message ->
        val dismiss = {
            store.alert = null
            pro.freeLimitReached = false
        }
        AlertDialog(
            onDismissRequest = dismiss,
            title = { Text("Lively") },
            text = { Text(message) },
            confirmButton = {
                Row {
                    if (!settings.hasCredentials) {
                        TextButton(onClick = { dismiss(); onShowSettings() }) { Text("Open Settings") }
                    }
                    if (pro.freeLimitReached && !pro.isPro) {
                        TextButton(onClick = { dismiss(); onShowPro() }) { Text("Get Lively Pro") }
                    }
                    TextButton(onClick = dismiss) { Text("OK") }
                }
            },
        )
    }
}

@Composable
private fun TranscriptLayout(
    store: ConversationStore,
    settings: AppSettings,
    wide: Boolean,
    onFaceToFace: () -> Unit,
    onShowSettings: () -> Unit,
) {
    val insets = WindowInsets.safeDrawing.asPaddingValues()
    Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))) {
        val barSpace = PaddingValues(top = insets.calculateTopPadding() + 64.dp, bottom = insets.calculateBottomPadding() + 104.dp)
        val utterances = store.visibleUtterances
        when {
            utterances.isEmpty() -> EmptyConversation(store.isListening, settings.languages, settings.chineseScript, Modifier.padding(barSpace))
            wide -> ParallelTranscript(utterances, settings.languages, store::retryTranslation, contentPadding = barSpace)
            else -> ChatTranscript(utterances, settings.languages, store::retryTranslation, contentPadding = barSpace)
        }

        // Top bar: status, then layout and settings.
        Row(
            Modifier
                .fillMaxWidth()
                .background(scrim(MaterialTheme.colorScheme.background, fadeAtBottom = true))
                .padding(top = insets.calculateTopPadding())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            StatusPill(store.status, store.isListening)
            Spacer(Modifier.weight(1f))
            if (!wide) TonalIconButton(Icons.Rounded.Splitscreen, "Face-to-face mode", onFaceToFace)
            TonalIconButton(Icons.Rounded.Settings, "Settings", onShowSettings)
        }

        // Bottom controls: clear, and the mic in the middle.
        Row(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(scrim(MaterialTheme.colorScheme.background, fadeAtBottom = false))
                .padding(bottom = insets.calculateBottomPadding())
                .padding(start = 24.dp, end = 24.dp, top = 24.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TonalIconButton(Icons.Rounded.DeleteOutline, "Clear conversation", store::clear, enabled = store.utterances.isNotEmpty())
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                MicButton(store.isListening, store.level, onClick = store::toggleListening)
            }
            // Balances the left button so the mic stays centered.
            Spacer(Modifier.size(48.dp))
        }
    }
}


/** Solid behind the bar's controls, fading out toward the content, so text scrolls away under it. */
private fun scrim(color: Color, fadeAtBottom: Boolean): Brush {
    val stops = arrayOf(0f to color, 0.7f to color, 1f to color.copy(alpha = 0f))
    return if (fadeAtBottom) Brush.verticalGradient(*stops) else Brush.verticalGradient(*stops.map { (1f - it.first) to it.second }.reversed().toTypedArray())
}
