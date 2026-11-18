package sh.ian.lively.ui

import androidx.activity.compose.LocalActivity
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.height
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import sh.ian.lively.model.Account
import sh.ian.lively.model.Pro

/**
 * Lively Pro: subscribe, restore, or see what you have. Pushed from
 * Settings and the account screen, and shown with [limitReached] when a
 * free day's translation time runs out.
 *
 * The allowances here match the key broker's limits in `wrangler.jsonc`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProScreen(
    pro: Pro,
    account: Account?,
    onBack: () -> Unit,
    /** Opened because today's free time ran out, which the header then says. */
    limitReached: Boolean = false,
    /** Opens the account screen, for the free hour signing in adds. */
    onSignIn: () -> Unit = {},
) {
    val uri = LocalUriHandler.current
    LaunchedEffect(Unit) { pro.start() }
    val hasPro = pro.isSubscribed || account?.hasFreePro == true
    // Signing in is the free way to keep going, where there's an account service.
    val offersSignIn = limitReached && account != null && !account.isSignedIn
    BoxWithConstraints {
        // The plans and Subscribe stay on screen under a header that scrolls.
        // A landscape phone is too short for both; there it all scrolls.
        val pinsStore = !hasPro && maxHeight >= 600.dp
        val store: @Composable () -> Unit = {
            Column(
                Modifier.widthIn(max = 460.dp).padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Store(pro, if (offersSignIn) onSignIn else null)
                Links()
            }
        }
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                TopAppBar(
                    title = { Text("Lively Pro") },
                    navigationIcon = { BackButton(onBack) },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                )
            },
            bottomBar = {
                if (pinsStore) {
                    // The same background as the screen, with no edge: the header
                    // fades out as it scrolls under.
                    val background = MaterialTheme.colorScheme.background
                    Column(Modifier.fillMaxWidth()) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(StoreFade)
                                .background(Brush.verticalGradient(listOf(background.copy(alpha = 0f), background))),
                        )
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .background(background)
                                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
                            contentAlignment = Alignment.TopCenter,
                        ) { store() }
                    }
                }
            },
        ) { padding ->
            Box(
                Modifier
                    .fillMaxSize()
                    .padding(top = padding.calculateTopPadding())
                    // Up to the store itself, so the header scrolls under its fade.
                    .padding(bottom = (padding.calculateBottomPadding() - if (pinsStore) StoreFade else 0.dp).coerceAtLeast(0.dp))
                    .verticalScroll(rememberScrollState()),
                contentAlignment = Alignment.TopCenter,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Column(
                        Modifier
                            .widthIn(max = 460.dp)
                            .padding(horizontal = 24.dp)
                            .padding(top = 8.dp, bottom = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(28.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        when {
                            pro.isSubscribed -> {
                                ProHeader("You have Lively Pro", "It renews through Google Play until you cancel.")
                                PillButton("Manage subscription", onClick = { uri.openUri(pro.manageURL) })
                            }
                            account?.hasFreePro == true -> ProHeader("You have Lively Pro", "It's included free with your account.")
                            // The subtitle says what Pro adds, so the list of
                            // benefits is left out and the plans stay close.
                            limitReached -> ProHeader(
                                "That's today's free time",
                                if (offersSignIn) {
                                    "Free translation is back tomorrow. Sign in for another hour today, or get 10 hours a day with Pro."
                                } else {
                                    "Free translation is back tomorrow. Lively Pro gives you 10 hours a day."
                                },
                                showsBenefits = false,
                            )
                            else -> ProHeader()
                        }
                    }
                    if (hasPro) {
                        Links()
                    } else if (!pinsStore) {
                        store()
                    }
                    if (!pinsStore) Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
                }
            }
        }
    }
}

@Composable
private fun Links() {
    val uri = LocalUriHandler.current
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuietButton("Terms of Use") { uri.openUri(TERMS) }
        QuietButton("Privacy Policy") { uri.openUri(PRIVACY) }
    }
}

/** A small text button for the things under Subscribe, which shouldn't compete with it. */
@Composable
private fun QuietButton(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.heightIn(min = 40.dp), contentPadding = PaddingValues(horizontal = 12.dp)) {
        Text(text, style = MaterialTheme.typography.labelLarge, color = color)
    }
}

/** The plans, Subscribe and what's under it. [onSignIn] is set when signing in is offered instead. */
@Composable
private fun Store(pro: Pro, onSignIn: (() -> Unit)?) {
    val activity = LocalActivity.current
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        when (val store = pro.store) {
            Pro.StoreState.Loading -> CircularProgressIndicator(Modifier.padding(vertical = 24.dp))
            is Pro.StoreState.Unavailable -> Text(
                store.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(vertical = 16.dp),
            )
            is Pro.StoreState.Ready -> {
                // Yearly first, as on the App Store.
                val offers = store.offers.sortedByDescending { it.period == "year" }
                var selected by rememberSaveable { mutableStateOf(offers.firstOrNull()?.productID) }
                Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    for (offer in offers) {
                        PlanCard(offer, offer.productID == selected) { selected = offer.productID }
                    }
                }
                PillButton("Subscribe", onClick = {
                    val offer = offers.firstOrNull { it.productID == selected } ?: return@PillButton
                    activity?.let { pro.buy(it, offer) }
                })
                Text(
                    "Renews automatically until you cancel in Google Play. Cancel anytime.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            if (onSignIn != null) {
                QuietButton("Sign in for another free hour", MaterialTheme.colorScheme.primary, onSignIn)
            }
            // Play may only have been slow, so this is offered whatever the store said.
            QuietButton("Restore purchases") { pro.start() }
        }
    }
}

@Composable
private fun PlanCard(offer: Pro.Offer, selected: Boolean, onClick: () -> Unit) {
    val border by animateColorAsState(
        if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
        label = "plan border",
    )
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .border(if (selected) 2.dp else 1.dp, border, RoundedCornerShape(20.dp))
            .selectable(selected, onClick = onClick, role = Role.RadioButton)
            // "plan-year" and "plan-month", for the UI tests.
            .testTag("plan-${offer.period}")
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RadioButton(selected = selected, onClick = null)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(offer.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                offer.badge?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(Color(0xFFFF9500))
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                }
            }
            Text("${offer.price} per ${offer.period}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ProHeader(title: String = "Lively Pro", subtitle: String = "Translate for hours, every day.", showsBenefits: Boolean = true) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                Modifier
                    .size(80.dp)
                    .shadow(14.dp, CircleShape, spotColor = Color(0xFFFF9500))
                    .clip(CircleShape)
                    .background(Brush.linearGradient(listOf(Color(0xFFFF9500), Color(0xFFFF2D55)))),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Rounded.Star, null, tint = Color.White, modifier = Modifier.size(38.dp))
            }
            Text(title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
            Text(subtitle, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        if (showsBenefits) Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Benefit(Icons.Rounded.Timer, Color(0xFFFF9500), "10 hours a day", "Free gives you an hour a day, or two when you're signed in.")
            Benefit(Icons.Rounded.Devices, Color(0xFF007AFF), "On all your devices", "Pro comes with your Google account. No sign-in needed.")
            Benefit(Icons.AutoMirrored.Rounded.Undo, Color(0xFF34C759), "Cancel anytime", "Manage it in Google Play's Payments & subscriptions.")
        }
    }
}

/** How far the header fades before it reaches the pinned plans. */
private val StoreFade = 20.dp

private const val TERMS = "https://lively.cautela.hk/terms"
private const val PRIVACY = "https://lively.cautela.hk/privacy"
