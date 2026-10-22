package sh.ian.lively

import android.app.Application
import android.content.Context
import android.icu.text.Transliterator
import android.icu.util.ULocale
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.view.textclassifier.TextClassificationManager
import android.view.textclassifier.TextLanguage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import sh.ian.lively.model.Account
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.LanguageDetector
import sh.ian.lively.model.Pro
import sh.ian.lively.model.ScriptConverter
import sh.ian.lively.model.SpeechProviders
import sh.ian.lively.net.BrokerTranslator
import sh.ian.lively.net.RegionProber
import sh.ian.lively.net.SonioxKeyProvider
import sh.ian.lively.support.DebugFlags
import sh.ian.lively.support.KeystoreSecretStore
import sh.ian.lively.support.SharedPreferencesStore
import java.util.UUID

/** The app's long-lived objects, built once per process. */
class LivelyApp : Application() {
    lateinit var graph: Graph
        private set

    override fun onCreate() {
        super.onCreate()
        installPlatformText(this)
        graph = Graph(this)
    }

    class Graph(context: Context) {
        val scope: CoroutineScope = MainScope()
        val prefs = SharedPreferencesStore(context.getSharedPreferences("lively", Context.MODE_PRIVATE))
        val secrets = KeystoreSecretStore(context)
        private val brokerURL = BuildConfig.KEY_BROKER_URL.takeIf { it.isNotEmpty() }

        /** Null when the build has no key broker. */
        val account: Account? = brokerURL?.let { Account(it, secrets, prefs, scope, isDemo = { DebugFlags.demo }) }
        val pro = Pro(context, scope, account, isDemo = { DebugFlags.demo })

        /**
         * A random ID for this install. It names no person or device, and the
         * broker only sees a hash of it.
         */
        private val installID: String = secrets.read(INSTALL_ID) ?: UUID.randomUUID().toString().also { secrets.write(it, INSTALL_ID) }

        /** Who's asking, for the broker's limits. */
        private val identity = object : SonioxKeyProvider.Identity {
            override val accountToken get() = account?.token
            override fun accountTokenRejected(token: String) { account?.tokenWasRejected(token) }
            override val playPurchaseToken get() = pro.purchaseToken
            override fun freeLimitReached() { pro.freeLimitReached = true }
        }

        /** Null when the build has no key broker, so Soniox needs a key entered in Settings. */
        val keyProvider: SonioxKeyProvider? = brokerURL?.let { url ->
            SonioxKeyProvider(
                brokerURL = url,
                regions = RegionProber(prefs, scope),
                scope = scope,
                installID = installID,
                identity = identity,
            )
        }

        /** Translates typed text; null when the build has no key broker. */
        val brokerTranslator: BrokerTranslator? = brokerURL?.let { BrokerTranslator(it, installID, identity) }

        val settings = AppSettings(prefs, secrets, SpeechProviders.all(scope, keyProvider))

        val network = NetworkWatcher(context)

        init {
            // A spare key minted on the old plan carries the old plan's limits.
            account?.onPlanChange = { keyProvider?.dropSpare() }
            pro.onPlanChange = { keyProvider?.dropSpare() }
        }

        private companion object {
            const val INSTALL_ID = "lively-install-id"
        }
    }

    companion object {
        /**
         * Points the platform-neutral model at Android's on-device text
         * services: ICU for Simplified → Traditional, and TextClassifier to
         * tell apart two languages that share a script.
         */
        fun installPlatformText(context: Context) {
            val transliterator by lazy { Transliterator.getInstance("Hans-Hant") }
            ScriptConverter.toTraditional = { text -> synchronized(transliterator) { transliterator.transliterate(text) } }

            val classifier = context.getSystemService(TextClassificationManager::class.java)?.textClassifier
            LanguageDetector.fallback = fallback@{ text, pair ->
                classifier ?: return@fallback null
                val result = runCatching { classifier.detectLanguage(TextLanguage.Request.Builder(text).build()) }.getOrNull()
                    ?: return@fallback null
                val scores = pair.all.associateWith { language ->
                    val code = if (language.code == "no") "nb" else language.code
                    maxOf(result.getConfidenceScore(ULocale.forLanguageTag(code)), result.getConfidenceScore(ULocale(language.code)))
                }
                scores.maxByOrNull { it.value }?.takeIf { it.value > 0f }?.key
            }
        }
    }
}

/**
 * Follows the default network. Reports whether there is one, and when it
 * changes to another (Wi-Fi to cellular) while staying online.
 */
class NetworkWatcher(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val scope = MainScope()
    private var current: Network? = null
    private val listeners = mutableListOf<(online: Boolean, changed: Boolean) -> Unit>()

    var isOnline = true
        private set

    fun listen(listener: (online: Boolean, changed: Boolean) -> Unit) {
        listeners += listener
        listener(isOnline, false)
    }

    fun remove(listener: (online: Boolean, changed: Boolean) -> Unit) {
        listeners -= listener
    }

    init {
        isOnline = connectivity?.activeNetwork != null
        current = connectivity?.activeNetwork
        connectivity?.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val online = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                scope.launch(Dispatchers.Main) { update(network, online) }
            }

            override fun onLost(network: Network) {
                scope.launch(Dispatchers.Main) { if (network == current) update(null, false) }
            }
        })
    }

    private fun update(network: Network?, online: Boolean) {
        val changed = online && isOnline && current != null && network != null && network != current
        if (online) current = network
        if (!online && network == null) current = null
        if (online == isOnline && !changed) return
        isOnline = online
        listeners.toList().forEach { it(online, changed) }
    }
}
