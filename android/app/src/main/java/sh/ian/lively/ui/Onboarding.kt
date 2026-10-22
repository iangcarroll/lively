package sh.ian.lively.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.graphics.luminance
import androidx.core.view.WindowCompat
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import android.view.HapticFeedbackConstants
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import sh.ian.lively.model.Account
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.DemoConversation
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguageSide
import kotlin.math.cos
import kotlin.math.sin

private enum class Step { WELCOME, TABLE, LANGUAGES, ACCOUNT }

/**
 * First launch: a short, mostly visual tour. It shows Lively working
 * instead of describing it, picks the two languages, and offers sign-in.
 */
@Composable
fun OnboardingScreen(settings: AppSettings, account: Account?, onFinish: () -> Unit) {
    // Sign-in is offered only when the build has an account service.
    val steps = if (account == null) listOf(Step.WELCOME, Step.TABLE, Step.LANGUAGES) else Step.entries
    val pager = rememberPagerState { steps.size }
    val scope = rememberCoroutineScope()
    val step = steps[pager.currentPage]
    // Read through derived state, so swiping recomposes only when these change.
    val welcome by remember { derivedStateOf { steps[pager.currentPage] == Step.WELCOME && pager.currentPageOffsetFraction > -0.5f } }
    val welcomeShown by remember {
        derivedStateOf {
            if (steps[pager.currentPage] == Step.WELCOME) 1f - (-pager.currentPageOffsetFraction * 2).coerceIn(0f, 1f) else 0f
        }
    }
    val canvas by animateColorAsState(
        if (welcome) Color(0xFF3F54DB) else MaterialTheme.colorScheme.background,
        tween(450),
        label = "background",
    )
    // White status bar icons over the welcome gradient, the theme's own elsewhere.
    val view = LocalView.current
    val darkTheme = MaterialTheme.colorScheme.background.luminance() < 0.5f
    LaunchedEffect(welcome, darkTheme) {
        val window = (view.context as? android.app.Activity)?.window ?: return@LaunchedEffect
        WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !welcome && !darkTheme
    }
    DisposableEffect(Unit) {
        onDispose {
            val window = (view.context as? android.app.Activity)?.window ?: return@onDispose
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
        }
    }
    BackHandler(enabled = pager.currentPage > 0) { scope.launch { pager.animateScrollToPage(pager.currentPage - 1) } }

    Box(Modifier.fillMaxSize().background(canvas)) {
        val gradientAlpha by animateFloatAsState(welcomeShown, label = "gradient")
        if (gradientAlpha > 0f) LivelyGradient(Modifier.fillMaxSize().alpha(gradientAlpha))

        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            HorizontalPager(pager, Modifier.weight(1f).fillMaxWidth(), beyondViewportPageCount = 1) { index ->
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Box(Modifier.widthIn(max = 520.dp).fillMaxSize()) {
                        when (steps[index]) {
                            Step.WELCOME -> WelcomePage(settings.providers.maxOf { it.languages.size })
                            Step.TABLE -> TablePage(active = pager.currentPage == index)
                            Step.LANGUAGES -> LanguagesPage(settings)
                            Step.ACCOUNT -> account?.let { AccountPage(it, onSignedIn = onFinish) }
                        }
                    }
                }
            }
            Column(
                Modifier
                    .widthIn(max = 480.dp)
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                PageDots(steps.size, pager.currentPage, light = welcome)
                if (step == Step.ACCOUNT) {
                    TextButton(onClick = onFinish, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) {
                        Text("Not now", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    val title = when {
                        step == Step.WELCOME -> "Get started"
                        step == Step.LANGUAGES && Step.ACCOUNT !in steps -> "Start talking"
                        else -> "Continue"
                    }
                    PillButton(
                        title,
                        onClick = {
                            if (pager.currentPage + 1 < steps.size) {
                                scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
                            } else {
                                onFinish()
                            }
                        },
                        container = if (welcome) Color.White else MaterialTheme.colorScheme.primary,
                        content = if (welcome) WelcomeInk else MaterialTheme.colorScheme.onPrimary,
                    )
                }
            }
        }
    }
}

/** The page layout every step shares: a picture, then a title and a line or two. */
@Composable
private fun OnboardingPage(title: String, message: String, light: Boolean = false, art: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // Tablets and unfolded foldables have room for a bigger picture.
        val grow = if (maxWidth >= 480.dp && maxHeight >= 760.dp) 1.25f else 1f
        // Landscape phones are too short for both; there the page scrolls.
        val short = maxHeight < 300.dp
        val compact = maxHeight < 520.dp
        val shortArtHeight = maxHeight * 0.8f
        Column(
            Modifier
                .fillMaxSize()
                .then(if (short) Modifier.verticalScroll(rememberScrollState()) else Modifier),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                (if (short) Modifier.height(shortArtHeight) else Modifier.weight(1f)).fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                FitInside(grow) { art() }
            }
            Column(
                Modifier.padding(horizontal = 32.dp).padding(top = 8.dp, bottom = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    title,
                    style = if (compact) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.displaySmall,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                    color = if (light) Color.White else MaterialTheme.colorScheme.onBackground,
                )
                Text(
                    message,
                    style = if (compact) MaterialTheme.typography.bodyMedium else MaterialTheme.typography.bodyLarge,
                    textAlign = TextAlign.Center,
                    color = if (light) Color.White.copy(alpha = 0.85f) else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * Lays [content] out at its natural height, then scales it down to fit the
 * space it's given (or up by [grow] where there's room), so the words below
 * it never get pushed off a small screen.
 */
@Composable
private fun FitInside(grow: Float, content: @Composable () -> Unit) {
    Layout(content) { measurables, constraints ->
        val placeable = measurables.single().measure(constraints.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity))
        val scale = minOf(grow, constraints.maxHeight.toFloat() / placeable.height.coerceAtLeast(1))
        layout(constraints.maxWidth, constraints.maxHeight) {
            placeable.placeWithLayer(
                (constraints.maxWidth - placeable.width) / 2,
                (constraints.maxHeight - placeable.height) / 2,
            ) {
                scaleX = scale
                scaleY = scale
            }
        }
    }
}

@Composable
private fun WelcomePage(languageCount: Int) = OnboardingPage(
    title = "Lively",
    message = "Talk with anyone, face to face. Lively translates both of you as you speak, in $languageCount languages.",
    light = true,
) { GreetingBubbles() }

@Composable
private fun TablePage(active: Boolean) = OnboardingPage(
    title = "Lay it flat between you",
    message = "Just talk. Lively hears who's speaking, and each of you reads your own half, in your own language.",
) { TableDemo(active) }

@Composable
private fun LanguagesPage(settings: AppSettings) {
    var choosing by remember { mutableStateOf<LanguageSide?>(null) }
    val view = LocalView.current
    OnboardingPage(
        title = "Pick your languages",
        message = "Lively listens for both and translates each into the other. You can change them any time.",
    ) {
        Column(Modifier.padding(horizontal = 24.dp).widthIn(max = 420.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(contentAlignment = Alignment.Center) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    LanguageCard("You speak", settings.languages.first, Lively.colors.firstInk) { choosing = LanguageSide.FIRST }
                    LanguageCard("They speak", settings.languages.second, Lively.colors.secondInk) { choosing = LanguageSide.SECOND }
                }
                Surface(
                    onClick = {
                        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                        settings.languages = settings.languages.swapped()
                    },
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surfaceContainerHighest,
                    shadowElevation = 4.dp,
                    modifier = Modifier.size(48.dp).semantics { contentDescription = "Swap languages" },
                ) {
                    Box(contentAlignment = Alignment.Center) { Icon(Icons.Rounded.SwapVert, null) }
                }
            }
            AnimatedVisibility(Language.CHINESE in settings.languages) {
                ScriptPicker(settings, Modifier.padding(top = 20.dp).widthIn(max = 320.dp))
            }
        }
    }
    choosing?.let { side ->
        Dialog(onDismissRequest = { choosing = null }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            LanguageListScreen(
                settings,
                side,
                onDone = { choosing = null },
                title = if (side == LanguageSide.FIRST) "You speak" else "They speak",
                closeIcon = true,
            )
        }
    }
}

/** One side of the pair: the language's own name, large, in its ink. */
@Composable
private fun LanguageCard(caption: String, language: Language, ink: Color, onClick: () -> Unit) {
    val shape = RoundedCornerShape(28.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 112.dp)
            .shadow(6.dp, shape, ambientColor = Color.Black.copy(alpha = 0.15f), spotColor = Color.Black.copy(alpha = 0.15f))
            .clip(shape)
            .background(Lively.colors.card)
            .background(ink.copy(alpha = 0.06f))
            .border(1.dp, ink.copy(alpha = 0.18f), shape)
            .clickable(onClickLabel = "Choose a language", onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = "$caption: ${language.englishName}" }
            .padding(horizontal = 22.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(caption, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            AnimatedContent(language, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "language") { shown ->
                Column {
                    Text(
                        shown.nativeName,
                        style = MaterialTheme.typography.headlineMedium.copy(localeList = shown.localeList()),
                        fontWeight = FontWeight.Bold,
                        color = ink,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (shown.englishName != shown.nativeName) {
                        Text(shown.englishName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        Icon(Icons.Rounded.UnfoldMore, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
    }
}

@Composable
private fun AccountPage(account: Account, onSignedIn: () -> Unit) {
    LaunchedEffect(account.isSignedIn) { if (account.isSignedIn) onSignedIn() }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(top = 40.dp, bottom = 16.dp),
    ) {
        AccountContent(account)
    }
}

@Composable
private fun PageDots(count: Int, current: Int, light: Boolean) {
    val color = if (light) Color.White else MaterialTheme.colorScheme.onBackground
    Row(
        Modifier.semantics(mergeDescendants = true) { contentDescription = "Page ${current + 1} of $count" },
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        repeat(count) { index ->
            val width by animateDpAsState(if (index == current) 22.dp else 7.dp, spring(stiffness = 600f), label = "dot")
            Box(
                Modifier
                    .size(width = width, height = 7.dp)
                    .alpha(if (index == current) 0.9f else 0.22f)
                    .background(color, CircleShape),
            )
        }
    }
}

/** The app icon's blue-to-red wash, drifting slowly. */
@Composable
fun LivelyGradient(modifier: Modifier = Modifier) {
    val time = rememberInfiniteTransition(label = "drift")
    val t by time.animateFloat(0f, (2 * Math.PI * 20).toFloat(), infiniteRepeatable(tween(360_000, easing = LinearEasing)), label = "t")
    Canvas(modifier) {
        drawRect(Brush.linearGradient(listOf(Color(0xFF4054DB), Color(0xFF784AA8), Color(0xFFDB4D33)), Offset.Zero, Offset(size.width, size.height)))
        val drift = Offset(sin(t * 0.35f) * 0.18f * size.width, cos(t * 0.27f) * 0.14f * size.height)
        val center = Offset(size.width / 2, size.height / 2) + drift
        drawCircle(Brush.radialGradient(listOf(Color(0xFF784AA8).copy(alpha = 0.9f), Color.Transparent), center, size.maxDimension * 0.55f), size.maxDimension, center)
        drawCircle(Brush.radialGradient(listOf(Color(0xFF4F4DCC).copy(alpha = 0.8f), Color.Transparent), Offset(0f, 0f), size.maxDimension * 0.6f), size.maxDimension)
        drawCircle(Brush.radialGradient(listOf(Color(0xFFDB4D33).copy(alpha = 0.85f), Color.Transparent), Offset(size.width, size.height), size.maxDimension * 0.55f), size.maxDimension)
    }
}

/**
 * The app icon, alive: two speech bubbles saying hello to each other in a
 * new pair of languages every couple of seconds.
 */
@Composable
private fun GreetingBubbles() {
    val greetings = remember {
        listOf(
            "Hello" to "你好", "Hola" to "Bonjour", "Ciao" to "こんにちは", "Olá" to "안녕하세요",
            "Hallo" to "Привет", "Merhaba" to "नमस्ते", "Hej" to "مرحبا", "Xin chào" to "Γεια σου",
        )
    }
    var index by remember { mutableIntStateOf(0) }
    // The answer lags the greeting a moment, like a translation catching up.
    var answerIndex by remember { mutableIntStateOf(0) }
    val appear = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        launch { delay(150); appear.animateTo(1f, spring(dampingRatio = 0.55f, stiffness = 120f)) }
        while (true) {
            delay(2200)
            index = (index + 1) % greetings.size
            delay(350)
            answerIndex = index
        }
    }
    Box(Modifier.size(300.dp, 230.dp), contentAlignment = Alignment.Center) {
        GreetingBubble(
            greetings[index].first, WelcomeInk, tailLeading = true,
            Modifier
                .offset((-44).dp, (-46).dp)
                .graphicsLayer { scaleX = 0.6f + 0.4f * appear.value; scaleY = scaleX; alpha = appear.value.coerceIn(0f, 1f) },
        )
        GreetingBubble(
            greetings[answerIndex].second, Color(0xFFD6452F), tailLeading = false,
            Modifier
                .offset(44.dp, 46.dp)
                .graphicsLayer { scaleX = 0.6f + 0.4f * appear.value; scaleY = scaleX; alpha = appear.value.coerceIn(0f, 1f) },
        )
    }
}

@Composable
private fun GreetingBubble(text: String, ink: Color, tailLeading: Boolean, modifier: Modifier) {
    val shape = remember(tailLeading) { bubbleShape(tailLeading) }
    Box(
        modifier
            .size(196.dp, 96.dp)
            .shadow(20.dp, shape, ambientColor = Color.Black.copy(alpha = 0.3f), spotColor = Color.Black.copy(alpha = 0.3f))
            .background(Color.White, shape),
        contentAlignment = Alignment.Center,
    ) {
        AnimatedContent(text, transitionSpec = { (fadeIn(tween(400)) + scaleIn(initialScale = 0.9f)) togetherWith fadeOut(tween(300)) }, label = "greeting") {
            Text(it, color = ink, fontSize = 34.sp, fontWeight = FontWeight.Bold, maxLines = 1, modifier = Modifier.padding(horizontal = 18.dp))
        }
    }
}

/** A rounded speech bubble with a small tail at a bottom corner, like the icon's. */
private fun bubbleShape(tailLeading: Boolean) = GenericShape { size, _ ->
    // Drawn in a 96-unit-tall box, like the iOS shape's points.
    val unit = size.height / 96f
    val radius = 30 * unit
    val body = Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, size.height, CornerRadius(radius))) }
    val x = if (tailLeading) radius else size.width - radius
    val d = if (tailLeading) -1f else 1f
    val tail = Path().apply {
        moveTo(x - 14 * unit * d, size.height - 2 * unit)
        quadraticTo(x + 6 * unit * d, size.height + 10 * unit, x + 16 * unit * d, size.height + 18 * unit)
        quadraticTo(x + 10 * unit * d, size.height + 6 * unit, x + 12 * unit * d, size.height - 2 * unit)
        close()
    }
    addPath(Path.combine(PathOperation.Union, body, tail))
}

/**
 * A little phone that lies down on the table and plays a conversation:
 * each half shows its reader's language, the far half upside down.
 */
@Composable
private fun TableDemo(active: Boolean) {
    val script = remember { DemoConversation.SCRIPT.take(3) }
    val tilt = remember { Animatable(0f) }
    var lineCount by remember { mutableIntStateOf(0) }
    var spokenLength by remember { mutableIntStateOf(0) }
    var translated by remember { mutableStateOf(false) }
    var listening by remember { mutableStateOf(false) }

    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        delay(500)
        launch { tilt.animateTo(1f, spring(dampingRatio = 0.7f, stiffness = 40f)) }
        delay(900)
        while (true) {
            listening = true
            for ((index, line) in script.withIndex()) {
                lineCount = index + 1
                spokenLength = 0
                translated = false
                val spoken = line.first
                // Chinese has fewer, denser characters; pace both alike.
                val step = if (spoken.length > 30) 2 else 1
                while (spokenLength < spoken.length) {
                    delay(if (index % 2 == 0) 45 else 110)
                    spokenLength = minOf(spoken.length, spokenLength + step)
                }
                delay(450)
                translated = true
                delay(1800)
            }
            listening = false
            delay(1500)
            lineCount = 0
            delay(700)
        }
    }

    val colors = Lively.colors
    val dark = MaterialTheme.colorScheme.background.red < 0.5f
    Box(
        Modifier
            .size(260.dp, 360.dp)
            .semantics { contentDescription = "A phone lying flat between two people. Each half shows the conversation in one person's language." },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .offset(y = 124.dp)
                .size(240.dp, 54.dp)
                .alpha(tilt.value * 0.12f)
                .background(Color.Black, RoundedCornerShape(50)),
        )
        Column(
            Modifier
                .offset { IntOffset(0, (12.dp * tilt.value).roundToPx()) }
                .graphicsLayer {
                    rotationX = 44f * tilt.value
                    cameraDistance = 6f * density
                }
                .size(200.dp, 390.dp)
                .shadow(if (dark) 30.dp else 16.dp, RoundedCornerShape(40.dp), spotColor = if (dark) MaterialTheme.colorScheme.primary else Color.Black)
                .clip(RoundedCornerShape(40.dp))
                .background(colors.card)
                .border(7.dp, Color(if (dark) 0xFF3D3D3D else 0xFF1F1F1F), RoundedCornerShape(40.dp))
                .padding(top = 38.dp, bottom = 22.dp),
        ) {
            DemoHalf(script, lineCount, spokenLength, translated, english = false, colors.secondInk, Modifier.weight(1f).rotate(180f))
            Row(Modifier.padding(horizontal = 14.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f).height(1.dp).background(MaterialTheme.colorScheme.outlineVariant))
                Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) {
                    val pulse = rememberInfiniteTransition(label = "pulse")
                    val ring by pulse.animateFloat(1f, 1.45f, infiniteRepeatable(tween(1100)), label = "ring")
                    if (listening) {
                        Box(
                            Modifier
                                .size(26.dp)
                                .scale(ring)
                                .alpha(1.45f - ring)
                                .border(2.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.35f), CircleShape),
                        )
                    }
                    Box(Modifier.size(26.dp).background(MaterialTheme.colorScheme.primary, CircleShape), contentAlignment = Alignment.Center) {
                        Icon(Icons.Rounded.GraphicEq, null, tint = Color.White, modifier = Modifier.size(14.dp))
                    }
                }
                Box(Modifier.weight(1f).height(1.dp).background(MaterialTheme.colorScheme.outlineVariant))
            }
            DemoHalf(script, lineCount, spokenLength, translated, english = true, colors.firstInk, Modifier.weight(1f))
        }
        // The camera punch-hole, riding along with the tilted phone.
        Box(
            Modifier
                .offset { IntOffset(0, ((-182).dp + 95.dp * tilt.value).roundToPx()) }
                .size(12.dp)
                .alpha(1f - tilt.value)
                .background(Color(0xFF1F1F1F), CircleShape),
        )
    }
}

/** One reader's half: the last two lines, newest at the bottom edge. */
@Composable
private fun DemoHalf(
    script: List<Pair<String, String>>,
    lineCount: Int,
    spokenLength: Int,
    translated: Boolean,
    english: Boolean,
    ink: Color,
    modifier: Modifier,
) {
    Box(modifier.fillMaxWidth()) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.Bottom),
        ) {
            for (index in maxOf(0, lineCount - 2) until lineCount) {
                val isLatest = index == lineCount - 1
                // Even lines are spoken in English by the near person.
                val ownWords = (index % 2 == 0) == english
                val line = script[index]
                val text = if (english == (index % 2 == 0)) line.first else line.second
                if (ownWords || !isLatest || translated) {
                    Text(
                        if (ownWords && isLatest) text.take(spokenLength) else text,
                        fontSize = if (isLatest) 14.sp else 12.sp,
                        lineHeight = if (isLatest) 18.sp else 15.sp,
                        fontWeight = if (isLatest && !ownWords) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (ownWords) MaterialTheme.colorScheme.onSurfaceVariant else ink,
                        modifier = Modifier.alpha(if (isLatest) 1f else 0.5f),
                    )
                } else {
                    TypingDots(ink, Modifier.padding(vertical = 4.dp), dotSize = 5.dp)
                }
            }
        }
        Text(
            if (english) "EN" else "中文",
            fontSize = 9.sp,
            fontWeight = FontWeight.Bold,
            color = ink,
            modifier = Modifier
                .padding(start = 14.dp)
                .clip(CircleShape)
                .background(ink.copy(alpha = 0.12f))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}
