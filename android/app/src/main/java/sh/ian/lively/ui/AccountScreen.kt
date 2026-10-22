package sh.ian.lively.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AlternateEmail
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Email
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import sh.ian.lively.model.Account
import kotlin.math.roundToInt
import kotlin.math.sin

/** Sign in with an emailed code, or see who's signed in. Pushed from Settings. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(account: Account, onBack: () -> Unit) {
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("Account") },
                navigationIcon = { BackButton(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(top = 24.dp, bottom = 32.dp),
        ) {
            AccountContent(account)
            Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
        }
    }
}

/** The account screen's body: a header, then either the sign-in steps or who's signed in. */
@Composable
fun AccountContent(account: Account, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier
                .widthIn(max = 460.dp)
                .fillMaxWidth()
                .padding(horizontal = 24.dp),
            verticalArrangement = Arrangement.spacedBy(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Header(account)
            val email = account.email
            AnimatedContent(targetState = email, label = "account", transitionSpec = { fadeIn() togetherWith fadeOut() }) { signedIn ->
                if (signedIn != null) {
                    SignedInCard(account, signedIn)
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(32.dp)) {
                        SignInForm(account)
                        Column(verticalArrangement = Arrangement.spacedBy(18.dp), modifier = Modifier.padding(horizontal = 4.dp)) {
                            Benefit(Icons.Rounded.Timer, Color(0xFFFF9500), "More translation time", "A bigger daily allowance than without an account.")
                            Benefit(Icons.Rounded.Devices, Color(0xFF007AFF), "On all your devices", "Sign in on each one; your allowance comes along.")
                            Benefit(Icons.Rounded.Email, Color(0xFF34C759), "No password to remember", "We email you a 6-digit code each time.")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Header(account: Account) {
    val colors = Lively.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(
            Modifier
                .size(80.dp)
                .shadow(14.dp, CircleShape, spotColor = colors.firstInk)
                .clip(CircleShape)
                .background(Brush.linearGradient(listOf(colors.firstInk, Color(0xFF8C4A99), colors.secondInk))),
            contentAlignment = Alignment.Center,
        ) {
            val initial = account.email?.firstOrNull()
            if (initial != null) {
                Text(initial.uppercase(), color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.SemiBold)
            } else {
                Icon(Icons.Rounded.Person, null, tint = Color.White, modifier = Modifier.size(38.dp))
            }
        }
        Text(
            if (account.isSignedIn) "You're signed in" else "Sign in to Lively",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Text(
            if (account.isSignedIn) {
                "Your translation time follows you to every device you sign in on."
            } else {
                "Optional, and it takes a few seconds. Signing in gives you more translation time every day."
            },
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
fun Benefit(icon: ImageVector, color: Color, title: String, detail: String) {
    Row(
        Modifier.semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        SettingsIcon(icon, color)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SignedInCard(account: Account, email: String) {
    var confirmingSignOut by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var deleteError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Column(verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(CardShape)
                .background(MaterialTheme.colorScheme.surfaceContainerLow),
        ) {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                SettingsIcon(Icons.Rounded.Email, Color(0xFF007AFF))
                Column(Modifier.weight(1f)) {
                    Text("Email", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(email, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                }
                Icon(Icons.Rounded.Verified, "Verified", tint = Lively.colors.live)
            }
            if (account.hasFreePro) {
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                Row(
                    Modifier.padding(16.dp).semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    SettingsIcon(Icons.Rounded.Star, Color(0xFFFF9500))
                    Column {
                        Text("Lively Pro", style = MaterialTheme.typography.bodyLarge)
                        Text("Included free with your account", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            TextButton(
                onClick = { confirmingSignOut = true },
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
                shape = RoundedCornerShape(0.dp),
            ) {
                Text("Sign out", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.titleMedium)
            }
        }

        TextButton(onClick = { confirmingDelete = true }, enabled = !deleting, modifier = Modifier.heightIn(min = 48.dp)) {
            if (deleting) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text("Delete account", color = MaterialTheme.colorScheme.error)
            }
        }
        deleteError?.let { ErrorLine(it) }
    }

    if (confirmingSignOut) {
        AlertDialog(
            onDismissRequest = { confirmingSignOut = false },
            title = { Text("Sign out of Lively?") },
            text = { Text("You'll go back to this device's daily translation time.") },
            confirmButton = {
                TextButton(onClick = { confirmingSignOut = false; account.signOut() }) {
                    Text("Sign out", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmingSignOut = false }) { Text("Cancel") } },
        )
    }
    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("Delete your Lively account?") },
            text = {
                Text(
                    if (account.hasFreePro) {
                        "This erases your email and account from Lively's servers, including the free Lively Pro that came with it. It can't be undone."
                    } else {
                        "This erases your email and account from Lively's servers and can't be undone. It doesn't cancel a Lively Pro subscription."
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingDelete = false
                    deleting = true
                    deleteError = null
                    scope.launch {
                        try {
                            account.deleteAccount()
                        } catch (e: Account.AccountException) {
                            deleteError = e.message
                        } finally {
                            deleting = false
                        }
                    }
                }) { Text("Delete account", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ErrorLine(message: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Rounded.ErrorOutline, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(18.dp))
        Text(message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
    }
}

/**
 * Two steps, one action each: type an email and continue, then type the
 * code, which signs in by itself once all six digits are there.
 */
@Composable
private fun SignInForm(account: Account) {
    var email by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    /** The address a code was sent to, while waiting for it. */
    var codeSentTo by rememberSaveable { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var resendAvailableAt by rememberSaveable { mutableLongStateOf(0L) }
    val shake = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()

    val trimmed = email.trim()
    val plausible = trimmed.split("@").let { it.size == 2 && it[0].isNotEmpty() && it[1].contains(".") && !it[1].endsWith(".") }

    fun run(action: suspend () -> Unit) {
        working = true
        errorMessage = null
        scope.launch {
            try {
                action()
            } catch (e: Account.AccountException) {
                errorMessage = e.message
            } finally {
                working = false
            }
        }
    }

    fun send(address: String) = run {
        account.sendCode(address)
        codeSentTo = address
        code = ""
        resendAvailableAt = System.currentTimeMillis() + RESEND_DELAY_MS
    }

    fun signIn() {
        val sentTo = codeSentTo ?: return
        if (working) return
        val entered = code
        run {
            try {
                account.signIn(sentTo, entered)
            } catch (e: Account.AccountException) {
                code = ""
                scope.launch {
                    shake.snapTo(0f)
                    shake.animateTo(1f, tween(400))
                }
                throw e
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        AnimatedContent(
            targetState = codeSentTo,
            label = "step",
            transitionSpec = {
                val forward = targetState != null
                (slideInHorizontally { if (forward) it else -it } + fadeIn()) togetherWith
                    (slideOutHorizontally { if (forward) -it else it } + fadeOut())
            },
        ) { sentTo ->
            if (sentTo == null) {
                EmailStep(email, { email = it; errorMessage = null }, plausible, working, onSubmit = { if (plausible && !working) send(trimmed) })
            } else {
                CodeStep(
                    sentTo = sentTo,
                    code = code,
                    onCodeChange = { new ->
                        val digits = new.filter(Char::isDigit).take(6)
                        code = digits
                        if (digits.isNotEmpty()) errorMessage = null
                        // Signs in once all six digits are there, typed, pasted or autofilled.
                        if (digits.length == 6) signIn()
                    },
                    isError = errorMessage != null,
                    working = working,
                    shake = shake.value,
                    resendAvailableAt = resendAvailableAt,
                    onChangeEmail = {
                        codeSentTo = null
                        code = ""
                        errorMessage = null
                    },
                    onResend = { send(sentTo) },
                )
            }
        }
        AnimatedVisibility(errorMessage != null) { errorMessage?.let { ErrorLine(it) } }
    }
}

@Composable
private fun EmailStep(email: String, onEmailChange: (String) -> Unit, plausible: Boolean, working: Boolean, onSubmit: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val border by animateColorAsState(
        if (focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
        label = "border",
    )
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(58.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerLow)
                .border(if (focused) 1.5.dp else 1.dp, border, RoundedCornerShape(18.dp))
                .padding(horizontal = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                Icons.Rounded.AlternateEmail,
                null,
                tint = if (focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            BasicTextField(
                value = email,
                onValueChange = onEmailChange,
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onGo = { onSubmit() }),
                modifier = Modifier
                    .weight(1f)
                    .onFocusChanged { focused = it.isFocused }
                    .semantics {
                        contentType = ContentType.EmailAddress
                        contentDescription = "Email"
                    },
                decorationBox = { inner ->
                    Box {
                        if (email.isEmpty()) {
                            Text("you@example.com", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
                        }
                        inner()
                    }
                },
            )
        }
        PillButton("Email me a code", onClick = onSubmit, enabled = plausible, working = working)
    }
}

@Composable
private fun CodeStep(
    sentTo: String,
    code: String,
    onCodeChange: (String) -> Unit,
    isError: Boolean,
    working: Boolean,
    shake: Float,
    resendAvailableAt: Long,
    onChangeEmail: () -> Unit,
    onResend: () -> Unit,
) {
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var focused by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(resendAvailableAt) {
        while (now < resendAvailableAt) {
            delay(250)
            now = System.currentTimeMillis()
        }
    }
    LaunchedEffect(Unit) {
        // Wait for the email field to leave, or it takes the focus with it.
        delay(400)
        focus.requestFocus()
        keyboard?.show()
    }
    val wait = ((resendAvailableAt - now + 999) / 1000).coerceAtLeast(0)

    Column(verticalArrangement = Arrangement.spacedBy(18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Enter the code we emailed to", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(sentTo, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        }

        // Six boxes over one text field, so paste and autofill both work.
        Box(
            Modifier
                .offset { IntOffset((8.dp.toPx() * sin(shake * Math.PI * 4)).roundToInt(), 0) }
                .clickable(remember { MutableInteractionSource() }, indication = null) {
                    focus.requestFocus()
                    keyboard?.show()
                },
            contentAlignment = Alignment.Center,
        ) {
            BasicTextField(
                value = code,
                onValueChange = onCodeChange,
                enabled = !working,
                singleLine = true,
                textStyle = TextStyle(color = Color.Transparent),
                cursorBrush = SolidColor(Color.Transparent),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                modifier = Modifier
                    .matchParentSize()
                    .alpha(0.02f)
                    .focusRequester(focus)
                    .onFocusChanged { focused = it.isFocused }
                    .semantics {
                        contentType = ContentType.SmsOtpCode
                        contentDescription = "6-digit code"
                    },
            )
            Row(
                Modifier.widthIn(max = 340.dp).fillMaxWidth().alpha(if (working) 0.5f else 1f),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                for (index in 0 until 6) {
                    CodeBox(Modifier.weight(1f), code.getOrNull(index), active = focused && index == minOf(code.length, 5) && !working, isError = isError)
                    if (index == 2) Box(Modifier.size(width = 8.dp, height = 2.dp).background(MaterialTheme.colorScheme.outline, CircleShape))
                }
            }
            if (working) CircularProgressIndicator(Modifier.size(28.dp))
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onChangeEmail, enabled = !working, modifier = Modifier.weight(1f)) { Text("Change email") }
            VerticalDivider(Modifier.height(18.dp))
            TextButton(onClick = onResend, enabled = !working && wait == 0L, modifier = Modifier.weight(1f)) {
                Text(if (wait > 0) "Resend in ${wait}s" else "Resend code")
            }
        }
    }
}

@Composable
private fun CodeBox(modifier: Modifier, digit: Char?, active: Boolean, isError: Boolean) {
    val color = when {
        isError -> MaterialTheme.colorScheme.error
        active -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.outlineVariant
    }
    val blink = rememberInfiniteTransition(label = "caret")
    val caret by blink.animateFloat(1f, 0f, infiniteRepeatable(tween(500), RepeatMode.Reverse), label = "caret alpha")
    Box(
        modifier
            .height(58.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .border(if (isError || active) 1.5.dp else 1.dp, color, RoundedCornerShape(14.dp)),
        contentAlignment = Alignment.Center,
    ) {
        if (digit != null) {
            Text(digit.toString(), fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
        } else if (active) {
            Box(Modifier.size(width = 2.dp, height = 26.dp).alpha(caret).background(MaterialTheme.colorScheme.primary, CircleShape))
        }
    }
}

private const val RESEND_DELAY_MS = 30_000L
