/* Standalone launcher for the legacy Python bundle.
 * The bundle contains Python at Resources/python and the app at Resources/app.
 */
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char executable[4096];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) {
        fprintf(stderr, "Click-n-speak: unable to locate launcher\n");
        return 1;
    }
    char *last_slash = strrchr(executable, '/');
    if (last_slash == NULL) {
        fprintf(stderr, "Click-n-speak: malformed launcher path\n");
        return 1;
    }
    *last_slash = '\0';

    char resources[4096], python[4096], app[4096], bundle[4096];
    snprintf(resources, sizeof(resources), "%s/../Resources", executable);
    snprintf(app, sizeof(app), "%s/app/main.py", resources);
    snprintf(bundle, sizeof(bundle), "%s/../..", executable);

    const char *python_names[] = {"python3", "python3.11"};
    int python_found = 0;
    for (size_t index = 0; index < sizeof(python_names) / sizeof(python_names[0]); ++index) {
        snprintf(python, sizeof(python), "%s/python/bin/%s", resources, python_names[index]);
        if (access(python, X_OK) == 0) {
            python_found = 1;
            break;
        }
    }
    if (!python_found) {
        fprintf(stderr, "Click-n-speak: no executable Python found in %s/python/bin (tried python3 and python3.11)\n", resources);
        return 1;
    }
    setenv("PYTHONPATH", resources, 1);
    setenv("RESOURCEPATH", resources, 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("CLICK_N_SPEAK_APP", bundle, 1);

    char **python_argv = calloc((size_t)argc + 2, sizeof(char *));
    if (python_argv == NULL) return 1;
    python_argv[0] = python;
    python_argv[1] = app;
    for (int index = 1; index < argc; ++index) python_argv[index + 1] = argv[index];
    python_argv[argc + 1] = NULL;
    execv(python, python_argv);
    perror("Click-n-speak: execv Python");
    free(python_argv);
    return 1;
}
