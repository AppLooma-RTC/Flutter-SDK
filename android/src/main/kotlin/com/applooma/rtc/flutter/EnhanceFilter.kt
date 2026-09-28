package com.applooma.rtc.flutter

// Keep in sync with the native Android SDK's VideoFilters.kt (the same filter)
// and with the React Native copy of this file (sdks/react-native/android).

import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt

/** Video Enhance options: beauty 0..1, lowLight, sharpen 0..1, warmth -1..1. */
internal data class EnhanceOptions(
    val beauty: Float = 0f,
    val lowLight: Boolean = false,
    val sharpen: Float = 0f,
    val warmth: Float = 0f,
) {
    val isNeutral: Boolean get() = beauty <= 0f && !lowLight && sharpen <= 0f && warmth == 0f

    companion object {
        fun of(beauty: Double?, lowLight: Boolean?, sharpen: Double?, warmth: Double?) = EnhanceOptions(
            beauty = beauty?.toFloat()?.takeIf { !it.isNaN() }?.coerceIn(0f, 1f) ?: 0f,
            lowLight = lowLight ?: false,
            sharpen = sharpen?.toFloat()?.takeIf { !it.isNaN() }?.coerceIn(0f, 1f) ?: 0f,
            warmth = warmth?.toFloat()?.takeIf { !it.isNaN() }?.coerceIn(-1f, 1f) ?: 0f,
        )
    }
}

/**
 * CPU filter behind Video Enhance, working on I420 planes in place: edge-
 * preserving skin smoothing, adaptive low-light gamma, sharpening and warmth.
 * Not thread-safe: called from the camera thread only.
 */
internal class EnhanceFilter {
    @Volatile var options: EnhanceOptions = EnhanceOptions()

    private var yRow = ByteArray(0)
    private var half = IntArray(0)
    private var blur = IntArray(0)
    private var tmp = IntArray(0)
    private var cRow = ByteArray(0)
    private val lut = IntArray(256)
    private val edgeWeight = IntArray(256)
    private val uLut = IntArray(256)
    private val vLut = IntArray(256)
    private var lastBeauty = -1f
    private var lastWarmth = Float.NaN
    private var gamma = 1.0

    fun process(
        w: Int, h: Int,
        dataY: ByteBuffer, strideY: Int,
        dataU: ByteBuffer, strideU: Int,
        dataV: ByteBuffer, strideV: Int,
    ) {
        val o = options
        if (o.isNeutral) { gamma = 1.0; return }
        if (o.beauty > 0f || o.sharpen > 0f || o.lowLight) processLuma(dataY.duplicate(), strideY, w, h, o)
        if (o.warmth != 0f) processChroma(dataU, strideU, dataV, strideV, (w + 1) / 2, (h + 1) / 2, o.warmth)
    }

    private fun processLuma(yBuf: ByteBuffer, stride: Int, w: Int, h: Int, o: EnhanceOptions) {
        val hw = w / 2
        val hh = h / 2
        val needBlur = (o.beauty > 0f || o.sharpen > 0f) && hw >= 2 && hh >= 2
        if (yRow.size < w * 2) yRow = ByteArray(w * 2)

        var sum = 0L
        var count = 0
        if (needBlur) {
            val n = hw * hh
            if (half.size < n) { half = IntArray(n); blur = IntArray(n); tmp = IntArray(n) }
            val row = yRow
            for (j in 0 until hh) {
                yBuf.position(2 * j * stride); yBuf.get(row, 0, w)
                yBuf.position((2 * j + 1) * stride); yBuf.get(row, w, w)
                val base = j * hw
                var x = 0
                for (i in 0 until hw) {
                    val a = (row[x].toInt() and 0xFF) + (row[x + 1].toInt() and 0xFF) +
                        (row[w + x].toInt() and 0xFF) + (row[w + x + 1].toInt() and 0xFF)
                    val v = (a + 2) shr 2
                    half[base + i] = v
                    if ((i and 3) == 0 && (j and 3) == 0) { sum += v; count++ }
                    x += 2
                }
            }
            val radius = if (o.beauty > 0f) (2 + (o.beauty * 3f).roundToInt()) else 1
            boxBlur(half, blur, tmp, hw, hh, radius)
        } else if (o.lowLight) {
            for (j in 0 until h step 8) {
                val p = j * stride
                for (i in 0 until w step 8) { sum += yBuf.get(p + i).toInt() and 0xFF; count++ }
            }
        }

        buildLut(o, if (count > 0) sum.toDouble() / count else 128.0)
        if (o.beauty != lastBeauty) buildEdgeWeights(o.beauty)

        val beautyOn = o.beauty > 0f && needBlur
        val sharpQ = (o.sharpen * 1.5f * 256f).toInt()
        val sharpOn = sharpQ > 0 && needBlur
        val row = yRow
        val lutL = lut
        val ew = edgeWeight
        for (j in 0 until h) {
            val p = j * stride
            yBuf.position(p); yBuf.get(row, 0, w)
            if (!beautyOn && !sharpOn) {
                for (i in 0 until w) row[i] = lutL[row[i].toInt() and 0xFF].toByte()
            } else {
                val hj = minOf(j shr 1, hh - 1)
                val bBase = hj * hw
                for (i in 0 until w) {
                    val y = row[i].toInt() and 0xFF
                    val hi = minOf(i shr 1, hw - 1)
                    var v = y
                    if (beautyOn) {
                        val d = blur[bBase + hi] - y
                        v = y + ((d * ew[if (d < 0) -d else d]) shr 8)
                    }
                    if (sharpOn) v += ((y - half[bBase + hi]) * sharpQ) shr 8
                    if (v < 0) v = 0 else if (v > 255) v = 255
                    row[i] = lutL[v].toByte()
                }
            }
            yBuf.position(p); yBuf.put(row, 0, w)
        }
    }

    private fun processChroma(u: ByteBuffer, strideU: Int, v: ByteBuffer, strideV: Int, cw: Int, ch: Int, warmth: Float) {
        if (warmth != lastWarmth) {
            lastWarmth = warmth
            val shift = (warmth * 14f).roundToInt()
            for (k in 0 until 256) {
                uLut[k] = (k - shift).coerceIn(0, 255)
                vLut[k] = (k + shift).coerceIn(0, 255)
            }
        }
        if (cRow.size < cw) cRow = ByteArray(cw)
        applyPlane(u.duplicate(), strideU, cw, ch, uLut)
        applyPlane(v.duplicate(), strideV, cw, ch, vLut)
    }

    private fun applyPlane(buf: ByteBuffer, stride: Int, cw: Int, ch: Int, table: IntArray) {
        val row = cRow
        for (j in 0 until ch) {
            val p = j * stride
            buf.position(p); buf.get(row, 0, cw)
            for (i in 0 until cw) row[i] = table[row[i].toInt() and 0xFF].toByte()
            buf.position(p); buf.put(row, 0, cw)
        }
    }

    private fun buildLut(o: EnhanceOptions, mean: Double) {
        var target = 1.0
        if (o.lowLight) {
            val m = mean.coerceIn(4.0, 250.0) / 255.0
            target = if (m < 0.43) (ln(0.43) / ln(m)).coerceIn(0.45, 1.0) else 1.0
        }
        gamma += (target - gamma) * 0.15
        if (!o.lowLight && abs(gamma - 1.0) < 0.01) gamma = 1.0
        val lift = o.beauty * 10f
        for (k in 0 until 256) {
            var v = if (gamma == 1.0) k.toDouble() else 255.0 * (k / 255.0).pow(gamma)
            v += lift * (1.0 - k / 255.0)
            lut[k] = v.roundToInt().coerceIn(0, 255)
        }
    }

    private fun buildEdgeWeights(beauty: Float) {
        lastBeauty = beauty
        val strength = beauty.coerceIn(0f, 1f) * 0.85f
        val sigma = 6f + 14f * beauty
        for (d in 0 until 256) {
            val x = d / sigma
            val fall = if (x >= 2f) 0f else if (x <= 1f) 1f else 2f - x
            edgeWeight[d] = (256f * strength * fall).toInt()
        }
    }

    private companion object {
        fun boxBlur(src: IntArray, dst: IntArray, tmp: IntArray, w: Int, h: Int, r: Int) {
            val div = 2 * r + 1
            for (j in 0 until h) {
                val base = j * w
                var acc = 0
                for (k in -r..r) acc += src[base + k.coerceIn(0, w - 1)]
                for (i in 0 until w) {
                    tmp[base + i] = acc / div
                    acc += src[base + minOf(i + r + 1, w - 1)] - src[base + maxOf(i - r, 0)]
                }
            }
            for (i in 0 until w) {
                var acc = 0
                for (k in -r..r) acc += tmp[k.coerceIn(0, h - 1) * w + i]
                for (j in 0 until h) {
                    dst[j * w + i] = acc / div
                    acc += tmp[minOf(j + r + 1, h - 1) * w + i] - tmp[maxOf(j - r, 0) * w + i]
                }
            }
        }
    }
}
