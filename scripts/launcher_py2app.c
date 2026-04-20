/*
 * Click-n-speak launcher for py2app bundles.
 *
 * Replaces py2app's generic "applet" stub so macOS TCC shows
 * "Click-n-speak" (not "applet") in Input Monitoring settings.
 *
 * Replicates what py2app's applet does:
 *   - sets RESOURCEPATH = Contents/Resources
 *   - dlopen Contents/Frameworks/libpython3.11.dylib
 *   - calls Py_Main with Contents/Resources/__boot__.py
 */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*Py_Main_t)(int, wchar_t **);
typedef wchar_t *(*Py_DecodeLocale_t)(const char *, size_t *);

int main(int argc, char *argv[]) {
    /* Locate this binary → derive MacOS/ directory */
    char exe[4096];
    uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) {
        fprintf(stderr, "Click-n-speak: cannot get executable path\n");
        return 1;
    }

    char macos_dir[4096];
    strlcpy(macos_dir, exe, sizeof(macos_dir));
    char *sl = strrchr(macos_dir, '/');
    if (sl) *sl = '\0';

    /* Build key paths */
    char resources[4096], libpython[4096], boot_py[4096], bundle[4096];
    snprintf(resources,  sizeof(resources),  "%s/../Resources",                          macos_dir);
    snprintf(libpython,  sizeof(libpython),  "%s/../Frameworks/libpython3.11.dylib",     macos_dir);
    snprintf(boot_py,    sizeof(boot_py),    "%s/../Resources/__boot__.py",               macos_dir);
    snprintf(bundle,     sizeof(bundle),     "%s/../..",                                  macos_dir);

    /* Environment expected by py2app's __boot__.py and our app code.
     * PYTHONHOME must point to Contents/Resources so Python finds its stdlib
     * in Contents/Resources/lib/python3.11/ (where py2app places it),
     * overriding the compiled-in venv paths baked into libpython. */
    setenv("RESOURCEPATH",       resources, 1);
    setenv("PYTHONHOME",         resources, 1);
    setenv("ARGVZERO",           exe,       1);  /* py2app: basename used as argv[0] in sys.argv */
    setenv("CLICK_N_SPEAK_APP",  bundle,    1);

    /* Load libpython — must stay resident (dlclose would unload Python mid-run) */
    void *lib = dlopen(libpython, RTLD_LAZY | RTLD_GLOBAL);
    if (!lib) {
        fprintf(stderr, "Click-n-speak: dlopen %s: %s\n", libpython, dlerror());
        return 1;
    }

    Py_Main_t         Py_Main        = (Py_Main_t)        dlsym(lib, "Py_Main");
    Py_DecodeLocale_t Py_DecodeLocale = (Py_DecodeLocale_t) dlsym(lib, "Py_DecodeLocale");
    if (!Py_Main || !Py_DecodeLocale) {
        fprintf(stderr, "Click-n-speak: missing Python symbols\n");
        return 1;
    }

    /* multiprocessing spawn calls: binary -c "from multiprocessing.spawn import spawn_main; ..."
     * In that case pass argv straight to Python, replacing argv[0] with exe path. */
    if (argc > 1) {
        wchar_t **wargv = calloc(argc + 1, sizeof(wchar_t *));
        if (!wargv) return 1;
        wargv[0] = Py_DecodeLocale(exe, NULL);
        for (int i = 1; i < argc; i++)
            wargv[i] = Py_DecodeLocale(argv[i], NULL);
        wargv[argc] = NULL;
        return Py_Main(argc, wargv);
    }

    /* Normal launch: argv[0] = exe, argv[1] = __boot__.py */
    wchar_t *wargv[3];
    wargv[0] = Py_DecodeLocale(exe,     NULL);
    wargv[1] = Py_DecodeLocale(boot_py, NULL);
    wargv[2] = NULL;

    return Py_Main(2, wargv);
}
