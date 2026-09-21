import logging
from pathlib import Path
import sys
from threading import Lock

_logger_lock = Lock()


def get_logger(log_file, level=logging.INFO):
    path = Path(log_file).expanduser().resolve()
    with _logger_lock:
        logger = logging.getLogger(f"simulate.file.{path}")
        logger.setLevel(level)
        logger.propagate = False
        if not logger.handlers:
            path.parent.mkdir(parents=True, exist_ok=True)
            file_handler = logging.FileHandler(path, mode="a", encoding="utf-8")
            stdout_handler = logging.StreamHandler(sys.stdout)
            formatter = logging.Formatter(
                "%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s",
                datefmt="%Y-%m-%d %H:%M:%S",
            )
            for handler in (stdout_handler, file_handler):
                handler.setFormatter(formatter)
                logger.addHandler(handler)
        return logger
