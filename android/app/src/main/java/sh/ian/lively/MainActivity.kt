package sh.ian.lively

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import sh.ian.lively.audio.SpeechPlayer
import sh.ian.lively.audio.MicCapture
import sh.ian.lively.model.ConversationHost
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguageSide
import sh.ian.lively.support.DebugFlags
import sh.ian.lively.ui.AccountScreen
import sh.ian.lively.ui.ConversationScreen
import sh.ian.lively.ui.LanguageListScreen
import sh.ian.lively.ui.LivelyTheme
import sh.ian.lively.ui.OnboardingScreen
import sh.ian.lively.ui.ProScreen
import sh.ian.lively.ui.SettingsScreen
import java.lang.ref.WeakReference

class MainActivity : ComponentActivity() {
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        pendingPermission?.complete(granted)
        pendingPermission = null
    }
    private var pendingPermission: CompletableDeferred<Boolean>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        // Read before the store exists, which is the first time per process.
        if (savedInstanceState == null) DebugFlags.read(intent)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT))
        val graph = (application as LivelyApp).graph

        setContent {
            val model: ConversationViewModel = viewModel { ConversationViewModel(graph) }
            DisposableEffect(Unit) {
                model.host.attach(this@MainActivity)
                onDispose { model.host.attach(null) }
            }
            LivelyTheme {
                LivelyNavigation(graph, model.store)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        DebugFlags.read(intent)
    }

    suspend fun requestMicPermission(): Boolean {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) return true
        val deferred = CompletableDeferred<Boolean>()
        pendingPermission?.complete(false)
        pendingPermission = deferred
        micPermission.launch(Manifest.permission.RECORD_AUDIO)
        return deferred.await()
    }

    fun keepScreenAwake(awake: Boolean) {
        if (awake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

/** The mic and the window, for a store that outlives any one activity. */
class AndroidConversationHost : ConversationHost {
    private var activity: WeakReference<MainActivity> = WeakReference(null)
    private val mic = MicCapture()
    private var awake = false

    /** A new activity (after rotation or a fold) takes over the window flags. */
    fun attach(activity: MainActivity?) {
        this.activity = WeakReference(activity)
        activity?.keepScreenAwake(awake)
    }

    override suspend fun requestMicPermission(): Boolean = activity.get()?.requestMicPermission() ?: false

    override fun startMic(onChunk: (ByteArray, Float) -> Unit, onInterrupted: () -> Unit) {
        mic.onChunk = onChunk
        mic.onInterrupted = onInterrupted
        mic.start()
    }

    override fun stopMic() = mic.stop()

    override fun keepScreenAwake(awake: Boolean) {
        this.awake = awake
        activity.get()?.keepScreenAwake(awake)
    }

    /** The app's AudioManager, not the activity's, since the player outlives it. */
    override fun makeSpeechPlayer() =
        SpeechPlayer(activity.get()?.applicationContext?.getSystemService(AudioManager::class.java))
}

class ConversationViewModel(graph: LivelyApp.Graph) : ViewModel() {
    val host = AndroidConversationHost()
    val store = ConversationStore(graph.settings, graph.scope, host, graph.keyProvider, graph.brokerTranslator, demo = DebugFlags.demo)
    private val networkListener: (Boolean, Boolean) -> Unit = { online, changed -> store.setNetwork(online, changed) }
    private val network = graph.network

    init {
        network.listen(networkListener)
    }

    override fun onCleared() {
        network.remove(networkListener)
        store.didEnterBackground()
    }
}

private object Routes {
    const val CONVERSATION = "conversation"
    const val ONBOARDING = "onboarding"
    const val SETTINGS = "settings"
    const val ACCOUNT = "settings/account"
    const val PRO = "pro"
    const val LANGUAGE = "settings/language/{side}"
    fun language(side: LanguageSide) = "settings/language/${side.name}"
}

@Composable
private fun LivelyNavigation(graph: LivelyApp.Graph, store: ConversationStore) {
    val nav = rememberNavController()
    val prefs = graph.prefs
    val settings = graph.settings
    var showsTranscript by remember { mutableStateOf(prefs.bool("phoneShowsTranscript")) }
    var nearLanguage by remember { mutableStateOf(Language(prefs.string("nearLanguage") ?: settings.languages.first.code)) }
    val start = remember {
        when {
            DebugFlags.forceOnboarding -> Routes.ONBOARDING
            DebugFlags.demo -> Routes.CONVERSATION
            !prefs.bool("onboardingDone") -> Routes.ONBOARDING
            else -> Routes.CONVERSATION
        }
    }

    ForegroundEffects(graph, store)

    NavHost(
        navController = nav,
        startDestination = start,
        enterTransition = { slideInHorizontally { it / 4 } + fadeIn() },
        exitTransition = { slideOutHorizontally { -it / 4 } + fadeOut() },
        popEnterTransition = { slideInHorizontally { -it / 4 } + fadeIn() },
        popExitTransition = { slideOutHorizontally { it / 4 } + fadeOut() },
        modifier = Modifier.onPreviewKeyEvent { event ->
            // Space starts and stops listening on a hardware keyboard, as on the Mac.
            val onConversation = nav.currentDestination?.route == Routes.CONVERSATION
            if (onConversation && event.key == Key.Spacebar && event.type == KeyEventType.KeyUp) {
                store.toggleListening()
                true
            } else {
                false
            }
        },
    ) {
        composable(Routes.CONVERSATION) {
            LaunchedEffect(Unit) {
                if (DebugFlags.demo && DebugFlags.demoAutoPlay && !store.isListening && store.utterances.isEmpty()) {
                    DebugFlags.demoAutoPlay = false
                    store.toggleListening()
                } else if (!DebugFlags.demo && !settings.hasCredentials && prefs.bool("onboardingDone")) {
                    nav.navigateSingle(Routes.SETTINGS)
                }
            }
            ConversationScreen(
                store = store,
                settings = settings,
                pro = graph.pro,
                showsTranscript = showsTranscript,
                onShowsTranscriptChange = {
                    showsTranscript = it
                    prefs.putBool("phoneShowsTranscript", it)
                },
                nearLanguage = nearLanguage,
                onNearLanguageChange = {
                    nearLanguage = it
                    prefs.putString("nearLanguage", it.code)
                },
                onShowSettings = { nav.navigateSingle(Routes.SETTINGS) },
                onShowPro = { nav.navigateSingle(Routes.PRO) },
            )
        }
        composable(Routes.ONBOARDING) {
            OnboardingScreen(settings, graph.account) {
                prefs.putBool("onboardingDone", true)
                nearLanguage = settings.languages.first
                prefs.putString("nearLanguage", nearLanguage.code)
                store.settingsDidClose()
                nav.navigate(Routes.CONVERSATION) { popUpTo(0) { inclusive = true } }
                if (!settings.hasCredentials) nav.navigate(Routes.SETTINGS)
            }
        }
        composable(Routes.SETTINGS) {
            // Settings can change the provider, key or languages, which a warm session can't pick up.
            DisposableEffect(Unit) { onDispose { store.settingsDidClose() } }
            SettingsScreen(
                settings = settings,
                account = graph.account,
                pro = graph.pro,
                hasBroker = graph.keyProvider != null,
                onBack = { nav.popBackStack() },
                onAccount = { nav.navigateSingle(Routes.ACCOUNT) },
                onPro = { nav.navigateSingle(Routes.PRO) },
                onLanguage = { nav.navigateSingle(Routes.language(it)) },
                onWelcome = { nav.navigate(Routes.ONBOARDING) { popUpTo(Routes.CONVERSATION) } },
                onClear = {
                    store.clear()
                    nav.popBackStack()
                },
            )
        }
        composable(Routes.LANGUAGE) { entry ->
            val side = LanguageSide.valueOf(entry.arguments?.getString("side") ?: LanguageSide.FIRST.name)
            LanguageListScreen(settings, side, onDone = { nav.popBackStack() })
        }
        composable(Routes.ACCOUNT) {
            graph.account?.let { AccountScreen(it, onBack = { nav.popBackStack() }) }
        }
        composable(Routes.PRO) {
            ProScreen(graph.pro, graph.account, onBack = { nav.popBackStack() })
        }
    }
}

/** Taps during a screen transition can arrive twice; don't stack the same screen. */
private fun NavHostController.navigateSingle(route: String) {
    if (currentDestination?.route == route) return
    navigate(route) { launchSingleTop = true }
}

/**
 * Coming forward re-measures regions, readies a key and rereads the plan.
 * Going to the background stops listening: Android won't let a background
 * app keep the mic without a foreground service, and a translator that keeps
 * listening in a pocket would surprise people.
 */
@Composable
private fun ForegroundEffects(graph: LivelyApp.Graph, store: ConversationStore) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    store.didBecomeActive()
                    graph.pro.start()
                    graph.scope.launch { graph.account?.refresh() }
                }
                Lifecycle.Event.ON_STOP -> store.didEnterBackground()
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
}
