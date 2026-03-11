# Numba stub to bypass numba dependency in mlx-whisper
def jit(*args, **kwargs):
    if len(args) == 1 and callable(args[0]):
        return args[0]
    def decorator(func):
        return func
    return decorator

def njit(*args, **kwargs):
    return jit(*args, **kwargs)
