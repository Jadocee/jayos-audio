// dfhost: run a LADSPA plugin's mono instance over raw float32 audio, one
// quantum per real-time period, as PipeWire's data thread would.
//
//   dfhost <plugin.so> <label> <in.f32> <out.f32> <quantum> ["Port name=value" ...]
//
// Prints each control port's value as set, and the count of exact-zero runs
// (dropouts) of 32 samples or more after the first second.
//
// Paced, not run flat out: the plugin's run() never waits for the thread its
// model runs in. It takes a quantum out of an output queue and, when the
// thread has not filled it, writes silence and grows its delay
// (docs/DEEPFILTERNET.md, *What the plugin did*). Called faster than real
// time it would be measuring that, not the model. A dropout count other than
// 0 means the run is not evidence, and tools/measure/measure.py runs it
// again. The LADSPA types are declared here rather than taken from ladspa.h,
// which Arch ships in the ladspa package the build does not otherwise need.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef float LADSPA_Data;
typedef struct { int HintDescriptor; LADSPA_Data LowerBound, UpperBound; } LADSPA_PortRangeHint;
typedef struct LADSPA_Descriptor {
    unsigned long UniqueID;
    const char *Label;
    int Properties;
    const char *Name, *Maker, *Copyright;
    unsigned long PortCount;
    const int *PortDescriptors;
    const char *const *PortNames;
    const LADSPA_PortRangeHint *PortRangeHints;
    void *ImplementationData;
    void *(*instantiate)(const struct LADSPA_Descriptor *, unsigned long);
    void (*connect_port)(void *, unsigned long, LADSPA_Data *);
    void (*activate)(void *);
    void (*run)(void *, unsigned long);
    void (*run_adding)(void *, unsigned long);
    void (*set_run_adding_gain)(void *, LADSPA_Data);
    void (*deactivate)(void *);
    void (*cleanup)(void *);
} LADSPA_Descriptor;
enum { PORT_INPUT = 1, PORT_OUTPUT = 2, PORT_CONTROL = 4, PORT_AUDIO = 8 };

int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: dfhost so label in out quantum [k=v...]\n"); return 2; }
    void *lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    const LADSPA_Descriptor *(*fn)(unsigned long) = dlsym(lib, "ladspa_descriptor");
    const LADSPA_Descriptor *d = NULL;
    for (unsigned long i = 0; fn && (d = fn(i)); i++) if (!strcmp(d->Label, argv[2])) break;
    if (!d) { fprintf(stderr, "no label %s\n", argv[2]); return 2; }

    FILE *in = fopen(argv[3], "rb");
    if (!in) { perror("in"); return 2; }
    fseek(in, 0, SEEK_END); long bytes = ftell(in); fseek(in, 0, SEEK_SET);
    long n = bytes / 4;
    float *src = malloc(bytes), *dst = calloc(n, 4);
    if (fread(src, 4, n, in) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
    fclose(in);
    unsigned long q = strtoul(argv[5], NULL, 10);

    void *h = d->instantiate(d, 48000);
    float *ctl = calloc(d->PortCount, sizeof(float));
    float *ibuf = calloc(q, 4), *obuf = calloc(q, 4);
    for (unsigned long p = 0; p < d->PortCount; p++) {
        int pd = d->PortDescriptors[p];
        if (pd & PORT_CONTROL) {
            ctl[p] = d->PortRangeHints[p].LowerBound;
            for (int a = 6; a < argc; a++) {
                const char *eq = strrchr(argv[a], '=');
                if (eq && (size_t)(eq - argv[a]) == strlen(d->PortNames[p])
                    && !strncmp(argv[a], d->PortNames[p], eq - argv[a]))
                    ctl[p] = strtof(eq + 1, NULL);
            }
            d->connect_port(h, p, &ctl[p]);
            if (pd & PORT_INPUT) fprintf(stderr, "  %s = %g\n", d->PortNames[p], ctl[p]);
        } else if (pd & PORT_AUDIO) {
            d->connect_port(h, p, (pd & PORT_INPUT) ? ibuf : obuf);
        }
    }
    if (d->activate) d->activate(h);

    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    long period = (long)(q * 1e9 / 48000);
    for (long off = 0; off < n; off += q) {
        unsigned long m = (n - off < (long)q) ? (unsigned long)(n - off) : q;
        memset(ibuf, 0, q * 4);
        memcpy(ibuf, src + off, m * 4);
        d->run(h, q);
        memcpy(dst + off, obuf, m * 4);
        t.tv_nsec += period;
        while (t.tv_nsec >= 1000000000L) { t.tv_nsec -= 1000000000L; t.tv_sec++; }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL);
    }
    if (d->deactivate) d->deactivate(h);
    if (d->cleanup) d->cleanup(h);

    long gaps = 0, run = 0;
    for (long i = 48000; i < n; i++) {
        if (dst[i] == 0.0f) run++;
        else { if (run >= 32) gaps++; run = 0; }
    }
    if (run >= 32) gaps++;
    fprintf(stderr, "  dropouts %ld\n", gaps);
    FILE *out = fopen(argv[4], "wb");
    fwrite(dst, 4, n, out);
    fclose(out);
    return 0;
}
