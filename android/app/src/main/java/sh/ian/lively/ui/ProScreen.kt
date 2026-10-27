package sh.ian.lively.ui

import androidx.activity.compose.LocalActivity
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.runtime.rememberCoroutineScope
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
import kotlinx.coroutines.launch
import sh.ian.lively.model.Account
import sh.ian.lively.model.Pro

/**
 * Lively Pro: subscribe, restore, or see what you have. Pushed from
 * Settings, and shown when a free day's translation time runs out.
 *
 * The allowances here match the key broker's limits in `wrangler.jsonc`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProScreen(pro: Pro, account: Account?, onBack: () -> Unit) {
    val uri = LocalUriHandler.current
    LaunchedEffect(Unit) { pro.start() }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("Lively Pro") },
                navigationIcon = { BackButton(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.TopCenter,
        ) {
            Column(
                Modifier
                    .widthIn(max = 460.dp)
                    .padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                when {
                    pro.isSubscribed -> {
                        ProHeader("You have Lively Pro", "It renews through Google Play until you cancel.")
                        PillButton("Manage subscription", onClick = { uri.openUri(pro.manageURL) })
                    }
                    account?.hasFreePro == true -> ProHeader("You have Lively Pro", "It's included free with your account.")
                    else -> {
                        ProHeader()
                        Store(pro)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { uri.openUri(TERMS) }) { Text("Terms of Use") }
                    TextButton(onClick = { uri.openUri(PRIVACY) }) { Text("Privacy Policy") }
                }
                Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
            }
        }
    }
}

@Composable
private fun Store(pro: Pro) {
    val activity = LocalActivity.current
    val scope = rememberCoroutineScope()
    when (val store = pro.store) {
        Pro.StoreState.Loading -> CircularProgressIndicator()
        is Pro.StoreState.Unavailable -> Text(
            store.message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        is Pro.StoreState.Ready -> {
            // Yearly first, as on the App Store.
            val offers = store.offers.sortedByDescending { it.period == "year" }
            var selected by rememberSaveable { mutableStateOf(offers.firstOrNull()?.productID) }
            Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                for (offer in offers) {
                    PlanCard(offer, offer.productID == selected) { selected = offer.productID }
                }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
                TextButton(onClick = { scope.launch { pro.refresh() } }) { Text("Restore purchases") }
            }
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
            .padding(horizontal = 12.dp, vertical = 14.dp),
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
private fun ProHeader(title: String = "Lively Pro", subtitle: String = "Translate for hours, every day.") {
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
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Benefit(Icons.Rounded.Timer, Color(0xFFFF9500), "10 hours a day", "Free gives you an hour a day, or two when you're signed in.")
            Benefit(Icons.Rounded.Devices, Color(0xFF007AFF), "On all your devices", "Pro comes with your Google account. No sign-in needed.")
            Benefit(Icons.AutoMirrored.Rounded.Undo, Color(0xFF34C759), "Cancel anytime", "Manage it in Google Play's Payments & subscriptions.")
        }
        Spacer(Modifier.height(0.dp))
    }
}

private const val TERMS = "https://lively.ian.sh/terms"
private const val PRIVACY = "https://lively.ian.sh/privacy"
