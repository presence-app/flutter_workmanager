package dev.fluttercommunity.workmanager

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartCallback
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import java.util.Random

class BackgroundWorker(
    applicationContext: Context,
    private val workerParams: WorkerParameters
) : ListenableWorker(applicationContext, workerParams), MethodChannel.MethodCallHandler {

    private lateinit var backgroundChannel: MethodChannel
    private var engine: FlutterEngine? = null
    private var completer: CallbackToFutureAdapter.Completer<Result>? = null
    private var resolvableFuture = CallbackToFutureAdapter.getFuture<Result> { completer ->
        this.completer = completer
        null
    }

    companion object {
        const val TAG = "BackgroundWorker"
        const val PAYLOAD_KEY = "be.tramckrijte.workmanager.INPUT_DATA"
        const val DART_TASK_KEY = "be.tramckrijte.workmanager.DART_TASK"
        const val IS_IN_DEBUG_MODE_KEY = "be.tramckrijte.workmanager.IS_IN_DEBUG_MODE_KEY"
        const val BACKGROUND_CHANNEL_NAME = "be.tramckrijte.workmanager/background_channel_work_manager"

        private val flutterLoader = FlutterLoader()
    }

    private val payload get() = workerParams.inputData.getString(PAYLOAD_KEY)
    private val dartTask get() = workerParams.inputData.getString(DART_TASK_KEY)!!
    private val isInDebug get() = workerParams.inputData.getBoolean(IS_IN_DEBUG_MODE_KEY, false)
    private val randomThreadIdentifier = Random().nextInt()
    private var startTime: Long = 0

    override fun startWork(): ListenableFuture<Result> {
        startTime = System.currentTimeMillis()

        engine = FlutterEngine(applicationContext)

        if (!flutterLoader.initialized()) {
            flutterLoader.startInitialization(applicationContext)
        }

        flutterLoader.ensureInitializationCompleteAsync(
            applicationContext,
            null,
            Handler(Looper.getMainLooper())
        ) {
            val callbackHandle = SharedPreferenceHelper.getCallbackHandle(applicationContext)
            val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(callbackHandle)
                ?: throw IllegalStateException("Dart callback not found for handle $callbackHandle")
            val dartBundlePath = flutterLoader.findAppBundlePath()

            engine?.let { engine ->
                backgroundChannel = MethodChannel(engine.dartExecutor, BACKGROUND_CHANNEL_NAME)
                backgroundChannel.setMethodCallHandler(this@BackgroundWorker)

                // Execute Dart callback
                engine.dartExecutor.executeDartCallback(
                    DartCallback(
                        applicationContext.assets,
                        dartBundlePath,
                        callbackInfo
                    )
                )
            }
        }

        return resolvableFuture
    }

    override fun onStopped() {
        stopEngine(null)
    }

    private fun stopEngine(result: Result?) {
        if (result != null) {
            this.completer?.set(result)
        }

        Handler(Looper.getMainLooper()).post {
            engine?.destroy()
            engine = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "backgroundChannelInitialized") {
            backgroundChannel.invokeMethod(
                "onResultSend",
                mapOf(DART_TASK_KEY to dartTask, PAYLOAD_KEY to payload),
                object : MethodChannel.Result {
                    override fun notImplemented() = stopEngine(Result.failure())
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                        stopEngine(Result.failure())

                    override fun success(receivedResult: Any?) {
                        val success = receivedResult as? Boolean ?: false
                        stopEngine(if (success) Result.success() else Result.retry())
                    }
                }
            )
        }
    }
}
