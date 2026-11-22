package sh.ian.lively.ui

import sh.ian.lively.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SearchOff
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguageSide
import sh.ian.lively.model.get

/**
 * Every language the engine supports, searchable by English or native
 * name. Picking the other side's language swaps the pair.
 */
@Composable
fun LanguageListScreen(
    settings: AppSettings,
    side: LanguageSide,
    onDone: () -> Unit,
    title: String = if (side == LanguageSide.FIRST) stringResource(R.string.first_language) else stringResource(R.string.second_language),
    closeIcon: Boolean = false,
) {
    val current = settings.languages[side]
    val other = settings.languages.other(current)
    val all = remember(settings.providerID) { settings.provider.languages.sortedWith(compareBy(java.text.Collator.getInstance()) { it.displayName }) }
    fun pick(language: Language) {
        settings.setLanguage(language, side)
        onDone()
    }
    LanguageSearchList(title, all, onDone, closeIcon, pinned = {
        item { SectionHeader(stringResource(R.string.this_conversation)) }
        items(settings.languages.all, key = { "pair-${it.code}" }) { LanguageRow(it, current, other, settings) { pick(it) } }
        item { SectionHeader(stringResource(R.string.all_languages)) }
    }) { LanguageRow(it, current, other, settings) { pick(it) } }
}

/** The reader's saved language is independent of any conversation partner. */
@Composable
fun OwnLanguageListScreen(settings: AppSettings, onDone: () -> Unit, closeIcon: Boolean = false) {
    val all = remember { Language.SONIOX.sortedWith(compareBy(java.text.Collator.getInstance()) { it.displayName }) }
    val current = settings.speechListenerLanguage
    LanguageSearchList(stringResource(R.string.your_language), all, onDone, closeIcon) {
        LanguageRow(it, current, other = null, settings) {
            settings.speechListenerLanguage = it
            onDone()
        }
    }
}

/**
 * A titled list of [languages] under a search field that matches English
 * names, native names and codes. [pinned] rows lead the list until a search starts.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LanguageSearchList(
    title: String,
    languages: List<Language>,
    onDone: () -> Unit,
    closeIcon: Boolean,
    pinned: LazyListScope.() -> Unit = {},
    row: @Composable (Language) -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    val trimmed = query.trim()
    val matches = if (trimmed.isEmpty()) languages else languages.filter {
        it.displayName.contains(trimmed, ignoreCase = true) || it.englishName.contains(trimmed, ignoreCase = true) ||
            it.nativeName.contains(trimmed, ignoreCase = true) ||
            it.code == trimmed.lowercase()
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            Column(Modifier.background(MaterialTheme.colorScheme.background)) {
                TopAppBar(
                    title = { Text(title) },
                    navigationIcon = {
                        if (closeIcon) {
                            IconButton(onClick = onDone) { Icon(Icons.Rounded.Close, stringResource(R.string.close)) }
                        } else {
                            BackButton(onDone)
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                )
                TextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text(stringResource(R.string.search_languages)) },
                    leadingIcon = { Icon(Icons.Rounded.Search, null) },
                    trailingIcon = {
                        if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Rounded.Close, stringResource(R.string.clear_search)) }
                    },
                    singleLine = true,
                    shape = CircleShape,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
                    colors = TextFieldDefaults.colors(
                        focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                        unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
        },
    ) { padding ->
        LazyColumn(
            Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
        ) {
            if (trimmed.isEmpty()) pinned()
            items(matches, key = { it.code }) { row(it) }
            if (matches.isEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().padding(top = 64.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Rounded.SearchOff, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(40.dp))
                        Text(stringResource(R.string.no_results_for_value, trimmed), style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                    }
                }
            }
            item { androidx.compose.foundation.layout.Spacer(Modifier.windowInsetsPadding(WindowInsets.navigationBars)) }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
    )
}

@Composable
private fun LanguageRow(language: Language, current: Language, other: Language?, settings: AppSettings, onClick: () -> Unit) {
    val isCurrent = language == current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.large)
            .semantics { selected = isCurrent }
            .clickable(onClick = onClick, role = Role.Button)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(language.nativeName, style = MaterialTheme.typography.bodyLarge.copy(localeList = language.localeList()))
            if (language.hasDistinctDisplayName) {
                Text(language.displayName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (isCurrent) {
            Icon(Icons.Rounded.Check, stringResource(R.string.selected), tint = MaterialTheme.colorScheme.primary)
        } else if (language == other) {
            val ink = language.ink(settings.languages)
            Text(
                stringResource(R.string.swap),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = ink,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(ink.copy(alpha = 0.12f))
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
    }
}
