package sh.ian.lively.ui

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Map
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SearchOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.core.text.layoutDirection
import kotlinx.coroutines.launch
import sh.ian.lively.LivelyApp
import sh.ian.lively.model.AddressLanguage
import sh.ian.lively.model.AddressLookupStore
import sh.ian.lively.model.AddressPlace
import sh.ian.lively.model.Language
import sh.ian.lively.net.MapAddressLookupService

/**
 * A written address lookup, independent of conversation and speech settings.
 *
 * A pushed screen where iOS has a sheet. It has no map of the matches: an
 * embedded map on Android is the Google Maps SDK, which needs an API key.
 * "Open in Maps" hands the chosen place to whichever maps app is installed.
 */
@Composable
fun AddressLookupScreen(initialLanguage: Language, onBack: () -> Unit) {
    val context = LocalContext.current
    val graph = (context.applicationContext as LivelyApp).graph
    val scope = rememberCoroutineScope()
    val store = remember {
        AddressLookupStore(
            service = MapAddressLookupService(context) { graph.network.isOnline },
            language = AddressLanguage.matching(graph.prefs.string(LANGUAGE_KEY) ?: initialLanguage.locale.toLanguageTag()),
            scope = scope,
        )
    }
    AddressLookupContent(
        store,
        onLanguage = {
            store.language = it
            graph.prefs.putString(LANGUAGE_KEY, it.code)
        },
        onBack = onBack,
    )
}

/** The screen over a store, so UI tests can give it one with a scripted service. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AddressLookupContent(store: AddressLookupStore, onLanguage: (AddressLanguage) -> Unit, onBack: () -> Unit) {
    var showsLanguages by rememberSaveable { mutableStateOf(false) }
    DisposableEffect(store) { onDispose { store.close() } }
    if (showsLanguages) {
        AddressLanguagePicker(
            selection = store.language,
            onSelect = {
                onLanguage(it)
                showsLanguages = false
            },
            onDone = { showsLanguages = false },
        )
        return
    }

    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val focus = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    var mapError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(store.copyValue) {
        copied = false
        mapError = null
    }
    fun find() {
        focus.clearFocus()
        store.find()
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("Address") },
                navigationIcon = { BackButton(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
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
                Group(header = "Location", footer = "Requires internet. Places are looked up with your phone’s location service.") {
                    TextField(
                        value = store.query,
                        onValueChange = { store.query = it },
                        placeholder = { Text("Address or place name") },
                        minLines = 2,
                        maxLines = 5,
                        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { find() }),
                        colors = TextFieldDefaults.colors(
                            focusedIndicatorColor = Color.Transparent,
                            unfocusedIndicatorColor = Color.Transparent,
                            focusedContainerColor = Color.Transparent,
                            unfocusedContainerColor = Color.Transparent,
                        ),
                        modifier = Modifier.fillMaxWidth().testTag("address-query"),
                    )
                    RowDivider()
                    ActionRow(Icons.Rounded.ContentPaste, "Paste") {
                        scope.launch {
                            val clip = clipboard.getClipEntry()?.clipData?.takeIf { it.itemCount > 0 } ?: return@launch
                            store.query = clip.getItemAt(0).coerceToText(context).toString()
                            focus.clearFocus()
                        }
                    }
                    RowDivider()
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable(role = Role.Button) { showsLanguages = true }
                            .testTag("address-language")
                            .heightIn(min = 56.dp)
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text("Address language", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        Text(
                            store.language.nativeName,
                            style = MaterialTheme.typography.bodyMedium.copy(localeList = store.language.localeList()),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                PillButton(
                    "Find address",
                    onClick = ::find,
                    enabled = store.canSearch,
                    modifier = Modifier.padding(top = 20.dp).testTag("address-find"),
                )

                if (store.isBusy) {
                    Group {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            CircularProgressIndicator(strokeWidth = 2.5.dp, modifier = Modifier.size(22.dp))
                            Text(
                                if (store.phase == AddressLookupStore.Phase.SEARCHING) "Finding places…" else "Finding address…",
                                style = MaterialTheme.typography.bodyLarge,
                            )
                        }
                        RowDivider()
                        ActionRow(Icons.Rounded.Close, "Cancel lookup") { store.close() }
                    }
                }

                store.errorMessage?.let { message ->
                    Group {
                        Text(
                            message,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.padding(16.dp).testTag("address-error"),
                        )
                        RowDivider()
                        ActionRow(Icons.Rounded.Refresh, "Try again") {
                            focus.clearFocus()
                            store.retry()
                        }
                    }
                }

                if (store.phase == AddressLookupStore.Phase.CHOOSING) {
                    Group(header = if (store.matches.size == 1) "Confirm the place" else "Choose a place") {
                        store.matches.forEachIndexed { index, place ->
                            if (index > 0) RowDivider()
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .clickable(role = Role.Button) {
                                        focus.clearFocus()
                                        store.select(place)
                                    }
                                    .testTag("address-result")
                                    .heightIn(min = 56.dp)
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                PlaceLabel(place, Modifier.weight(1f))
                                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }

                val place = store.selectedPlace
                val address = store.copyValue
                if (place != null && address != null) {
                    Group(
                        header = "Address in ${store.language.englishName}",
                        footer = "Names and address details depend on available map data. Some places may keep their local spelling.",
                    ) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            PlaceLabel(place)
                            val rightToLeft = store.language.locale.layoutDirection == View.LAYOUT_DIRECTION_RTL
                            CompositionLocalProvider(LocalLayoutDirection provides if (rightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                                SelectionContainer {
                                    // Large enough to hold up to a driver.
                                    Text(
                                        address,
                                        style = MaterialTheme.typography.headlineSmall.copy(localeList = store.language.localeList(), lineHeight = 34.sp),
                                        fontWeight = FontWeight.Medium,
                                        modifier = Modifier.fillMaxWidth().testTag("address-text"),
                                    )
                                }
                            }
                        }
                        RowDivider()
                        ActionRow(if (copied) Icons.Rounded.Check else Icons.Rounded.ContentCopy, if (copied) "Copied" else "Copy address") {
                            scope.launch {
                                clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Lively", address)))
                                copied = true
                            }
                        }
                        RowDivider()
                        ActionRow(Icons.Rounded.Map, "Open in Maps") {
                            // The coordinates of the chosen place, labelled with its name, in any maps app.
                            val uri = "geo:0,0?q=${place.latitude},${place.longitude}(${Uri.encode(place.name)})".toUri()
                            try {
                                context.startActivity(Intent(Intent.ACTION_VIEW, uri))
                            } catch (_: ActivityNotFoundException) {
                                mapError = "Couldn’t open Maps. Try again."
                            }
                        }
                        mapError?.let {
                            Text(
                                it,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            )
                        }
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun PlaceLabel(place: AddressPlace, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(place.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
        // The Geocoder has no name for most addresses, and the address then stands in for it.
        if (place.subtitle.isNotEmpty() && place.subtitle != place.name) {
            Text(place.subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A row that does something, like a button in an iOS form. */
@Composable
private fun ActionRow(icon: ImageVector, title: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick, role = Role.Button)
            .heightIn(min = 56.dp)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
        Text(title, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun RowDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)

private fun AddressLanguage.localeList() = LocaleList(locale.toLanguageTag())

/** Every language an address can be shown in, searchable by English or native name. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddressLanguagePicker(selection: AddressLanguage, onSelect: (AddressLanguage) -> Unit, onDone: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val trimmed = query.trim()
    val languages = if (trimmed.isEmpty()) AddressLanguage.all else AddressLanguage.all.filter {
        it.englishName.contains(trimmed, ignoreCase = true) ||
            it.nativeName.contains(trimmed, ignoreCase = true) ||
            it.code.contains(trimmed, ignoreCase = true)
    }
    BackHandler(onBack = onDone)
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            Column {
                TopAppBar(
                    title = { Text("Address language") },
                    navigationIcon = { BackButton(onDone) },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                )
                TextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text("Search languages") },
                    leadingIcon = { Icon(Icons.Rounded.Search, null) },
                    trailingIcon = {
                        if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Rounded.Close, "Clear search") }
                    },
                    singleLine = true,
                    shape = CircleShape,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
                    colors = TextFieldDefaults.colors(
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp)
                        .testTag("address-language-search"),
                )
            }
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
        ) {
            items(languages, key = { it.code }) { language ->
                val isSelected = language == selection
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(MaterialTheme.shapes.large)
                        .semantics { selected = isSelected }
                        .clickable(role = Role.Button) { onSelect(language) }
                        // "address-language-ja", for the UI tests.
                        .testTag("address-language-${language.code}")
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(language.nativeName, style = MaterialTheme.typography.bodyLarge.copy(localeList = language.localeList()))
                        if (!language.englishName.equals(language.nativeName, ignoreCase = true)) {
                            Text(language.englishName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    if (isSelected) Icon(Icons.Rounded.Check, "Selected", tint = MaterialTheme.colorScheme.primary)
                }
            }
            if (languages.isEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().padding(top = 64.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Rounded.SearchOff, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(40.dp))
                        Text("No results for “$trimmed”", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                    }
                }
            }
        }
    }
}

/** The same key as `UserDefaults` on iOS. */
private const val LANGUAGE_KEY = "addressLookupLanguage"
