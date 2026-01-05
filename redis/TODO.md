# Changed image to official Redis
Why didn't we use that originally?

# Deal with this WARNING

redis  | 1:C 29 Dec 2025 06:03:24.891 # oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
redis  | 1:C 29 Dec 2025 06:03:24.891 # Redis version=6.2.21, bits=64, commit=00000000, modified=0, pid=1, just started
redis  | 1:C 29 Dec 2025 06:03:24.891 # Configuration loaded
redis  | 1:M 29 Dec 2025 06:03:24.892 * Increased maximum number of open files to 10032 (it was originally set to 1024).
redis  | 1:M 29 Dec 2025 06:03:24.892 * monotonic clock: POSIX clock_gettime
redis  | 1:M 29 Dec 2025 06:03:24.892 * Running mode=standalone, port=6379.
redis  | 1:M 29 Dec 2025 06:03:24.892 # Server initialized
redis  | 1:M 29 Dec 2025 06:03:24.892 # WARNING Memory overcommit must be enabled! Without it, a background save or replication may fail under low memory condition. Being disabled, it can can also cause failures without low memory condition, see https://github.com/jemalloc/jemalloc/issues/1328. To fix this issue add 'vm.overcommit_memory = 1' to /etc/sysctl.conf and then reboot or run the command 'sysctl vm.overcommit_memory=1' for this to take effect.
redis  | 1:M 29 Dec 2025 06:03:24.894 * Ready to accept connections

# Put log files somewhere