package sh.ian.lively.model

import android.app.Activity
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Lively Pro: a bigger daily translation allowance, from a Google Play
 * subscription or, for some accounts, for free ([Account.hasFreePro]).
 *
 * The broker decides what each key allows (`Server/key-broker/src/play.ts`).
 * The app sends it the current subscription's purchase token, which the
 * broker checks with Google Play. Play keeps the token across renewals, and
 * restores purchases made on other devices with the same Google account.
 */
class Pro(
    context: Context,
    private val scope: CoroutineScope,
    private val account: Account?,
    private val isDemo: () -> Boolean,
) {
    /** One way to pay, as the store shows it. */
    data class Offer(
        val productID: String,
        val title: String,
        val price: String,
        val period: String,
        /** What the yearly plan saves against twelve months, e.g. "Save 33%". */
        val badge: String?,
        val details: ProductDetails?,
        val offerToken: String?,
    )

    sealed interface StoreState {
        data object Loading : StoreState
        data class Ready(val offers: List<Offer>) : StoreState
        data class Unavailable(val message: String) : StoreState
    }

    /** The active subscription purchase, if there is one. */
    var purchase by mutableStateOf<Purchase?>(null)
        private set
    var store by mutableStateOf<StoreState>(StoreState.Loading)
        private set
    /** Set when a free day's allowance runs out, so the app can offer Pro. */
    var freeLimitReached by mutableStateOf(false)
    /** A demo-mode purchase, so screenshots can show the subscribed state. */
    private var demoSubscribed by mutableStateOf(false)

    val isSubscribed: Boolean get() = purchase != null || demoSubscribed
    val isPro: Boolean get() = isSubscribed || account?.hasFreePro == true

    /** Its token, sent to the broker as `Lively-Play-Purchase`. */
    val purchaseToken: String? get() = purchase?.purchaseToken

    /** The plan changed, so a spare key minted on the old one is stale. */
    var onPlanChange: () -> Unit = {}

    private val client: BillingClient = BillingClient.newBuilder(context.applicationContext)
        .setListener { result, purchases -> scope.launch { handle(result, purchases) } }
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    private var connecting = false
    /** Gives up on a store that never answers; see [start]. */
    private var loadingTimeout: Job? = null

    /**
     * Connects to Play and reads what this Google account owns. Call at
     * launch and when the app comes forward: a purchase can renew, lapse or
     * be refunded meanwhile, or be bought on another device.
     */
    fun start() {
        // Before the early returns: demo mode can be turned on after the
        // first call, and the plans screen must never be left on its spinner.
        if (isDemo()) {
            store = StoreState.Ready(DEMO_OFFERS)
        } else if (store == StoreState.Loading && loadingTimeout?.isActive != true) {
            // Play can take forever to answer, or never call back at all.
            // A later answer still replaces this.
            loadingTimeout = scope.launch {
                delay(LOADING_TIMEOUT_MS)
                if (store == StoreState.Loading) store = StoreState.Unavailable(UNREACHABLE)
            }
        }
        if (client.isReady) {
            scope.launch { refresh() }
            return
        }
        if (connecting) return
        connecting = true
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                scope.launch {
                    connecting = false
                    if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                        refresh()
                    } else if (!isDemo()) {
                        store = StoreState.Unavailable(unavailableMessage(result))
                    }
                }
            }

            override fun onBillingServiceDisconnected() {
                scope.launch { connecting = false }
            }
        })
    }

    suspend fun refresh() {
        if (!client.isReady) return
        val owned = client.queryPurchasesAsync(
            QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build(),
        )
        if (owned.billingResult.responseCode == BillingClient.BillingResponseCode.OK) {
            apply(owned.purchasesList)
        }
        if (isDemo()) return
        val products = client.queryProductDetails(
            QueryProductDetailsParams.newBuilder().setProductList(
                PRODUCT_IDS.map {
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(it)
                        .setProductType(BillingClient.ProductType.SUBS)
                        .build()
                },
            ).build(),
        )
        val details = products.productDetailsList.orEmpty()
        store = if (products.billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
            StoreState.Unavailable(unavailableMessage(products.billingResult))
        } else if (details.isEmpty()) {
            StoreState.Unavailable("Lively Pro isn't available from Google Play on this device yet.")
        } else {
            StoreState.Ready(offers(details))
        }
    }

    /** Opens Google Play's purchase sheet for [offer]. */
    fun buy(activity: Activity, offer: Offer) {
        if (isDemo()) {
            demoSubscribed = true
            freeLimitReached = false
            return
        }
        val details = offer.details ?: return
        val params = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(details)
            .apply { offer.offerToken?.let(::setOfferToken) }
            .build()
        client.launchBillingFlow(activity, BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(params)).build())
    }

    /** Google Play's own page for this subscription, where it's cancelled or changed. */
    val manageURL: String
        get() {
            val product = purchase?.products?.firstOrNull()
            return if (product == null) {
                "https://play.google.com/store/account/subscriptions"
            } else {
                "https://play.google.com/store/account/subscriptions?sku=$product&package=sh.ian.lively"
            }
        }

    private suspend fun handle(result: BillingResult, purchases: List<Purchase>?) {
        if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
            apply(purchases)
        } else if (result.responseCode == BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED) {
            refresh()
        }
    }

    private suspend fun apply(purchases: List<Purchase>) {
        val active = purchases.filter {
            it.purchaseState == Purchase.PurchaseState.PURCHASED && it.products.any(PRODUCT_IDS::contains)
        }
        // Google refunds a purchase that isn't acknowledged within three days.
        for (purchase in active.filter { !it.isAcknowledged }) {
            client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build())
        }
        val newest = active.maxByOrNull { it.purchaseTime }
        val changed = newest?.purchaseToken != purchase?.purchaseToken
        purchase = newest
        if (isSubscribed) freeLimitReached = false
        if (changed) onPlanChange()
    }

    private fun offers(details: List<ProductDetails>): List<Offer> {
        val raw = details.sortedBy { PRODUCT_IDS.indexOf(it.productId) }.mapNotNull { product ->
            // The base plan: the offer with no special pricing phases.
            val offer = product.subscriptionOfferDetails?.minByOrNull { it.pricingPhases.pricingPhaseList.size } ?: return@mapNotNull null
            val phase = offer.pricingPhases.pricingPhaseList.lastOrNull() ?: return@mapNotNull null
            Triple(product, offer.offerToken, phase)
        }
        val monthly = raw.firstOrNull { it.third.billingPeriod == "P1M" }?.third?.priceAmountMicros
        return raw.map { (product, token, phase) ->
            val yearly = phase.billingPeriod == "P1Y"
            Offer(
                productID = product.productId,
                title = if (yearly) "Yearly" else "Monthly",
                price = phase.formattedPrice,
                period = if (yearly) "year" else "month",
                badge = if (yearly && monthly != null) savingBadge(phase.priceAmountMicros, monthly) else null,
                details = product,
                offerToken = token,
            )
        }
    }

    private fun unavailableMessage(result: BillingResult) = when (result.responseCode) {
        BillingClient.BillingResponseCode.BILLING_UNAVAILABLE ->
            "Google Play Billing isn't available. Sign in to the Play Store on this device to subscribe."
        BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE, BillingClient.BillingResponseCode.NETWORK_ERROR ->
            UNREACHABLE
        else -> "Lively Pro isn't available from Google Play on this device yet."
    }

    companion object {
        /** The Play subscriptions, monthly first. They must match the broker's `PLAY_PRODUCT_IDS`. */
        val PRODUCT_IDS = listOf("sh.ian.lively.pro.monthly", "sh.ian.lively.pro.yearly")

        /** How long the plans screen waits for Google Play before saying it can't be reached. */
        private const val LOADING_TIMEOUT_MS = 10_000L
        private const val UNREACHABLE = "Couldn't reach Google Play. Check your connection and try again."

        /**
         * What a year saves against twelve months, e.g. "Save 33%". The
         * percentage is rounded down, so it never overstates the saving, and
         * a saving under 5% isn't worth a badge. Prices are in micros.
         */
        fun savingBadge(yearlyMicros: Long, monthlyMicros: Long): String? {
            if (monthlyMicros <= 0) return null
            val twelveMonths = monthlyMicros * 12
            if (yearlyMicros >= twelveMonths) return null
            val saving = ((twelveMonths - yearlyMicros) * 100 / twelveMonths).toInt()
            return if (saving >= 5) "Save $saving%" else null
        }

        /** `Config/Lively.storekit`'s local test prices, for demo mode. */
        private val DEMO_OFFERS = listOf(
            Offer("sh.ian.lively.pro.yearly", "Yearly", "$39.99", "year", savingBadge(39_990_000, 4_990_000), null, null),
            Offer("sh.ian.lively.pro.monthly", "Monthly", "$4.99", "month", null, null, null),
        )
    }
}
