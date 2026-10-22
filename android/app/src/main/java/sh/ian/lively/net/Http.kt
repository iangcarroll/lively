package sh.ian.lively.net

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A response read in full: its code, a header lookup and its body. */
class HttpResult(val code: Int, val body: String, private val headers: okhttp3.Headers) {
    fun header(name: String): String? = headers[name]
}

/** Runs the call off the main thread and reads the body; cancelling the coroutine cancels the call. */
suspend fun OkHttpClient.fetch(request: Request): HttpResult {
    val call = newCall(request)
    return suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                val result = runCatching { response.use { HttpResult(it.code, it.body.string(), it.headers) } }
                result.fold(
                    onSuccess = { if (continuation.isActive) continuation.resume(it) },
                    onFailure = { if (continuation.isActive) continuation.resumeWithException(it) },
                )
            }
        })
    }
}
