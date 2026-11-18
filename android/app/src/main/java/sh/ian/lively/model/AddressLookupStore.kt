package sh.ian.lively.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Owns lookup work without involving microphone, conversation, or speech state. */
class AddressLookupStore(
    private val service: AddressLookupProviding,
    language: AddressLanguage,
    private val scope: CoroutineScope,
) {
    enum class Phase { IDLE, SEARCHING, CHOOSING, LOCALIZING, RESOLVED }

    private var _query by mutableStateOf("")
    var query: String
        get() = _query
        set(value) {
            if (value == _query) return
            _query = value
            reset()
        }

    private var _language by mutableStateOf(language)
    var language: AddressLanguage
        get() = _language
        set(value) {
            if (value == _language) return
            _language = value
            val place = selectedPlace
            if (place != null) {
                select(place)
            } else {
                cancelWork()
                address = null
                errorMessage = null
                phase = if (matches.isEmpty()) Phase.IDLE else Phase.CHOOSING
            }
        }

    var phase by mutableStateOf(Phase.IDLE)
        private set
    var matches by mutableStateOf(emptyList<AddressPlace>())
        private set
    var selectedPlace by mutableStateOf<AddressPlace?>(null)
        private set
    var address by mutableStateOf<String?>(null)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    private var work: Job? = null

    /** Replaced whenever work is cancelled, so a late answer finds it has been superseded. */
    private var operation = Any()

    val isBusy: Boolean get() = phase == Phase.SEARCHING || phase == Phase.LOCALIZING
    val canSearch: Boolean get() = normalizedQuery.isNotEmpty() && !isBusy
    val copyValue: String? get() = if (phase == Phase.RESOLVED) address else null

    private val normalizedQuery: String
        get() = query.split(WHITESPACE).filter { it.isNotEmpty() }.joinToString(" ")

    fun find() {
        val input = normalizedQuery
        reset()
        if (input.isEmpty()) return
        if (input.codePointCount(0, input.length) > 1_000) {
            errorMessage = "Use a shorter address or place name."
            return
        }
        if (input.startsWith("https://", ignoreCase = true) || input.startsWith("http://", ignoreCase = true)) {
            errorMessage = "Paste an address or place name instead of a map link."
            return
        }
        phase = Phase.SEARCHING
        val token = operation
        work = scope.launch {
            try {
                val places = service.findPlaces(input)
                if (!isCurrent(token)) return@launch
                matches = places.filter { it.hasValidCoordinate }.take(8)
                phase = if (matches.isEmpty()) Phase.IDLE else Phase.CHOOSING
                if (matches.isEmpty()) errorMessage = "No places found. Add a city or country and try again."
            } catch (error: Exception) {
                if (!isCurrent(token)) return@launch
                phase = Phase.IDLE
                if (error !is CancellationException) errorMessage = message(error)
            }
            work = null
        }
    }

    fun select(place: AddressPlace) {
        if (place !in matches) return
        cancelWork()
        selectedPlace = place
        address = null
        errorMessage = null
        phase = Phase.LOCALIZING
        val token = operation
        val requestedLanguage = language
        work = scope.launch {
            try {
                val value = service.address(place, requestedLanguage)
                if (!isCurrent(token)) return@launch
                val trimmed = value.trim()
                if (trimmed.isEmpty()) throw AddressLookupException(AddressLookupError.MISSING_ADDRESS)
                address = trimmed
                phase = Phase.RESOLVED
            } catch (error: Exception) {
                if (!isCurrent(token)) return@launch
                phase = Phase.CHOOSING
                if (error !is CancellationException) errorMessage = message(error)
            }
            work = null
        }
    }

    fun retry() {
        val place = selectedPlace
        if (place != null) select(place) else find()
    }

    fun close() = reset()

    private fun reset() {
        cancelWork()
        matches = emptyList()
        selectedPlace = null
        address = null
        errorMessage = null
        phase = Phase.IDLE
    }

    private fun cancelWork() {
        operation = Any()
        work?.cancel()
        work = null
        service.cancel()
    }

    private fun CoroutineScope.isCurrent(token: Any) = operation === token && isActive

    private fun message(error: Exception): String =
        (error as? AddressLookupException)?.error?.message ?: "Couldn’t look up this place. Try again."

    private companion object {
        /** Unicode white space, including the no-break and ideographic spaces `\s` leaves out. */
        val WHITESPACE = Regex("[\\s\\p{Z}]+")
    }
}
