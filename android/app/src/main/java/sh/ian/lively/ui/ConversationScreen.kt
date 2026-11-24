package sh.ian.lively.ui

import sh.ian.lively.R
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material.icons.rounded.LocationOn
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Place
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import sh.ian.lively.model.ConnectionStatus
import androidx.compose.material.icons.rounded.Splitscreen
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.foundation.layout.exclude
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import sh.ian.lively.support.DebugFlags
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.window.Dialog
import sh.ian.lively.model.LocationLanguages
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import kotlinx.coroutines.launch
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.ConversationMode
import sh.ian.lively.model.SpeechProviders
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.Pro
import sh.ian.lively.model.Utterance

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
    /** In an automatic conversation, whether the listener has the near side. */
    listenerNear: Boolean,
    onListenerNearChange: (Boolean) -> Unit,
    onShowSettings: () -> Unit,
    /** Opens the address lookup, which is separate from the conversation. */
    onShowAddress: () -> Unit,
    /** Opens Lively Pro saying today's free time has run out. */
    onShowLimit: () -> Unit,
) {
    val resources = LocalResources.current
    val pair = settings.languages
    // The near side's language, kept within the current pair.
    val near = when {
        store.isAutomaticLanguageMode -> store.listenerLanguage
        nearLanguage in pair -> nearLanguage
        else -> pair.first
    }
    val automaticOffline = store.isAutomaticLanguageMode && !store.isOnline
    // The banner below takes the top inset when it's shown.
    val insets = if (automaticOffline) WindowInsets.safeDrawing.exclude(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)) else WindowInsets.safeDrawing
    var showsTextInput by rememberSaveable { mutableStateOf(false) }
    var showsLanguages by rememberSaveable { mutableStateOf(false) }
    // The listening guidance fades once a live conversation is under way and
    // returns when the phone is handed over. Settings, Pro and the address
    // lookup are other destinations, which pause it by leaving this one.
    val listeningPrompt = rememberListeningPromptVisibility(
        isLive = store.isListening && store.status == ConnectionStatus.Live,
        isCovered = showsLanguages,
    )
    /** The turn being corrected in the text bar. */
    var editing by remember { mutableStateOf<Utterance?>(null) }
    /** The bar opened for an edit, so it closes when the edit ends. */
    var textInputOpenedForEdit by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    // Hiding drops the keyboard first, while the field is still there, so the
    // layout follows the keyboard's animation; removing a focused field leaves
    // the keyboard up a moment and then makes everything jump.
    val setShowsTextInput = { shown: Boolean ->
        if (shown) {
            showsTextInput = true
        } else if (showsTextInput) {
            keyboard?.hide()
            focusManager.clearFocus()
            editing = null
            textInputOpenedForEdit = false
            scope.launch {
                withFrameNanos {}
                showsTextInput = false
            }
        }
    }
    // Opens the text bar on a turn's transcript to correct it.
    val startEditing = { utterance: Utterance ->
        textInputOpenedForEdit = !showsTextInput
        editing = utterance
        showsTextInput = true
    }
    val endEditing = {
        editing = null
        if (textInputOpenedForEdit) setShowsTextInput(false)
    }
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        if (automaticOffline) {
            Text(
                // iOS goes on to offer on-device translation with a pair, which Android doesn't have.
                stringResource(R.string.automatic_detection_needs_internet),
                Modifier
                    .fillMaxWidth()
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
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
                        listenerNear = listenerNear,
                        onSwap = {
                            if (store.isAutomaticLanguageMode) onListenerNearChange(!listenerNear) else onNearLanguageChange(pair.other(near))
                        },
                        showsTextInput = showsTextInput,
                        onShowsTextInputChange = setShowsTextInput,
                        editing = editing,
                        onEdit = startEditing,
                        onEndEditing = endEditing,
                        onShowTranscript = { onShowsTranscriptChange(true) },
                        onShowSettings = onShowSettings,
                        onShowAddress = onShowAddress,
                        onChangeLanguages = { showsLanguages = true },
                        contentPadding = insets.asPaddingValues(),
                        showsListeningPrompt = listeningPrompt.showsListeningPrompt,
                    )
                } else {
                    TranscriptLayout(
                        store, settings, wide, insets,
                        showsTextInput = showsTextInput,
                        onShowsTextInputChange = setShowsTextInput,
                        editing = editing,
                        onEdit = startEditing,
                        onEndEditing = endEditing,
                        onFaceToFace = { onShowsTranscriptChange(false) },
                        onShowSettings = onShowSettings,
                        onShowAddress = onShowAddress,
                        onChangeLanguages = { showsLanguages = true },
                        showsListeningPrompt = listeningPrompt.showsListeningPrompt,
                    )
                }
            }
        }
    }

    if (showsLanguages) {
        LanguagesSheet(settings, onDismiss = {
            showsLanguages = false
            // Like closing Settings: a new pair starts a new conversation.
            store.settingsDidClose()
        })
    }

    // `LivelyLimit`: as if today's free time had just run out.
    LaunchedEffect(Unit) {
        if (DebugFlags.limit) {
            DebugFlags.limit = false
            pro.freeLimitReached = true
            store.alert = resources.getString(R.string.todays_free_translation_time_is_used_up)
        }
    }

    // Out of free time: Lively Pro itself, rather than an alert that leads to
    // it. The alert and the flag are cleared on the way, so coming back from
    // that screen doesn't open it again.
    val limitReached = store.alert != null && pro.freeLimitReached && !pro.isPro
    LaunchedEffect(limitReached) {
        if (limitReached) {
            store.alert = null
            pro.freeLimitReached = false
            onShowLimit()
        }
    }

    store.alert?.takeIf { !limitReached }?.let { message ->
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
                        TextButton(onClick = { dismiss(); onShowSettings() }) { Text(stringResource(R.string.open_settings)) }
                    }
                    TextButton(onClick = dismiss) { Text(stringResource(R.string.ok)) }
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
    /** The safe area, less whatever a banner above has taken. */
    safeArea: WindowInsets,
    showsTextInput: Boolean,
    onShowsTextInputChange: (Boolean) -> Unit,
    editing: Utterance?,
    onEdit: (Utterance) -> Unit,
    onEndEditing: () -> Unit,
    onFaceToFace: () -> Unit,
    onShowSettings: () -> Unit,
    onShowAddress: () -> Unit,
    onChangeLanguages: () -> Unit,
    showsListeningPrompt: Boolean = true,
) {
    val insets = safeArea.asPaddingValues()
    val automatic = store.isAutomaticLanguageMode
    Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))) {
        val barSpace = PaddingValues(top = insets.calculateTopPadding() + 64.dp, bottom = insets.calculateBottomPadding() + (if (showsTextInput) 176.dp else 104.dp)
            // The Start/Stop caption, and the listening prompt once there are turns.
            + 22.dp + if (store.visibleUtterances.isEmpty() || !showsListeningPrompt) 0.dp else 84.dp)
        when {
            store.visibleUtterances.isEmpty() -> EmptyConversation(store, settings.languages, settings.chineseScript, Modifier.padding(barSpace), showsListeningPrompt)
            wide -> ParallelTranscript(store, settings.languages, onEdit, contentPadding = barSpace)
            else -> ChatTranscript(store, settings.languages, onEdit, contentPadding = barSpace)
        }

        // Top bar: status and the languages, then layout and settings.
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
            LanguagePairButton(
                first = if (automatic) store.listenerLanguage else settings.languages.first,
                second = if (automatic) store.detectedPartnerLanguage else settings.languages.second,
                pair = settings.languages,
                onClick = onChangeLanguages,
                modifier = Modifier.weight(1f),
            )
            // Turned on from the menu in face-to-face or Settings; shown while
            // on, so it can be stopped from here.
            if (store.speaksTranslations) SpeakAloudButton(store)
            if (!wide) TonalIconButton(Icons.Rounded.Splitscreen, stringResource(R.string.face_to_face_mode), onFaceToFace)
            Box {
                var menu by remember { mutableStateOf(false) }
                TonalIconButton(Icons.Rounded.MoreVert, stringResource(R.string.more), onClick = { menu = true })
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = RoundedCornerShape(16.dp)) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.address)) },
                        leadingIcon = { Icon(Icons.Rounded.Place, null) },
                        onClick = { menu = false; onShowAddress() },
                    )
                    HorizontalDivider()
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.settings)) },
                        leadingIcon = { Icon(Icons.Rounded.Settings, null) },
                        onClick = { menu = false; onShowSettings() },
                    )
                }
            }
        }

        // Bottom controls: clear, the mic in the middle, and text input.
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(scrim(MaterialTheme.colorScheme.background, fadeAtBottom = false))
                .padding(bottom = insets.calculateBottomPadding())
                .padding(top = 24.dp, bottom = 12.dp),
        ) {
            AnimatedVisibility(showsTextInput, enter = fadeIn(), exit = fadeOut()) {
                TypeToTranslateBar(
                    store, if (automatic) null else settings.languages,
                    if (automatic) store.listenerLanguage else settings.languages.first,
                    onClose = { onShowsTextInputChange(false) },
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
                    editing = editing,
                    onEndEditing = onEndEditing,
                )
            }
            if (store.visibleUtterances.isNotEmpty() && showsListeningPrompt) {
                TranscriptListeningStatus(
                    store, settings.languages, settings.chineseScript,
                    Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
                )
            }
            Row(
                Modifier.padding(horizontal = 24.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TonalIconButton(Icons.Rounded.DeleteOutline, stringResource(R.string.clear_conversation), store::clear, enabled = store.utterances.isNotEmpty())
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                    MicButton(
                        store.isListening, store.level, onClick = store::toggleListening, isHearing = store.isHearing,
                        onHoldStart = store::startListening, onHoldEnd = store::stopListening,
                    )
                }
                TextInputToggle(showsTextInput, onShowsTextInputChange)
            }
            // The mic's own label is read by TalkBack; this one is for the eye.
            Text(
                if (store.isListening) stringResource(R.string.stop) else stringResource(R.string.start),
                Modifier.fillMaxWidth().padding(top = 4.dp).clearAndSetSemantics {},
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}


/**
 * Changes the languages without a trip to Settings: the welcome tour's
 * cards, in a sheet over the conversation.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LanguagesSheet(settings: AppSettings, onDismiss: () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Text(stringResource(R.string.languages), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            // Automatic detection is the online engine's; other engines only take a pair.
            if (settings.providerID == SpeechProviders.SONIOX_ID) {
                ConversationModePicker(settings, Modifier.widthIn(max = 420.dp))
            }
            if (settings.usesAutomaticLanguageDetection) {
                AutomaticLanguagePicker(settings, Modifier.widthIn(max = 420.dp))
                ScriptPicker(settings, Modifier.widthIn(max = 320.dp))
            } else {
                LanguagePairPicker(settings, Modifier.widthIn(max = 420.dp))
            }
            Text(
                stringResource(R.string.changing_language_notice),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/** Automatic or a chosen pair, as a segmented control. */
@Composable
fun ConversationModePicker(settings: AppSettings, modifier: Modifier = Modifier) {
    val resources = LocalResources.current
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth().semantics { contentDescription = resources.getString(R.string.conversation) }) {
        ConversationMode.entries.forEachIndexed { index, mode ->
            SegmentedButton(
                selected = settings.conversationMode == mode,
                onClick = { settings.conversationMode = mode },
                shape = SegmentedButtonDefaults.itemShape(index, ConversationMode.entries.size),
                label = { Text(stringResource(mode.labelRes), textAlign = TextAlign.Center) },
            )
        }
    }
}

/** Opens and closes [TypeToTranslateBar]. */
@Composable
fun TextInputToggle(showsTextInput: Boolean, onChange: (Boolean) -> Unit, size: Dp = 48.dp) {
    TonalIconButton(
        if (showsTextInput) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard,
        stringResource(R.string.type_to_translate),
        onClick = { onChange(!showsTextInput) },
        size = size,
    )
}

/** Solid behind the bar's controls, fading out toward the content, so text scrolls away under it. */
private fun scrim(color: Color, fadeAtBottom: Boolean): Brush {
    val stops = arrayOf(0f to color, 0.7f to color, 1f to color.copy(alpha = 0f))
    return if (fadeAtBottom) Brush.verticalGradient(*stops) else Brush.verticalGradient(*stops.map { (1f - it.first) to it.second }.reversed().toTypedArray())
}

/**
 * Asks whether to turn on "Set from location". Saying yes shows the system's
 * location prompt; if the pair can't be set, the card says why before closing.
 * A Material dialog here, where iOS draws the card over the conversation.
 */
@Composable
fun LocationOfferCard(location: LocationLanguages, onDone: (changed: Boolean) -> Unit) {
    var asked by rememberSaveable { mutableStateOf(false) }
    val setUsesLocation = rememberLocationSwitch(location)
    val status = location.status
    val isWorking = status == LocationLanguages.Status.Idle || status == LocationLanguages.Status.Locating
    LaunchedEffect(asked, status) {
        if (asked && status is LocationLanguages.Status.Applied) onDone(true)
    }
    Dialog(onDismissRequest = { onDone(false) }) {
        Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
            Column(
                Modifier.padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                SettingsIcon(Icons.Rounded.LocationOn, MaterialTheme.colorScheme.primary, size = 56.dp)
                Text(
                    stringResource(R.string.set_languages_from_your_location),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                )
                Text(
                    if (asked) status.message ?: stringResource(R.string.finding_where_you_are)
                    else stringResource(R.string.location_offer_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                when {
                    !asked -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        PillButton(stringResource(R.string.use_my_location), onClick = {
                            asked = true
                            setUsesLocation(true)
                        })
                        TextButton(onClick = { onDone(false) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.not_now), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    isWorking -> CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.5.dp)
                    else -> TextButton(onClick = { onDone(false) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        Text(stringResource(R.string.ok), style = MaterialTheme.typography.titleMedium)
                    }
                }
            }
        }
    }
}
