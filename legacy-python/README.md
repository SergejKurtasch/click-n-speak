# Click-n-speak legacy Python application

`legacy-python/` is the frozen, maintenance-only rollback reference for
Click-n-speak. It retains the Python entry point, runtime modules, packaging,
resources, tests, and historical material needed to reproduce the legacy
application while the Swift application is the only actively developed
product.

Do not add new product features here. Changes are limited to rollback safety,
reproducibility, security, and clearly documented maintenance fixes. The tree
must remain independently runnable and must not import code or runtime
resources from `swift-app/`.

## Development

Create an environment owned by this application tree, install its dependencies,
then run commands from `legacy-python/`:

```bash
cd legacy-python
python3.11 -m venv venv
venv/bin/python -m pip install -r requirements.txt
```

Focused legacy checks use:

```bash
venv/bin/python -m pytest tests -q
```
