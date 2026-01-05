# Check screenshot generation works...
In the absence of this bit of config: https://github.com/keithamoss/demsausage/blob/d7e6b531ca6b31bd4fcf3a888cb5b967dcff51b9/docker-compose.yml#L135

I think I also need to rotate the GitHub PAT token

# Handle logs

# Handle these errors from the gunicorn logs

/usr/local/lib/python3.9/site-packages/gevent/events.py:74: UserWarning: pkg_resources is deprecated as an API. See https://setuptools.pypa.io/en/latest/pkg_resources.html. The pkg_resources package is slated for removal as early as 2025-11-30. Refrain from using this package or pin to Setuptools<81.
  from pkg_resources import iter_entry_points
/usr/local/lib/python3.9/site-packages/gevent/events.py:74: UserWarning: pkg_resources is deprecated as an API. See https://setuptools.pypa.io/en/latest/pkg_resources.html. The pkg_resources package is slated for removal as early as 2025-11-30. Refrain from using this package or pin to Setuptools<81.
  from pkg_resources import iter_entry_points
[2025-12-29 06:48:24 +0000] [32] [INFO] Starting gunicorn 23.0.0
[2025-12-29 06:48:24 +0000] [32] [INFO] Listening at: http://0.0.0.0:8000 (32)
[2025-12-29 06:48:24 +0000] [32] [INFO] Using worker: gevent
[2025-12-29 06:48:24 +0000] [34] [INFO] Booting worker with pid: 34
[2025-12-29 06:48:24 +0000] [37] [INFO] Booting worker with pid: 37
/usr/local/lib/python3.9/site-packages/gevent/events.py:74: UserWarning: pkg_resources is deprecated as an API. See https://setuptools.pypa.io/en/latest/pkg_resources.html. The pkg_resources package is slated for removal as early as 2025-11-30. Refrain from using this package or pin to Setuptools<81.
  from pkg_resources import iter_entry_points
/usr/local/lib/python3.9/site-packages/gevent/events.py:74: UserWarning: pkg_resources is deprecated as an API. See https://setuptools.pypa.io/en/latest/pkg_resources.html. The pkg_resources package is slated for removal as early as 2025-11-30. Refrain from using this package or pin to Setuptools<81.
  from pkg_resources import iter_entry_points

# Could CloudFlare replace our memcached use?