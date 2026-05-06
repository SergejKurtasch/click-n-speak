"""model_downloader.py — background Whisper model download with progress callbacks."""
import multiprocessing
import multiprocessing.queues
import os
import queue
import threading
import time
from typing import Callable

from .utils import log_error, log_info


def _subprocess_download(
    model_id: str,
    cache_dir: str,
    progress_q: "multiprocessing.Queue[int]",
    result_q: "multiprocessing.Queue[tuple]",
) -> None:
    """Runs in a child process. Reports byte progress and a final result via queues.

    This is a module-level function so it is picklable under the 'spawn' start method.
    The _Tqdm class is defined locally — instances are never transferred across processes.
    """
    _counter = [0]

    class _Tqdm:
        # threading is a module-level import — visible in class bodies (unlike enclosing
        # function locals, which class bodies cannot access due to Python scoping rules).
        _lock = threading.Lock()

        def __init__(self, iterable=None, **kwargs):
            self.iterable = iterable
            self.n = 0
            self.total = kwargs.get("total", None)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def __iter__(self):
            if self.iterable:
                yield from self.iterable

        def update(self, n=1):
            if n is None or n <= 0:
                return
            self.n += n
            with self.__class__._lock:
                _counter[0] += n
                val = _counter[0]
            try:
                progress_q.put_nowait(val)
            except Exception:
                pass

        def close(self): pass
        def set_postfix(self, **kw): pass
        def set_description(self, *a, **kw): pass
        def reset(self, total=None): pass
        def refresh(self, **kw): pass
        def unpause(self): pass
        def clear(self, **kw): pass
        def display(self, **kw): pass
        def write(self, s, **kw): pass

        @staticmethod
        def external_write_mode(**kw):
            class _ctx:
                def __enter__(self): return self
                def __exit__(self, *a): pass
            return _ctx()

        @classmethod
        def get_lock(cls):
            return cls._lock

        @classmethod
        def set_lock(cls, lk):
            cls._lock = lk

    try:
        from huggingface_hub import snapshot_download  # type: ignore
        snapshot_download(
            repo_id=model_id,
            cache_dir=cache_dir,
            resume_download=True,
            local_files_only=False,
            tqdm_class=_Tqdm,
        )
        result_q.put(("done",))
    except Exception as e:
        result_q.put(("error", str(e)))


class ModelDownloader:
    """Downloads a HuggingFace model in a child process with progress callbacks.

    cancel() terminates the process immediately — no lingering background threads.

    Callbacks are invoked from a monitor thread; callers must post to a main-thread
    queue if AppKit/UI updates are needed.

    on_progress(downloaded_bytes, total_bytes_or_none)
    on_done()
    on_error(msg)
    on_cancelled()
    """

    def __init__(self) -> None:
        self._process: multiprocessing.Process | None = None
        self._cancelled = False

    def start(
        self,
        model_id: str,
        total_size_estimate: int,
        on_progress: Callable[[int, int | None], None],
        on_done: Callable[[], None],
        on_error: Callable[[str], None],
        on_cancelled: Callable[[], None],
    ) -> None:
        if self._cancelled:
            on_cancelled()
            return
        self._cancelled = False
        cache_dir = os.environ.get(
            "HF_HOME",
            os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub"),
        )
        ctx = multiprocessing.get_context("spawn")
        progress_q: multiprocessing.Queue = ctx.Queue()
        result_q: multiprocessing.Queue = ctx.Queue()

        self._process = ctx.Process(
            target=_subprocess_download,
            args=(model_id, cache_dir, progress_q, result_q),
            daemon=True,
            name=f"model-dl-{model_id.split('/')[-1]}",
        )
        self._process.start()
        log_info(f"ModelDownloader: started process pid={self._process.pid} for {model_id}")

        monitor = threading.Thread(
            target=self._monitor,
            args=(model_id, progress_q, result_q, on_progress, on_done, on_error, on_cancelled),
            daemon=True,
            name=f"model-dl-monitor-{model_id.split('/')[-1]}",
        )
        monitor.start()

    def cancel(self) -> None:
        self._cancelled = True
        if self._process and self._process.is_alive():
            log_info(f"ModelDownloader: terminating process pid={self._process.pid}")
            self._process.terminate()

    def _monitor(
        self,
        model_id: str,
        progress_q: "multiprocessing.Queue[int]",
        result_q: "multiprocessing.Queue[tuple]",
        on_progress: Callable,
        on_done: Callable,
        on_error: Callable,
        on_cancelled: Callable,
    ) -> None:
        while True:
            # Drain all pending progress updates
            while True:
                try:
                    val = progress_q.get_nowait()
                    try:
                        on_progress(val, None)
                    except Exception:
                        pass
                except queue.Empty:
                    break

            # Check for a final result from the child
            try:
                result = result_q.get_nowait()
                # Flush any remaining progress before signalling completion
                while True:
                    try:
                        val = progress_q.get_nowait()
                        try:
                            on_progress(val, None)
                        except Exception:
                            pass
                    except queue.Empty:
                        break
                if result[0] == "done":
                    log_info(f"ModelDownloader: completed {model_id}")
                    on_done()
                else:
                    log_error(f"ModelDownloader: error for {model_id}: {result[1]}")
                    on_error(result[1])
                return
            except queue.Empty:
                pass

            # Detect unexpected process death (e.g., after terminate()).
            # Drain result_q once more first: there is a TOCTOU window where the child
            # puts ("done",) and exits between our get_nowait() above and is_alive()
            # here.  Without this drain we would wrongly call on_error on a successful
            # fast/resumable download.
            if self._process and not self._process.is_alive():
                try:
                    result = result_q.get_nowait()
                    if result[0] == "done":
                        log_info(f"ModelDownloader: completed {model_id}")
                        on_done()
                    else:
                        log_error(f"ModelDownloader: error for {model_id}: {result[1]}")
                        on_error(result[1])
                except queue.Empty:
                    if self._cancelled:
                        log_info(f"ModelDownloader: cancelled {model_id}")
                        on_cancelled()
                    else:
                        on_error("Download process terminated unexpectedly")
                return

            time.sleep(0.1)
