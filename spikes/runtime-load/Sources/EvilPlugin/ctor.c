// Runs inside dlopen, before the host looks up or calls anything.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void evil_ctor(void) {
    const char *dir = getenv("SPIKE_TMP");
    if (!dir) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/ctor-ran.txt", dir);
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "constructor ran during dlopen in pid %d\n", getpid());
        fclose(f);
    }
}
