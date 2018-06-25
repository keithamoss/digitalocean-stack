import logging

# Courtesy https://stackoverflow.com/questions/30059477/python-logging-how-to-check-if-logger-is-empty


def counted(fn):
    def wrapper(*args, **kwargs):
        wrapper.count += 1
        return fn(*args, **kwargs)
    wrapper.count = 0
    wrapper.__name__ = fn.__name__
    return wrapper


class MyLogger(logging.Logger):
    def __init__(self, name=None, level=logging.NOTSET):
        super(MyLogger, self).__init__(name, level)

    @counted
    def info(self, *args, **kwargs):
        super(MyLogger, self).info(*args, **kwargs)

    @counted
    def warning(self, *args, **kwargs):
        super(MyLogger, self).warning(*args, **kwargs)

    @counted
    def critical(self, msg, *args, **kwargs):
        super(MyLogger, self).critical(msg, *args, **kwargs)

    @counted
    def error(self, *args, **kwargs):
        super(MyLogger, self).error(*args, **kwargs)

    def logfile(self):
        for h in self.handlers:
            if hasattr(h, 'baseFilename'):
                return h.baseFilename

    def empty(self):
        if self.warning.count or self.critical.count or self.error.count:
            return False
        else:
            return True

    def has_critical_or_errors(self):
        if self.critical.count or self.error.count:
            return True
        else:
            return False

    def status(self):
        msg = "WARNINGS:%s ERRORS:%s CRITICAL:%s" % (self.warning.count, self.error.count, self.critical.count)
        return msg


def addLogFile(logger, filepath):
    handler = logging.FileHandler(filepath, "w", encoding=None, delay="true")
    handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter("%(levelname)s\t: %(message)s")
    handler.setFormatter(formatter)
    logger.addHandler(handler)


def addLogConsole(logger):
    handler = logging.StreamHandler()
    handler.setLevel(logging.INFO)
    # formatter = logging.Formatter("%(levelname)s\t: %(message)s")
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
    handler.setFormatter(formatter)
    logger.addHandler(handler)


def myLog(level=None):
    if not LOGGER.handlers:
        # "Adding Handlers..."
        addLogConsole(LOGGER)
        # addLogFile(LOGGER, '#YOUR LOG FILE#')

    return LOGGER


LOGGER = MyLogger("root")
