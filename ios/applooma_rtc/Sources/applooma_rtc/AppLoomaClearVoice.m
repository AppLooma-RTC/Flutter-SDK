#import "AppLoomaClearVoice.h"

#import <math.h>
#import <stdlib.h>
#import <string.h>

// Short-time spectrum (sqrt-Hann window, 50 % overlap), a per-band noise floor
// that follows the quietest level quickly and rises slowly (about 2 dB/s), and
// a Wiener-style gain with over-subtraction and a -20 dB floor. Same constants
// as the Android implementation. One hop (one 10 ms buffer) of latency.

#define CV_POWER_SMOOTH 0.7f
#define CV_RISE 1.005f
#define CV_FALL 0.7f
#define CV_OVER 3.0f
#define CV_FLOOR 0.1f
#define CV_MAX_CHANNELS 2

typedef struct {
  int hop, fftSize;
  float *window, *inFrame, *overlap, *re, *im, *smoothPower, *noise, *gain, *sorted;
  long frames;
} CVState;

static void cv_free(CVState *s) {
  free(s->window); free(s->inFrame); free(s->overlap); free(s->re); free(s->im);
  free(s->smoothPower); free(s->noise); free(s->gain); free(s->sorted);
  memset(s, 0, sizeof(*s));
}

static void cv_setup(CVState *s, int n) {
  cv_free(s);
  s->hop = n;
  int f = 1;
  while (f < 2 * n) f <<= 1;
  s->fftSize = f;
  int w = 2 * n;
  s->window = malloc(sizeof(float) * w);
  for (int i = 0; i < w; i++) s->window[i] = sqrtf(0.5f - 0.5f * cosf(2.0f * (float)M_PI * i / w));
  s->inFrame = calloc(w, sizeof(float));
  s->overlap = calloc(n, sizeof(float));
  s->re = calloc(f, sizeof(float));
  s->im = calloc(f, sizeof(float));
  int bins = f / 2 + 1;
  s->smoothPower = calloc(bins, sizeof(float));
  s->noise = calloc(bins, sizeof(float));
  s->sorted = calloc(bins, sizeof(float));
  s->gain = malloc(sizeof(float) * bins);
  for (int k = 0; k < bins; k++) s->gain[k] = 1.0f;
  s->frames = 0;
}

static void cv_fft(float *re, float *im, int n, int inverse) {
  for (int i = 1, j = 0; i < n; i++) {
    int bit = n >> 1;
    while (j & bit) { j ^= bit; bit >>= 1; }
    j ^= bit;
    if (i < j) {
      float t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (int len = 2; len <= n; len <<= 1) {
    double ang = 2 * M_PI / len * (inverse ? 1 : -1);
    double wr = cos(ang), wi = sin(ang);
    for (int i = 0; i < n; i += len) {
      double cr = 1, ci = 0;
      for (int k = 0; k < len / 2; k++) {
        int a = i + k, b = a + len / 2;
        float xr = (float)(re[b] * cr - im[b] * ci);
        float xi = (float)(re[b] * ci + im[b] * cr);
        re[b] = re[a] - xr; im[b] = im[a] - xi;
        re[a] += xr; im[a] += xi;
        double nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr;
      }
    }
  }
  if (inverse) for (int i = 0; i < n; i++) { re[i] /= n; im[i] /= n; }
}

static int cv_cmp(const void *a, const void *b) {
  float x = *(const float *)a, y = *(const float *)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}

static void cv_process(CVState *s, float *buf, int n) {
  if (n <= 1) return;
  if (n != s->hop) cv_setup(s, n);
  int hop = s->hop, w = 2 * hop, fftSize = s->fftSize, bins = fftSize / 2 + 1;
  memmove(s->inFrame, s->inFrame + hop, sizeof(float) * hop);
  memcpy(s->inFrame + hop, buf, sizeof(float) * hop);

  memset(s->re, 0, sizeof(float) * fftSize);
  memset(s->im, 0, sizeof(float) * fftSize);
  for (int i = 0; i < w; i++) s->re[i] = s->inFrame[i] * s->window[i];
  cv_fft(s->re, s->im, fftSize, 0);

  for (int k = 0; k < bins; k++) {
    float p = s->re[k] * s->re[k] + s->im[k] * s->im[k];
    s->smoothPower[k] = s->frames == 0 ? p : CV_POWER_SMOOTH * s->smoothPower[k] + (1 - CV_POWER_SMOOTH) * p;
  }
  // Start the floor at the median band level of the first frame.
  float startFloor = 0;
  if (s->frames == 0) {
    memcpy(s->sorted, s->smoothPower, sizeof(float) * bins);
    qsort(s->sorted, bins, sizeof(float), cv_cmp);
    startFloor = s->sorted[bins / 2];
  }
  for (int k = 0; k < bins; k++) {
    int k0 = k > 0 ? k - 1 : 0, k1 = k < bins - 1 ? k + 1 : bins - 1;
    float sm = (s->smoothPower[k0] + s->smoothPower[k] + s->smoothPower[k1]) / 3.0f;
    if (s->frames == 0) s->noise[k] = startFloor;
    else if (sm < s->noise[k]) s->noise[k] = CV_FALL * s->noise[k] + (1 - CV_FALL) * sm;
    else s->noise[k] = fminf(s->noise[k] * CV_RISE, sm);
    float g = sm <= 0 ? CV_FLOOR : fminf(1.0f, fmaxf(CV_FLOOR, 1.0f - CV_OVER * s->noise[k] / sm));
    // Open fast, close a little slower: fewer "musical" artefacts.
    s->gain[k] = g > s->gain[k] ? g : 0.6f * s->gain[k] + 0.4f * g;
    s->re[k] *= s->gain[k]; s->im[k] *= s->gain[k];
    if (k >= 1 && k < fftSize / 2) {
      s->re[fftSize - k] = s->re[k];
      s->im[fftSize - k] = -s->im[k];
    }
  }
  cv_fft(s->re, s->im, fftSize, 1);
  for (int i = 0; i < hop; i++) {
    buf[i] = s->overlap[i] + s->re[i] * s->window[i];
    s->overlap[i] = s->re[hop + i] * s->window[hop + i];
  }
  s->frames++;
}

@implementation AppLoomaClearVoice {
  CVState _state[CV_MAX_CHANNELS];
}

+ (instancetype)shared {
  static AppLoomaClearVoice *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [AppLoomaClearVoice new]; });
  return instance;
}

- (void)dealloc {
  for (int c = 0; c < CV_MAX_CHANNELS; c++) cv_free(&_state[c]);
}

- (void)resetStates {
  for (int c = 0; c < CV_MAX_CHANNELS; c++) _state[c].hop = 0;
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
  [self resetStates];
}

- (void)audioProcessingProcess:(RTCAudioBuffer *)audioBuffer {
  if (!self.enabled) {
    [self resetStates];
    return;
  }
  // The buffer holds floats in 16-bit range; the suppressor is scale-independent.
  size_t channels = MIN(audioBuffer.channels, (size_t)CV_MAX_CHANNELS);
  int n = (int)audioBuffer.frames;
  for (size_t c = 0; c < channels; c++) {
    float *data = [audioBuffer rawBufferForChannel:c];
    if (data && n > 1) cv_process(&_state[c], data, n);
  }
}

- (void)audioProcessingRelease {
  [self resetStates];
}

@end
