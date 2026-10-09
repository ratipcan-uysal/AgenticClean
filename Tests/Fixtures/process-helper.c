// Disposable integration-test helper. Never used by the application.
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    if (strcmp(argv[1], "ignore-term") == 0) signal(SIGTERM, SIG_IGN);
    FILE *ready=fopen(argv[2], "w");
    if (!ready) return 3;
    fputs("ready", ready); fclose(ready);
    alarm(60); // Test cleanup remains bounded even if the test runner crashes.
    for (;;) pause();
}
