package com.applooma.rtc.flutter

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Native half of the Flutter SDK: Video Enhance and Clear Voice, attached to
 * the media plugin's capture hooks (the local camera track's frame processor
 * list and the microphone's capture post-processing stage).
 */
class AppLoomaRtcPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "applooma_rtc/media").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setVideoEnhance" -> result.success(
                    MediaHooks.setVideoEnhance(
                        call.argument<String>("trackId"),
                        EnhanceOptions.of(
                            call.argument<Double>("beauty"),
                            call.argument<Boolean>("lowLight"),
                            call.argument<Double>("sharpen"),
                            call.argument<Double>("warmth"),
                        ),
                    )
                )
                "setClearVoice" -> result.success(MediaHooks.setClearVoice(call.argument<Boolean>("enabled") == true))
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("media", t.message, null)
        }
    }
}

internal object MediaHooks {
    private val enhancer = EnhanceProcessor()
    private var attached: LocalVideoTrack? = null
    private var clearVoiceAdded = false

    /**
     * Sets the options and attaches the filter to [trackId] (the local camera
     * track), detaching it from any earlier track. Neutral options detach.
     * Returns true when the filter is running on a camera track.
     */
    @Synchronized
    fun setVideoEnhance(trackId: String?, options: EnhanceOptions): Boolean {
        enhancer.filter.options = options
        val track = if (options.isNeutral || trackId == null) null
            else FlutterWebRTCPlugin.sharedSingleton?.getLocalTrack(trackId) as? LocalVideoTrack
        if (track !== attached) {
            attached?.removeProcessor(enhancer)
            enhancer.releasePending()
            track?.addProcessor(enhancer)
            attached = track
        }
        return track != null
    }

    @Synchronized
    fun setClearVoice(on: Boolean): Boolean {
        ClearVoiceProcessor.enabled = on
        if (!clearVoiceAdded) {
            val controller = FlutterWebRTCPlugin.sharedSingleton?.audioProcessingController ?: return false
            controller.capturePostProcessing.addProcessor(ClearVoiceProcessor)
            clearVoiceAdded = true
        }
        return true
    }
}

/** Runs [EnhanceFilter] on every camera frame (camera thread). */
internal class EnhanceProcessor : LocalVideoTrack.ExternalVideoFrameProcessing {
    val filter = EnhanceFilter()

    /**
     * The frame handed on last time. The hook passes our return value to the
     * source and never releases it, so it is released here once the source has
     * taken its own reference (on the next frame, or on detach).
     */
    private var pending: VideoFrame? = null

    @Synchronized
    fun releasePending() {
        pending?.release()
        pending = null
    }

    @Synchronized
    override fun onFrame(frame: VideoFrame): VideoFrame {
        pending?.release()
        pending = null
        if (filter.options.isNeutral) return frame
        val i420 = try { frame.buffer.toI420() } catch (_: Throwable) { null } ?: return frame
        try {
            filter.process(i420.width, i420.height, i420.dataY, i420.strideY, i420.dataU, i420.strideU, i420.dataV, i420.strideV)
        } catch (_: Throwable) {
            i420.release()
            return frame
        }
        return VideoFrame(i420, frame.rotation, frame.timestampNs).also { pending = it }
    }
}

/** Clear Voice on the microphone's capture post-processing stage (audio thread). */
internal object ClearVoiceProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    @Volatile var enabled = false
    private val denoiser = ClearVoiceDenoiser()

    override fun initialize(sampleRateHz: Int, numChannels: Int) { denoiser.reset() }
    override fun reset(newRate: Int) { denoiser.reset() }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        // Never let an exception escape into the native audio thread.
        try {
            if (!enabled) { denoiser.reset(); return }
            val fb = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer()
            // numBands * numFrames can overshoot the buffer (3 bands reported
            // for full-band audio); the buffer's own limit is the truth.
            val n = minOf(numBands * numFrames, fb.limit())
            if (n > 0) denoiser.process(fb, n)
        } catch (_: Throwable) {}
    }
}
