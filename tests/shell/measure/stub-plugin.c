// A LADSPA plugin with the shape of DeepFilterNet's deep_filter_mono -- its
// six controls by their names, one audio port in and one out -- that passes
// its input through a fixed delay, for tests/shell/test-measure.sh. The host
// and the analysis are what is tested; the model is not, and a pass-through
// is the one plugin whose right answer is known: every frame kept, at 0 dB,
// and the delay found to the sample. STUB_GAP=1 in the environment zeroes
// 100 samples 1.5 s in, which the host has to count as one dropout.
#include <stdlib.h>
#include <string.h>

#define DELAY 3872
typedef float LADSPA_Data;
typedef struct { int HintDescriptor; LADSPA_Data LowerBound, UpperBound; } Hint;
typedef struct D {
    unsigned long UniqueID; const char *Label; int Properties;
    const char *Name, *Maker, *Copyright; unsigned long PortCount;
    const int *PortDescriptors; const char *const *PortNames; const Hint *PortRangeHints;
    void *ImplementationData;
    void *(*instantiate)(const struct D *, unsigned long);
    void (*connect_port)(void *, unsigned long, LADSPA_Data *);
    void (*activate)(void *); void (*run)(void *, unsigned long);
    void (*run_adding)(void *, unsigned long); void (*set_run_adding_gain)(void *, LADSPA_Data);
    void (*deactivate)(void *); void (*cleanup)(void *);
} D;

enum { IN = 1, OUT = 2, CTL = 4, AUD = 8 };
static const int descs[] = { CTL | IN, CTL | IN, CTL | IN, CTL | IN, CTL | IN, CTL | IN, AUD | IN, AUD | OUT };
static const char *const names[] = { "Attenuation Limit (dB)", "Min processing threshold (dB)",
    "Max ERB processing threshold (dB)", "Max DF processing threshold (dB)",
    "Min Processing Buffer (frames)", "Post Filter Beta", "Audio In", "Audio Out" };
static const Hint hints[] = { {0, 0, 100}, {0, -15, 35}, {0, -15, 35}, {0, -15, 35}, {0, 0, 10}, {0, 0, 0.05}, {0, 0, 0}, {0, 0, 0} };

typedef struct { float *port[8]; float ring[DELAY]; unsigned long pos, done; int gap; } S;

static void *inst(const D *d, unsigned long rate) { (void)d; (void)rate; S *s = calloc(1, sizeof *s); s->gap = getenv("STUB_GAP") != NULL; return s; }
static void conn(void *h, unsigned long p, float *b) { ((S *)h)->port[p] = b; }
static void run(void *h, unsigned long n) {
    S *s = h;
    for (unsigned long i = 0; i < n; i++, s->done++) {
        float x = s->port[6][i];
        float y = s->ring[s->pos];
        s->ring[s->pos] = x;
        s->pos = (s->pos + 1) % DELAY;
        if (s->gap && s->done >= 72000 && s->done < 72100) y = 0.0f;
        s->port[7][i] = y;
    }
}
static void clean(void *h) { free(h); }
static const D d = { 1, "deep_filter_mono", 0, "stub", "jayos-audio", "none", 8, descs, names, hints, NULL,
    inst, conn, NULL, run, NULL, NULL, NULL, clean };
const D *ladspa_descriptor(unsigned long i) { return i == 0 ? &d : NULL; }
