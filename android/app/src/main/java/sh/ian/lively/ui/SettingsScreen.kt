package sh.ian.lively.ui

import sh.ian.lively.R
import androidx.compose.ui.res.stringResource
import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Forum
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Hearing
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Language as LanguageGlobe
import androidx.compose.material.icons.rounded.LocationOn
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.ian.lively.BuildConfig
import sh.ian.lively.audio.PickupRange
import sh.ian.lively.model.Account
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.ConversationMode
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguageSide
import sh.ian.lively.model.Latency
import sh.ian.lively.model.LocationLanguages
import sh.ian.lively.model.Pro
import sh.ian.lively.model.ProviderOption
import sh.ian.lively.model.SpeechProviders

private val Orange = Color(0xFFFF9500)
private val Teal = Color(0xFF30B0C7)
private val Purple = Color(0xFFAF52DE)
private val Green = Color(0xFF34C759)
private val Gray = Color(0xFF8E8E93)
private val Indigo = Color(0xFF5856D6)
private val Pink = Color(0xFFFF2D55)
private val Blue = Color(0xFF007AFF)
private val Red = Color(0xFFFF3B30)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    settings: AppSettings,
    account: Account?,
    pro: Pro,
    location: LocationLanguages,
    hasBroker: Boolean,
    onBack: () -> Unit,
    onAccount: () -> Unit,
    onPro: () -> Unit,
    onLanguage: (LanguageSide) -> Unit,
    /** Opens the list for the reader's own language, in an automatic conversation. */
    onOwnLanguage: () -> Unit,
    onWelcome: () -> Unit,
    onClear: () -> Unit,
) {
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior(rememberTopAppBarState())
    val provider = settings.provider
    // Unsaved key edits by credential id, saved when leaving the screen.
    val drafts = remember { mutableStateMapOf<String, String>().apply { settings.allCredentials.forEach { put(it.id, settings.credential(it)) } } }
    val save by rememberUpdatedState {
        for (credential in settings.allCredentials) {
            drafts[credential.id]?.let { settings.setCredential(it.trim(), credential) }
        }
        if (settings.translationModel.isBlank()) settings.translationModel = AppSettings.DEFAULT_TRANSLATION_MODEL
    }
    DisposableEffect(Unit) { onDispose { save() } }
    var choosingEngine by remember { mutableStateOf(false) }
    var choosingConversation by remember { mutableStateOf(false) }
    val automatic = settings.usesAutomaticLanguageDetection
    var choosingPickupRange by remember { mutableStateOf(false) }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            LargeTopAppBar(
                title = { Text(stringResource(R.string.settings)) },
                navigationIcon = { BackButton(onBack) },
                scrollBehavior = scroll,
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
                if (account != null) {
                    Group {
                        AccountRow(account.email, onAccount)
                    }
                }

                if (hasBroker) {
                    Group(footer = if (!pro.isPro) stringResource(R.string.up_to_10_hours_of_translation_a_day) else null) {
                        Item(
                            icon = { SettingsIcon(Icons.Rounded.Star, Orange) },
                            title = "Lively Pro",
                            value = when {
                                pro.isSubscribed -> stringResource(R.string.active)
                                account?.hasFreePro == true -> stringResource(R.string.included)
                                else -> stringResource(R.string.upgrade)
                            },
                            onClick = onPro,
                        )
                    }
                }

                Group(header = stringResource(R.string.languages), footer = languagesFooter(settings)) {
                    // Automatic detection is the online engine's; other engines only take a pair.
                    if (settings.providerID == SpeechProviders.SONIOX_ID) {
                        Item(
                            icon = { SettingsIcon(Icons.Rounded.Forum, Indigo) },
                            title = stringResource(R.string.conversation),
                            value = stringResource(settings.conversationMode.labelRes),
                            onClick = { choosingConversation = true },
                        )
                        Divider()
                    }
                    if (automatic) {
                        LanguageItem(stringResource(R.string.your_language), settings.speechListenerLanguage, settings, onClick = onOwnLanguage)
                        Divider()
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 14.dp)
                                .semantics(mergeDescendants = true) {},
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            SettingsIcon(Icons.Rounded.LanguageGlobe, Gray)
                            Text(stringResource(R.string.other_language), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Text(stringResource(R.string.automatic), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                        }
                    } else {
                        LanguageItem(stringResource(R.string.first_language), settings.languages.first, settings, onClick = { onLanguage(LanguageSide.FIRST) })
                        Divider()
                        LanguageItem(stringResource(R.string.second_language), settings.languages.second, settings, onClick = { onLanguage(LanguageSide.SECOND) })
                    }
                    if (automatic || Language.CHINESE in settings.languages) {
                        Divider()
                        Row(
                            Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            SettingsIcon(Icons.Rounded.Translate, Teal)
                            Text(stringResource(R.string.chinese_script), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        }
                        ScriptPicker(settings, Modifier.padding(start = 68.dp, end = 16.dp, bottom = 14.dp))
                    }
                }

                // Location chooses a pair, which automatic detection doesn't use.
                if (!automatic) {
                    val setUsesLocation = rememberLocationSwitch(location)
                    Group(footer = listOfNotNull(LocationLanguages.SUMMARY, location.status.message).joinToString(" ")) {
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .toggleable(
                                    value = settings.usesLocationLanguages,
                                    role = Role.Switch,
                                    onValueChange = setUsesLocation,
                                )
                                .padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            SettingsIcon(Icons.Rounded.LocationOn, Blue)
                            Text(stringResource(R.string.set_from_location), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Switch(checked = settings.usesLocationLanguages, onCheckedChange = null)
                        }
                    }
                }

                Group(header = stringResource(R.string.microphone), footer = stringResource(settings.pickupRange.summaryRes)) {
                    Item(
                        icon = { SettingsIcon(Icons.Rounded.Hearing, Green) },
                        title = stringResource(R.string.pickup_range),
                        value = stringResource(settings.pickupRange.labelRes),
                        onClick = { choosingPickupRange = true },
                    )
                }

                val canSpeak = hasBroker || settings.credential(SpeechProviders.sonioxCredential(false)).isNotBlank()
                Group(header = stringResource(R.string.speech_to_speech), footer = speechFooter(settings, canSpeak)) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .toggleable(
                                value = settings.speaksTranslations,
                                enabled = canSpeak,
                                role = Role.Switch,
                                onValueChange = { settings.speaksTranslations = it },
                            )
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        SettingsIcon(Icons.AutoMirrored.Rounded.VolumeUp, Blue)
                        Text(stringResource(R.string.speak_translations_aloud), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        Switch(checked = settings.speaksTranslations, onCheckedChange = null, enabled = canSpeak)
                    }
                }

                Group(header = stringResource(R.string.speech_engine), footer = engineFooter(settings)) {
                    Item(
                        icon = { SettingsIcon(Icons.Rounded.GraphicEq, Purple) },
                        title = stringResource(R.string.engine),
                        value = provider.name,
                        onClick = { choosingEngine = true },
                    )
                    for (credential in provider.credentials) {
                        Divider()
                        KeyField(
                            label = stringResource(credential.nameRes),
                            value = drafts[credential.id].orEmpty(),
                            onValueChange = { drafts[credential.id] = it },
                            onDone = save,
                        )
                    }
                    if (ProviderOption.SPEED in provider.options) {
                        Divider()
                        Row(
                            Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            SettingsIcon(Icons.Rounded.Speed, Orange)
                            Text(stringResource(R.string.speed), style = MaterialTheme.typography.bodyLarge)
                        }
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(start = 68.dp, end = 16.dp, bottom = 14.dp)) {
                            Latency.entries.forEachIndexed { index, latency ->
                                SegmentedButton(
                                    selected = settings.latency == latency,
                                    onClick = { settings.latency = latency },
                                    shape = SegmentedButtonDefaults.itemShape(index, Latency.entries.size),
                                    label = { Text("${stringResource(latency.labelRes)}\n${latency.milliseconds} ms", textAlign = TextAlign.Center, fontSize = 13.sp, lineHeight = 15.sp) },
                                )
                            }
                        }
                    }
                    if (ProviderOption.TRANSLATION_MODEL in provider.options) {
                        Divider()
                        Row(
                            Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            SettingsIcon(Icons.Rounded.Memory, Indigo)
                            OutlinedTextField(
                                value = settings.translationModel,
                                onValueChange = { settings.translationModel = it },
                                label = { Text(stringResource(R.string.model)) },
                                placeholder = { Text(AppSettings.DEFAULT_TRANSLATION_MODEL) },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }

                Group {
                    Item(icon = { SettingsIcon(Icons.Rounded.AutoAwesome, Pink) }, title = stringResource(R.string.welcome_tour), onClick = onWelcome, chevron = false)
                    Divider()
                    Item(
                        icon = { SettingsIcon(Icons.Rounded.DeleteOutline, Red) },
                        title = stringResource(R.string.clear_conversation),
                        titleColor = MaterialTheme.colorScheme.error,
                        onClick = onClear,
                        chevron = false,
                    )
                }

                Text(
                    "Lively ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 24.dp),
                )
                Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
            }
        }
    }

    if (choosingPickupRange) {
        ChoiceDialog(
            title = stringResource(R.string.pickup_range),
            options = PickupRange.entries.map { it to stringResource(it.labelRes) },
            selected = settings.pickupRange,
            onSelect = { settings.pickupRange = it; choosingPickupRange = false },
            onDismiss = { choosingPickupRange = false },
        )
    }

    if (choosingConversation) {
        ChoiceDialog(
            title = stringResource(R.string.conversation),
            options = ConversationMode.entries.map { it to stringResource(it.labelRes) },
            selected = settings.conversationMode,
            onSelect = { settings.conversationMode = it; choosingConversation = false },
            onDismiss = { choosingConversation = false },
        )
    }

    if (choosingEngine) {
        ChoiceDialog(
            title = stringResource(R.string.engine),
            options = settings.providers.map { it.id to it.name },
            selected = settings.providerID,
            onSelect = { settings.providerID = it; choosingEngine = false },
            onDismiss = { choosingEngine = false },
        )
    }
}

@Composable
private fun languagesFooter(settings: AppSettings) = when {
    settings.usesAutomaticLanguageDetection ->
        stringResource(R.string.settings_automatic_languages_footer)
    settings.providerID == SpeechProviders.SONIOX_ID -> stringResource(R.string.settings_pair_languages_footer)
    else -> stringResource(R.string.settings_pair_only_footer)
}

@Composable
private fun speechFooter(settings: AppSettings, canSpeak: Boolean): String {
    if (!canSpeak) return stringResource(R.string.speech_playback_requires_key)
    // Android speaks only the outgoing direction: away from the listener's language in Automatic.
    val spoken = if (settings.usesAutomaticLanguageDetection) stringResource(R.string.playback_detected_language) else stringResource(R.string.playback_named_language, settings.languages.second.displayName)
    return spoken + " " +
        stringResource(R.string.speech_playback_listening_footer) +
        stringResource(R.string.face_to_face_playback_menu_hint)
}

@Composable
private fun engineFooter(settings: AppSettings): String {
    val provider = settings.provider
    val lines = mutableListOf(stringResource(provider.summaryRes))
    lines += provider.credentials.map { stringResource(it.helpRes) }
    lines += stringResource(R.string.credential_storage_footer)
    if (ProviderOption.SPEED in provider.options) {
        lines += stringResource(R.string.speed_footer)
    }
    return lines.joinToString(" ")
}

/**
 * Turns "Set from location" on and off. Turning it on asks for approximate
 * location access first; see [LocationLanguages].
 */
@Composable
fun rememberLocationSwitch(location: LocationLanguages): (Boolean) -> Unit {
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> location.enable(granted) }
    return { on -> if (on) ask.launch(Manifest.permission.ACCESS_COARSE_LOCATION) else location.disable() }
}

@Composable
fun ScriptPicker(settings: AppSettings, modifier: Modifier = Modifier) {
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth()) {
        ChineseScript.entries.forEachIndexed { index, script ->
            SegmentedButton(
                selected = settings.chineseScript == script,
                onClick = { settings.chineseScript = script },
                shape = SegmentedButtonDefaults.itemShape(index, ChineseScript.entries.size),
                label = { Text(stringResource(script.labelRes), textAlign = TextAlign.Center) },
            )
        }
    }
}

/** A rounded group of rows, like a section of the system Settings app. */
@Composable
fun Group(header: String? = null, footer: String? = null, content: @Composable () -> Unit) {
    if (header != null) {
        Text(
            header,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 8.dp),
        )
    } else {
        Spacer(Modifier.height(16.dp))
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerLow),
    ) { content() }
    if (footer != null) {
        Text(
            footer,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
        )
    }
}

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(start = 68.dp), color = MaterialTheme.colorScheme.outlineVariant)

@Composable
fun Item(
    icon: @Composable () -> Unit,
    title: String,
    onClick: () -> Unit,
    value: String? = null,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    chevron: Boolean = true,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick, role = Role.Button)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        icon()
        Text(title, style = MaterialTheme.typography.bodyLarge, color = titleColor, modifier = Modifier.weight(1f))
        if (value != null) {
            Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f, fill = false), textAlign = TextAlign.End)
        }
        if (chevron) Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun LanguageItem(title: String, language: Language, settings: AppSettings, onClick: () -> Unit) {
    Item(
        icon = { LanguageIcon(language, language.ink(settings.languages)) },
        title = title,
        value = language.nativeName,
        onClick = onClick,
    )
}

/** A settings icon showing the language's short tag in its ink. */
@Composable
fun LanguageIcon(language: Language, ink: Color) {
    Box(
        Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(ink),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            language.tag,
            color = Color.White,
            fontWeight = FontWeight.Bold,
            fontSize = if (language.tag.length > 2 || language == Language.CHINESE) 11.sp else 13.sp,
        )
    }
}

@Composable
private fun KeyField(label: String, value: String, onValueChange: (String) -> Unit, onDone: () -> Unit) {
    var visible by remember { mutableStateOf(false) }
    Row(
        Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SettingsIcon(Icons.Rounded.Key, Gray)
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            singleLine = true,
            visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onDone() }),
            trailingIcon = {
                IconButton(onClick = { visible = !visible }) {
                    Icon(if (visible) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, if (visible) stringResource(R.string.hide_key) else stringResource(R.string.show_key))
                }
            },
            modifier = Modifier.weight(1f),
        )
    }
}

/** The signed-in person at the top of Settings, or an invitation to sign in. */
@Composable
private fun AccountRow(email: String?, onClick: () -> Unit) {
    val colors = Lively.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick, role = Role.Button)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(
            Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(Brush.linearGradient(listOf(colors.firstInk, colors.secondInk))),
            contentAlignment = Alignment.Center,
        ) {
            val initial = email?.takeUnless(Account::hidesEmail)?.firstOrNull()
            if (initial != null) {
                Text(initial.uppercase(), color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
            } else {
                Icon(Icons.Rounded.Person, null, tint = Color.White, modifier = Modifier.size(28.dp))
            }
        }
        Column(Modifier.weight(1f)) {
            Text(
                email?.let(Account::displayName) ?: stringResource(R.string.sign_in_to_lively),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            Text(
                if (email == null) stringResource(R.string.two_free_hours_a_day_instead_of_one) else stringResource(R.string.account),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A list of radio choices in a dialog, the Android picker for a few options. */
@Composable
fun <T> ChoiceDialog(title: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.selectableGroup()) {
                for ((value, label) in options) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .selectable(selected = value == selected, onClick = { onSelect(value) }, role = Role.RadioButton)
                            .padding(vertical = 12.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        RadioButton(selected = value == selected, onClick = null)
                        Text(label, style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
