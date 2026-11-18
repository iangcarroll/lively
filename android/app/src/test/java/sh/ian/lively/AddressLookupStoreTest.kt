package sh.ian.lively

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.AddressLanguage
import sh.ian.lively.model.AddressLookupError
import sh.ian.lively.model.AddressLookupException
import sh.ian.lively.model.AddressLookupProviding
import sh.ian.lively.model.AddressLookupStore
import sh.ian.lively.model.AddressLookupStore.Phase
import sh.ian.lively.model.AddressPlace

private class FakeAddressService : AddressLookupProviding {
    val searches = mutableListOf<String>()
    val addresses = mutableListOf<Pair<AddressPlace, AddressLanguage>>()
    var cancelCount = 0
    private val pendingSearches = mutableMapOf<Int, CompletableDeferred<List<AddressPlace>>>()
    private val pendingAddresses = mutableMapOf<Int, CompletableDeferred<String>>()

    // Deliberately ignores cancellation. The store must independently reject
    // responses from operations that have been replaced or dismissed.
    override suspend fun findPlaces(query: String): List<AddressPlace> {
        val pending = CompletableDeferred<List<AddressPlace>>()
        pendingSearches[searches.size] = pending
        searches += query
        return withContext(NonCancellable) { pending.await() }
    }

    override suspend fun address(place: AddressPlace, language: AddressLanguage): String {
        val pending = CompletableDeferred<String>()
        pendingAddresses[addresses.size] = pending
        addresses += place to language
        return withContext(NonCancellable) { pending.await() }
    }

    override fun cancel() {
        cancelCount++
    }

    fun finishSearch(index: Int, places: List<AddressPlace>) = check(pendingSearches.remove(index)!!.complete(places))
    fun failSearch(index: Int, error: Exception) = check(pendingSearches.remove(index)!!.completeExceptionally(error))
    fun finishAddress(index: Int, address: String) = check(pendingAddresses.remove(index)!!.complete(address))
    fun failAddress(index: Int, error: Exception) = check(pendingAddresses.remove(index)!!.completeExceptionally(error))

    val pendingCount: Int get() = pendingSearches.size + pendingAddresses.size
}

/** The cases of `Tools/tests/AddressLookupRegression.swift`, against the Kotlin store. */
@OptIn(ExperimentalCoroutinesApi::class)
class AddressLookupStoreTest {
    private val japanese = AddressLanguage("ja")
    private val english = AddressLanguage("en")
    private val station = AddressPlace("tokyo-station", "Tokyo Station", "Chiyoda, Tokyo, Japan", 35.681236, 139.767125, "JP")
    private val museum = AddressPlace("tokyo-museum", "Tokyo National Museum", "Taito, Tokyo, Japan", 35.718835, 139.776527, "JP")
    private val japaneseAddress = "〒100-0005\n東京都千代田区丸の内1丁目9−1"
    private val museumAddress = "東京都台東区上野公園13−9"

    private val service = FakeAddressService()

    private fun TestScope.store(language: AddressLanguage = japanese) = AddressLookupStore(service, language, backgroundScope)

    private fun network() = AddressLookupException(AddressLookupError.NETWORK)

    private fun TestScope.search(store: AddressLookupStore, query: String = "Tokyo", places: List<AddressPlace> = listOf(station, museum)) {
        val index = service.searches.size
        store.query = query
        store.find()
        runCurrent()
        service.finishSearch(index, places)
        runCurrent()
    }

    private fun TestScope.resolve(store: AddressLookupStore, place: AddressPlace = station, address: String = japaneseAddress) {
        val index = service.addresses.size
        store.select(place)
        runCurrent()
        service.finishAddress(index, address)
        runCurrent()
    }

    @Test fun eachLookupHasItsOwnLanguage() = runTest {
        val first = store(japanese)
        val second = AddressLookupStore(FakeAddressService(), english, backgroundScope)
        first.language = AddressLanguage("zh-Hant")
        assertEquals("zh-Hant", first.language.code)
        assertEquals(english, second.language)
    }

    @Test fun emptyInputDoesNotContactTheService() = runTest {
        val store = store()
        assertEquals(Phase.IDLE, store.phase)
        assertFalse(store.isBusy)
        assertFalse(store.canSearch)
        assertNull(store.copyValue)
        for (input in listOf("", " \t\r\n 　")) {
            store.query = input
            assertFalse(store.canSearch)
            store.find()
            runCurrent()
            assertTrue(service.searches.isEmpty())
            assertEquals(Phase.IDLE, store.phase)
            assertNull(store.errorMessage)
        }
    }

    @Test fun oversizedInputAndLinksAreRejectedBeforeARequest() = runTest {
        val store = store()
        for (input in listOf("東".repeat(1_001), "https://maps.apple.com/?q=Tokyo", "  HTTPS://maps.example/location  ", "http://example.com/map")) {
            store.query = input
            store.find()
            runCurrent()
            assertTrue(service.searches.isEmpty())
            assertFalse(store.isBusy)
            assertNull(store.copyValue)
            assertNotNull(store.errorMessage)
        }
        store.query = "a".repeat(1_000)
        store.find()
        runCurrent()
        assertEquals(1_000, service.searches.single().length)
        service.finishSearch(0, emptyList())
        runCurrent()
        assertEquals(0, service.pendingCount)
    }

    @Test fun queryIsNormalizedAndFindingDoesNotSelect() = runTest {
        val store = store()
        search(store, " \t〒100-0005\n東京都千代田区\r\n丸の内1丁目9−1　 ", listOf(station))
        assertEquals(listOf("〒100-0005 東京都千代田区 丸の内1丁目9−1"), service.searches)
        assertEquals(Phase.CHOOSING, store.phase)
        assertNull(store.selectedPlace)
        assertTrue(service.addresses.isEmpty())
    }

    @Test fun selectionResolvesAndEditingInvalidatesIt() = runTest {
        val store = store()
        search(store)
        assertEquals(listOf(station, museum), store.matches)
        assertNull(store.selectedPlace)
        assertNull(store.copyValue)

        // A forged candidate with a reused identifier cannot be selected.
        store.select(station.copy(latitude = station.latitude + 1))
        runCurrent()
        assertNull(store.selectedPlace)
        assertEquals(Phase.CHOOSING, store.phase)
        assertTrue(service.addresses.isEmpty())

        resolve(store, address = " \n$japaneseAddress\n ")
        assertEquals(station to japanese, service.addresses[0])
        assertEquals(Phase.RESOLVED, store.phase)
        assertEquals(japaneseAddress, store.address)
        assertEquals(japaneseAddress, store.copyValue)
        // Localization does not replace the selected map coordinates.
        assertEquals(station, store.selectedPlace)

        val cancels = service.cancelCount
        store.query = "Kyoto"
        assertTrue(service.cancelCount > cancels)
        assertEquals(Phase.IDLE, store.phase)
        assertTrue(store.matches.isEmpty())
        assertNull(store.selectedPlace)
        assertNull(store.copyValue)

        // A previously valid candidate is rejected after the query changes.
        store.select(station)
        runCurrent()
        assertEquals(1, service.addresses.size)
        assertNull(store.selectedPlace)
        assertEquals(0, service.pendingCount)
    }

    @Test fun invalidCoordinatesAreFilteredBeforeTheResultLimit() = runTest {
        fun place(id: String, latitude: Double, longitude: Double) = AddressPlace(id, id, "Coordinate validation fixture", latitude, longitude, null)
        val invalid = listOf(
            Double.NaN to 0.0, 0.0 to Double.NaN, Double.POSITIVE_INFINITY to 0.0, Double.NEGATIVE_INFINITY to 0.0,
            0.0 to Double.POSITIVE_INFINITY, 0.0 to Double.NEGATIVE_INFINITY, 90.0001 to 0.0, -90.0001 to 0.0,
            0.0 to 180.0001, 0.0 to -180.0001,
        ).mapIndexed { index, (latitude, longitude) -> place("invalid-$index", latitude, longitude) }
        val valid = listOf(place("zero", 0.0, 0.0), place("minimum", -90.0, -180.0), place("maximum", 90.0, 180.0)) +
            (0 until 9).map { place("valid-$it", it.toDouble(), it.toDouble()) }
        invalid.forEach { assertFalse(it.id, it.hasValidCoordinate) }
        valid.forEach { assertTrue(it.id, it.hasValidCoordinate) }

        val store = store(english)
        // More than eight invalid entries come first, so the cap must be applied
        // after filtering; otherwise valid results would disappear entirely.
        search(store, "Coordinate fixtures", invalid + valid)
        assertEquals(valid.take(8), store.matches)
        assertEquals(Phase.CHOOSING, store.phase)
        assertNull(store.errorMessage)

        // A provider result outside the displayed limit cannot be selected.
        store.select(valid[8])
        runCurrent()
        assertNull(store.selectedPlace)
        assertTrue(service.addresses.isEmpty())

        // Zero coordinates are a valid selected location, not a missing-data sentinel.
        resolve(store, valid[0], "Equator, Atlantic Ocean")
        assertEquals(valid[0], store.selectedPlace)
        assertEquals("Equator, Atlantic Ocean", store.copyValue)

        search(store, "Invalid coordinates only", invalid)
        assertEquals(Phase.IDLE, store.phase)
        assertTrue(store.matches.isEmpty())
        assertNull(store.selectedPlace)
        assertNotNull(store.errorMessage)
        assertNull(store.copyValue)
        assertEquals(0, service.pendingCount)
    }

    @Test fun lateSearchCannotReplaceANewerQuery() = runTest {
        val store = store()
        store.query = "Old query"
        store.find()
        runCurrent()
        store.query = "New query"
        store.find()
        runCurrent()
        service.finishSearch(1, listOf(museum))
        runCurrent()
        service.finishSearch(0, listOf(station))
        runCurrent()
        assertEquals(listOf(museum), store.matches)
        assertEquals(Phase.CHOOSING, store.phase)
        assertNull(store.errorMessage)

        store.query = "Old failing query"
        store.find()
        runCurrent()
        store.query = "Newest query"
        store.find()
        runCurrent()
        service.finishSearch(3, listOf(station))
        runCurrent()
        service.failSearch(2, network())
        runCurrent()
        assertEquals(listOf(station), store.matches)
        assertEquals(Phase.CHOOSING, store.phase)
        assertNull(store.errorMessage)
        assertEquals(0, service.pendingCount)
    }

    @Test fun lateLocalizationCannotReplaceANewerSelectionOrLanguage() = runTest {
        val store = store()
        search(store)
        store.select(station)
        runCurrent()
        store.select(museum)
        runCurrent()
        service.finishAddress(1, museumAddress)
        runCurrent()
        service.finishAddress(0, japaneseAddress)
        runCurrent()
        assertEquals(museum, store.selectedPlace)
        assertEquals(museumAddress, store.address)

        // Changing language cancels work, clears the old copy value and resolves the same place again.
        val cancels = service.cancelCount
        store.language = english
        assertTrue(service.cancelCount > cancels)
        assertNull(store.copyValue)
        assertEquals(Phase.LOCALIZING, store.phase)
        runCurrent()
        assertEquals(museum to english, service.addresses[2])

        store.language = AddressLanguage("zh-Hant")
        runCurrent()
        assertEquals("zh-Hant", service.addresses[3].second.code)
        service.finishAddress(3, "日本東京都台東區上野公園13−9")
        runCurrent()
        // An obsolete language failure cannot erase the current address.
        service.failAddress(2, network())
        runCurrent()
        assertEquals("日本東京都台東區上野公園13−9", store.copyValue)
        assertNull(store.errorMessage)
        assertEquals(museum, store.selectedPlace)

        store.language = japanese
        runCurrent()
        store.language = english
        runCurrent()
        service.finishAddress(5, "13-9 Uenokoen, Taito City, Tokyo, Japan")
        runCurrent()
        // An obsolete language success cannot overwrite the current language result.
        service.finishAddress(4, "OLD JAPANESE ADDRESS")
        runCurrent()
        assertEquals("13-9 Uenokoen, Taito City, Tokyo, Japan", store.copyValue)
        assertEquals(english, store.language)
        assertEquals(0, service.pendingCount)
    }

    @Test fun languageChangeDuringSearchReleasesIt() = runTest {
        val store = store()
        store.query = "Tokyo"
        store.find()
        runCurrent()
        val cancels = service.cancelCount
        store.language = english
        assertTrue(service.cancelCount > cancels)
        assertEquals(Phase.IDLE, store.phase)
        assertNull(store.copyValue)
        service.finishSearch(0, listOf(station))
        runCurrent()
        assertTrue(store.matches.isEmpty())
        assertNull(store.selectedPlace)
        assertEquals(english, store.language)

        // Changing language before selection keeps the choices without localizing.
        search(store, "Tokyo", listOf(station))
        val calls = service.addresses.size
        store.language = japanese
        runCurrent()
        assertEquals(listOf(station), store.matches)
        assertEquals(Phase.CHOOSING, store.phase)
        assertEquals(calls, service.addresses.size)
        resolve(store)
        assertEquals(japaneseAddress, store.copyValue)
    }

    @Test fun queryChangeDuringLocalizationDropsTheOldResult() = runTest {
        val store = store()
        search(store, places = listOf(station))
        store.select(station)
        runCurrent()
        val cancels = service.cancelCount
        store.query = "Tokyo National Museum"
        assertTrue(service.cancelCount > cancels)
        assertEquals(Phase.IDLE, store.phase)
        assertTrue(store.matches.isEmpty())
        assertNull(store.selectedPlace)
        assertNull(store.copyValue)

        // The old place cannot be selected while a replacement query is pending.
        store.select(station)
        runCurrent()
        assertEquals(1, service.addresses.size)
        assertNull(store.selectedPlace)

        search(store, "Tokyo National Museum", listOf(museum))
        resolve(store, museum, museumAddress)
        service.finishAddress(0, japaneseAddress)
        runCurrent()
        assertEquals(museum, store.selectedPlace)
        assertEquals(listOf(museum), store.matches)
        assertEquals(museumAddress, store.copyValue)
        assertEquals(0, service.pendingCount)
    }

    @Test fun failuresAreShownAndRetryRepeatsTheSameWork() = runTest {
        val store = store()
        search(store, places = emptyList())
        assertEquals(Phase.IDLE, store.phase)
        assertFalse(store.isBusy)
        assertNotNull(store.errorMessage)
        assertNull(store.copyValue)

        store.retry()
        runCurrent()
        assertEquals(Phase.SEARCHING, store.phase)
        assertNull(store.errorMessage)
        assertEquals("Tokyo", service.searches[1])
        // Offline: visible, without a stuck spinner.
        service.failSearch(1, network())
        runCurrent()
        assertEquals(Phase.IDLE, store.phase)
        assertEquals(AddressLookupError.NETWORK.message, store.errorMessage)

        store.retry()
        runCurrent()
        service.finishSearch(2, listOf(station))
        runCurrent()
        // An empty provider address is not exposed as a successful result.
        store.select(station)
        runCurrent()
        service.finishAddress(0, " \n\t ")
        runCurrent()
        assertEquals(Phase.CHOOSING, store.phase)
        assertNull(store.copyValue)
        assertEquals(AddressLookupError.MISSING_ADDRESS.message, store.errorMessage)

        // Localization retry keeps the exact selection and language.
        store.retry()
        runCurrent()
        assertNull(store.errorMessage)
        assertEquals(station to japanese, service.addresses[1])
        service.finishAddress(1, japaneseAddress)
        runCurrent()
        assertEquals(Phase.RESOLVED, store.phase)
        assertEquals(japaneseAddress, store.copyValue)
        assertNull(store.errorMessage)

        // Unknown failures do not expose provider internals.
        store.query = "Failure"
        store.find()
        runCurrent()
        service.failSearch(3, IllegalStateException("DO NOT DISPLAY provider internals"))
        runCurrent()
        assertFalse(store.errorMessage!!.contains("provider internals"))
        assertFalse(store.isBusy)
        assertEquals(0, service.pendingCount)
    }

    @Test fun closingCancelsWorkAndClearsTheScreen() = runTest {
        val store = store()
        store.query = "Tokyo"
        store.find()
        runCurrent()
        val searchCancels = service.cancelCount
        store.close()
        assertTrue(service.cancelCount > searchCancels)
        assertEquals(Phase.IDLE, store.phase)
        assertNull(store.copyValue)
        assertNull(store.errorMessage)
        // A dismissed search cannot repopulate the screen.
        service.finishSearch(0, listOf(station))
        runCurrent()
        assertTrue(store.matches.isEmpty())
        assertNull(store.selectedPlace)
        assertEquals(Phase.IDLE, store.phase)

        search(store, places = listOf(station))
        store.select(station)
        runCurrent()
        val addressCancels = service.cancelCount
        store.close()
        assertTrue(service.cancelCount > addressCancels)
        assertNull(store.selectedPlace)
        assertNull(store.address)
        // A dismissed localization error cannot leak into a later visit.
        service.failAddress(0, network())
        runCurrent()
        assertEquals(Phase.IDLE, store.phase)
        assertNull(store.errorMessage)
        assertNull(store.copyValue)
    }

    @Test fun cancellationFromTheServiceIsSilent() = runTest {
        val store = store()
        store.query = "Tokyo"
        store.find()
        runCurrent()
        service.failSearch(0, CancellationException())
        runCurrent()
        assertEquals(Phase.IDLE, store.phase)
        assertFalse(store.isBusy)
        assertNull(store.errorMessage)

        search(store, places = listOf(station))
        store.select(station)
        runCurrent()
        service.failAddress(0, CancellationException())
        runCurrent()
        assertEquals(Phase.CHOOSING, store.phase)
        assertFalse(store.isBusy)
        assertNull(store.errorMessage)
        assertNull(store.copyValue)

        // The screen can resolve a new address after cancellations.
        resolve(store)
        assertEquals(japaneseAddress, store.copyValue)
        store.close()
        assertNull(store.copyValue)
        assertEquals(0, service.pendingCount)
    }
}
