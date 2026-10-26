package sh.ian.lively.ui

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
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Hearing
import androidx.compose.material.icons.rounded.Key
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
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguageSide
import sh.ian.lively.model.Latency
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
    hasBroker: Boolean,
    onBack: () -> Unit,
    onAccount: () -> Unit,
    onPro: () -> Unit,
    onLanguage: (LanguageSide) -> Unit,
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
    var choosingPickupRange by remember { mutableStateOf(false) }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            LargeTopAppBar(
                title = { Text("Settings") },
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
                    Group(footer = if (!pro.isPro) "Up to 10 hours of translation a day with the Soniox engine." else null) {
                        Item(
                            icon = { SettingsIcon(Icons.Rounded.Star, Orange) },
                            title = "Lively Pro",
                            value = when {
                                pro.isSubscribed -> "Active"
                                account?.hasFreePro == true -> "Included"
                                else -> "Upgrade"
                            },
                            onClick = onPro,
                        )
                    }
                }

                Group(
                    header = "Languages",
                    footer = "Lively listens for both languages and translates each into the other.",
                ) {
                    LanguageItem("First language", settings.languages.first, settings, onClick = { onLanguage(LanguageSide.FIRST) })
                    Divider()
                    LanguageItem("Second language", settings.languages.second, settings, onClick = { onLanguage(LanguageSide.SECOND) })
                    if (Language.CHINESE in settings.languages) {
                        Divider()
                        Row(
                            Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            SettingsIcon(Icons.Rounded.Translate, Teal)
                            Text("Chinese script", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        }
                        ScriptPicker(settings, Modifier.padding(start = 68.dp, end = 16.dp, bottom = 14.dp))
                    }
                }

                Group(header = "Microphone", footer = settings.pickupRange.summary) {
                    Item(
                        icon = { SettingsIcon(Icons.Rounded.Hearing, Green) },
                        title = "Pickup range",
                        value = settings.pickupRange.label,
                        onClick = { choosingPickupRange = true },
                    )
                }

                val canSpeak = hasBroker || settings.credential(SpeechProviders.sonioxCredential(false)).isNotBlank()
                Group(header = "Speech-to-speech", footer = speechFooter(settings, canSpeak)) {
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
                        Text("Speak translations aloud", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        Switch(checked = settings.speaksTranslations, onCheckedChange = null, enabled = canSpeak)
                    }
                }

                Group(header = "Speech engine", footer = engineFooter(settings)) {
                    Item(
                        icon = { SettingsIcon(Icons.Rounded.GraphicEq, Purple) },
                        title = "Engine",
                        value = provider.name,
                        onClick = { choosingEngine = true },
                    )
                    for (credential in provider.credentials) {
                        Divider()
                        KeyField(
                            label = credential.name,
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
                            Text("Speed", style = MaterialTheme.typography.bodyLarge)
                        }
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(start = 68.dp, end = 16.dp, bottom = 14.dp)) {
                            Latency.entries.forEachIndexed { index, latency ->
                                SegmentedButton(
                                    selected = settings.latency == latency,
                                    onClick = { settings.latency = latency },
                                    shape = SegmentedButtonDefaults.itemShape(index, Latency.entries.size),
                                    label = { Text("${latency.label}\n${latency.milliseconds} ms", textAlign = TextAlign.Center, fontSize = 13.sp, lineHeight = 15.sp) },
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
                                label = { Text("Model") },
                                placeholder = { Text(AppSettings.DEFAULT_TRANSLATION_MODEL) },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }

                Group {
                    Item(icon = { SettingsIcon(Icons.Rounded.AutoAwesome, Pink) }, title = "Welcome tour", onClick = onWelcome, chevron = false)
                    Divider()
                    Item(
                        icon = { SettingsIcon(Icons.Rounded.DeleteOutline, Red) },
                        title = "Clear conversation",
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
            title = "Pickup range",
            options = PickupRange.entries.map { it to it.label },
            selected = settings.pickupRange,
            onSelect = { settings.pickupRange = it; choosingPickupRange = false },
            onDismiss = { choosingPickupRange = false },
        )
    }

    if (choosingEngine) {
        ChoiceDialog(
            title = "Engine",
            options = settings.providers.map { it.id to it.name },
            selected = settings.providerID,
            onSelect = { settings.providerID = it; choosingEngine = false },
            onDismiss = { choosingEngine = false },
        )
    }
}

private fun speechFooter(settings: AppSettings, canSpeak: Boolean): String {
    if (!canSpeak) return "Speaking translations aloud needs a Soniox API key."
    return "Translations into ${settings.languages.second.englishName} are read aloud through the speaker as they arrive. " +
        "Lively doesn't listen while it speaks, so it won't translate itself, unless you're using headphones. " +
        "The speaker button on the conversation screen turns it on and off."
}

private fun engineFooter(settings: AppSettings): String {
    val provider = settings.provider
    val lines = mutableListOf(provider.summary)
    lines += provider.credentials.map { it.help }
    lines += "Keys are encrypted with the Android Keystore on this device."
    if (ProviderOption.SPEED in provider.options) {
        lines += "Faster speed shows words sooner; Accurate waits a little longer for better transcripts."
    }
    return lines.joinToString(" ")
}

@Composable
fun ScriptPicker(settings: AppSettings, modifier: Modifier = Modifier) {
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth()) {
        ChineseScript.entries.forEachIndexed { index, script ->
            SegmentedButton(
                selected = settings.chineseScript == script,
                onClick = { settings.chineseScript = script },
                shape = SegmentedButtonDefaults.itemShape(index, ChineseScript.entries.size),
                label = { Text(script.label, maxLines = 1) },
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
            Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
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
                    Icon(if (visible) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, if (visible) "Hide key" else "Show key")
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
            val initial = email?.firstOrNull()
            if (initial != null) {
                Text(initial.uppercase(), color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
            } else {
                Icon(Icons.Rounded.Person, null, tint = Color.White, modifier = Modifier.size(28.dp))
            }
        }
        Column(Modifier.weight(1f)) {
            Text(
                email ?: "Sign in to Lively",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            Text(
                if (email == null) "More translation time every day" else "Account",
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
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
