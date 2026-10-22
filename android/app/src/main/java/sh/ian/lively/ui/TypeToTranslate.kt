package sh.ian.lively.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.Utterance

/**
 * An optional text field for typing a line to translate, for when speaking
 * isn't practical. Opening it downloads on-device models, which typed text
 * uses when no translation key is set.
 */
@Composable
fun TypeToTranslateBar(
    store: ConversationStore,
    /** The typist's language, for text that could be either. */
    language: Language,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    /** A turn whose transcript is being corrected; sending replaces it. */
    editing: Utterance? = null,
    onEndEditing: () -> Unit = {},
) {
    var field by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    val focus = remember { FocusRequester() }
    val isEmpty = field.text.isBlank()
    val send = {
        if (!isEmpty) {
            if (editing != null) {
                store.edit(editing, field.text)
                onEndEditing()
            } else {
                store.submitTyped(field.text, language)
            }
            field = TextFieldValue()
        }
    }
    // Cancels an edit, or closes the bar.
    val close = {
        if (editing != null) {
            field = TextFieldValue()
            onEndEditing()
        } else {
            onClose()
        }
    }
    LaunchedEffect(Unit) {
        focus.requestFocus()
        store.prepareTypedTranslation()
    }
    LaunchedEffect(editing) {
        val source = editing?.trimmedSource ?: return@LaunchedEffect
        field = TextFieldValue(source, selection = TextRange(source.length))
        focus.requestFocus()
    }
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = modifier.fillMaxWidth(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (editing != null) {
                Icon(
                    Icons.Rounded.Edit,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 16.dp).size(20.dp),
                )
            }
            TextField(
                value = field,
                onValueChange = { field = it },
                placeholder = { Text(if (editing == null) "Type to translate" else "Fix what was heard") },
                singleLine = true,
                // Corrections are often names, which autocorrect would undo.
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send, autoCorrectEnabled = editing == null),
                keyboardActions = KeyboardActions(onSend = { send() }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.weight(1f).focusRequester(focus),
            )
            Surface(
                onClick = send,
                enabled = !isEmpty,
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier.size(36.dp).alpha(if (isEmpty) 0.4f else 1f),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        if (editing == null) Icons.AutoMirrored.Rounded.Send else Icons.Rounded.Check,
                        contentDescription = if (editing == null) "Translate" else "Save and translate again",
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            IconButton(onClick = close, modifier = Modifier.padding(end = 2.dp)) {
                Icon(
                    Icons.Rounded.Close,
                    contentDescription = if (editing == null) "Close text input" else "Cancel editing",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
